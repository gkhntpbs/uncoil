import AppKit
import SwiftUI
import SwiftTerm

/// One live terminal per session record. PTYs are owned by uncoil-runtimed
/// (RuntimeClient) so agents survive app restarts; if the daemon is
/// unreachable we fall back to an in-process PTY that dies with the app.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private init() {
        // App-wide key monitor for Shift/Option+Enter → literal newline.
        TerminalKeyMonitor.installIfNeeded()
    }

    private var terminals: [UUID: TerminalView] = [:]
    private var delegates: [UUID: AnyObject] = [:]
    /// Sessions driven over a provider's structured protocol, whichever
    /// provider it is.
    private var structuredSessions: [UUID: any StructuredAgentSession] = [:]
    /// Sessions whose process exited; the next request recreates the terminal
    /// (auto-relaunch — the user never sees a "restart" screen).
    private var deadSessions: Set<UUID> = []
    /// Dead sessions oldest-first, so the buffers of long-ended sessions can
    /// be released while the few most recent stay instantly re-openable.
    private var deadOrder: [UUID] = []
    private let deadTerminalLimit = 4
    /// Why the last launch of a session could not go back into its
    /// conversation. Written when the command is built and read one hop later,
    /// where publishing a change to the session is allowed.
    private var resumeObstacles: [UUID: AgentResumeObstacle] = [:]
    private weak var titleStore: ProjectStore?

    func hasTerminal(for recordID: UUID) -> Bool {
        terminals[recordID] != nil
    }

    func markDead(_ recordID: UUID) {
        deadSessions.insert(recordID)
        CodexThreadTracker.shared.stop(recordID)
        // The process is gone: its delegate can receive nothing further, and a
        // Codex session that ended keeps an open transport for no one.
        delegates[recordID] = nil
        deadOrder.removeAll { $0 == recordID }
        deadOrder.append(recordID)
        // A dead terminal is only a scrollback snapshot; requesting it again
        // recreates the view anyway (auto-relaunch). Keeping every ended
        // session's full buffer alive is the app's largest slow leak.
        while deadOrder.count > deadTerminalLimit {
            let evicted = deadOrder.removeFirst()
            terminals[evicted] = nil
            delegates[evicted] = nil
        }
    }

    func terminal(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        // Held so a prompt submitted through the app can name the session it
        // went to; every terminal in the app is opened through here.
        titleStore = projectStore
        if let existing = terminals[record.id], !deadSessions.contains(record.id) {
            return existing
        }
        if deadSessions.remove(record.id) != nil {
            // The provider hands the conversation back on relaunch; kept, the
            // old timeline would show it twice.
            AgentEventHub.shared.reset(record.id)
        }

        let view: TerminalView
        let runtimePhase = RuntimeClient.shared.phase
        if record.provider == .uncoil {
            view = makeUncoilAutoTerminal(
                record: record, settings: settings, sessionStore: sessionStore, projectStore: projectStore)
        } else if shouldUseCodexAppServer(record: record, settings: settings) {
            view = makeCodexAppServerTerminal(
                record: record,
                project: project,
                account: account,
                settings: settings,
                sessionStore: sessionStore,
                projectStore: projectStore
            )
        } else if shouldUseClaudeStream(record: record, settings: settings) {
            view = makeClaudeStreamTerminal(
                record: record,
                project: project,
                account: account,
                settings: settings,
                sessionStore: sessionStore,
                projectStore: projectStore
            )
        } else if runtimePhase == .connecting || runtimePhase == .ready {
            view = makeRuntimeTerminal(record: record, project: project, account: account,
                                       settings: settings, sessionStore: sessionStore,
                                       projectStore: projectStore)
        } else {
            view = makeInProcessTerminal(record: record, project: project, account: account,
                                         settings: settings, sessionStore: sessionStore,
                                         projectStore: projectStore)
        }
        terminals[record.id] = view
        if structuredSessions[record.id] == nil, record.provider == .codex {
            // The thread Codex had is gone, so the record has to let go of it
            // before it can be told which thread started instead.
            if resumeObstacles[record.id] == .gone {
                projectStore.clearProviderSessionID(record.id)
            }
            CodexThreadTracker.shared.track(
                recordID: record.id,
                codexHome: account?.configDirectory(profilesRoot: settings.profilesRootURL)
                    ?? CodexSessionStore.defaultHome(),
                cwd: record.workingDirectory(in: project),
                projectStore: projectStore,
                sessionStore: sessionStore
            )
        }

        // The agent starts ready-and-waiting; hooks flip it to thinking/
        // running as real work happens. Deferred: this runs from makeNSView
        // (a view-update pass) where publishing changes is not allowed.
        //
        // Marking the session started belongs to the same hop, for the same
        // reason — it clears `endedAt` and stamps the activity time on a
        // published record. Doing it inline was what filled the console with
        // "Publishing changes from within view updates is not allowed" every
        // time a session was opened.
        let recordID = record.id
        let resumeObstacle = resumeObstacles.removeValue(forKey: recordID)
        let provider = record.provider
        DispatchQueue.main.async { [weak sessionStore, weak projectStore] in
            projectStore?.markSessionStarted(recordID)
            // A conversation the provider has lost is one this record must
            // stop asking for; one that is merely busy elsewhere is not.
            if resumeObstacle == .gone {
                projectStore?.clearProviderSessionID(recordID)
            }
            // A conversation that quietly did not come back reads as one that
            // was lost, so the reason rides on the session's own status line.
            sessionStore?.setStatus(
                .idle,
                detail: resumeObstacle?.message(for: provider),
                origin: .lifecycle,
                for: recordID
            )
            if LaunchConfig.shared.codexApprovalFixture, record.provider == .codex {
                sessionStore?.setCodexApproval(
                    CodexApprovalRequest(
                        id: "fixture-approval",
                        sessionID: recordID,
                        requestID: .string("fixture-approval"),
                        kind: .command,
                        title: String(localized: "git status"),
                        detail: String(localized: "Asks for permission to read the project's state."),
                        permissions: nil,
                        availableDecisions: ["accept", "acceptForSession", "decline"]
                    ),
                    for: recordID
                )
                sessionStore?.setStatus(
                    .waitingForPermission,
                    detail: String(localized: "git status"),
                    for: recordID
                )
            }
        }
        return view
    }

    // MARK: - Surface

    /// What a session is drawn as. Uncoil Auto is a conversation and gets the
    /// chat; every agent CLI keeps its own terminal, structured or not.
    nonisolated static func surface(for provider: AgentProvider) -> SessionSurface {
        provider == .uncoil ? .chat : .terminal
    }

    /// Starts the session without putting its terminal on screen — for a
    /// surface that draws the session some other way. The terminal is still
    /// made: it is what the session's lifecycle hangs on, and the view the
    /// user gets if they switch to it.
    func ensureSession(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) {
        _ = terminal(
            for: record, project: project, account: account,
            settings: settings, sessionStore: sessionStore, projectStore: projectStore
        )
    }

    /// Where a structured session's drafted prompt goes: its chat when one is
    /// open, its terminal's line editor otherwise.
    private static func draftHandler(
        for recordID: UUID, delegate: StructuredSessionTerminalDelegate
    ) -> (String) -> Void {
        { [weak delegate] text in
            if !AgentChatDrafts.shared.deliver(text, to: recordID) {
                delegate?.prefill(text)
            }
        }
    }

    /// Uncoil Auto runs in the app, never in a shell. The terminal view is
    /// made all the same: it is what a session's lifecycle hangs on here.
    /// Under `-chat-fixture` it plays a script instead, so every row the chat
    /// can draw is reachable without a routing model.
    private func makeUncoilAutoTerminal(
        record: SessionRecord, settings: SettingsStore, sessionStore: SessionStore, projectStore: ProjectStore
    ) -> TerminalView {
        let view = UncoilTerminalView(frame: .zero)
        applyTheme(view)
        var session: any StructuredAgentSession = LaunchConfig.shared.chatFixture
            ? FixtureAgentSession(record: record, terminal: view, sessionStore: sessionStore)
            : UncoilAutoSession(
                record: record,
                terminal: view,
                environment: .live(
                    sessionID: record.id, projectID: record.projectID, projects: projectStore,
                    sessions: sessionStore, settings: settings),
                store: UncoilAutoStore(url: UncoilAutoStore.url(for: record.id)))
        let delegate = StructuredSessionTerminalDelegate(session: session, terminal: view)
        session.draftHandler = Self.draftHandler(for: record.id, delegate: delegate)
        view.terminalDelegate = delegate
        delegates[record.id] = delegate
        structuredSessions[record.id] = session
        session.start()
        return view
    }

    private func shouldUseCodexAppServer(record: SessionRecord, settings: SettingsStore) -> Bool {
        guard record.provider == .codex,
              LaunchConfig.shared.codexAppServerEnabled,
              settings.binaryPath(for: .codex) != nil else { return false }
        let providerArguments = settings.extraArguments[AgentProvider.codex.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return providerArguments?.isEmpty != false && (record.extraArguments?.isEmpty ?? true)
    }

    /// The same rule as Codex's: free-form extra arguments are written for the
    /// TUI, and passing them to `claude -p` could change what it is.
    private func shouldUseClaudeStream(record: SessionRecord, settings: SettingsStore) -> Bool {
        guard record.provider == .claude,
              LaunchConfig.shared.claudeStructuredEnabled,
              settings.binaryPath(for: .claude) != nil else { return false }
        let providerArguments = settings.extraArguments[AgentProvider.claude.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return providerArguments?.isEmpty != false && (record.extraArguments?.isEmpty ?? true)
    }

    /// PTY environment: SwiftTerm's helper env has no HOME/USER/PATH —
    /// without HOME the login shell never reads ~/.zprofile and
    /// user-installed CLIs (~/.local/bin/claude) are not on PATH.
    private func environment(
        for account: AccountProfile?,
        settings: SettingsStore,
        record: SessionRecord
    ) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        // Tell the agent which way round this terminal is, the way every
        // terminal emulator does. `COLORFGBG` is the old convention and the one
        // TUIs read before they can ask; SwiftTerm answers the modern question
        // (OSC 11) from the colours `applyTheme` installs. Between them, an
        // agent starting inside a light Uncoil picks its light theme instead of
        // painting a dark one into it.
        env.append("COLORFGBG=\(ThemeStore.shared.palette.isLight ? "0;15" : "15;0")")
        let processEnv = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR"] {
            if let value = processEnv[key] {
                env.append("\(key)=\(value)")
            }
        }
        if let account,
           let key = account.isolationEnvironmentKey,
           let dir = account.configDirectory(profilesRoot: settings.profilesRootURL) {
            env.append("\(key)=\(dir.path)")
        }
        // Control-plane wiring: agent sessions learn their identity and the
        // control socket so the bundled uncoil-mcp server can reach the app.
        if record.provider.wiresControlPlane {
            let mcp = ControlProtocol.mcpEnvironment(
                for: record, socketPath: ControlPlaneServer.defaultSocketPath())
            for key in mcp.keys.sorted() { env.append("\(key)=\(mcp[key]!)") }
        }
        // OpenCode has no per-session config flag, but it merges the JSON in
        // `OPENCODE_CONFIG_CONTENT` over the user's own file. That is what
        // makes registering the server possible without ever writing to
        // ~/.config/opencode — the user's providers and keys stay untouched.
        if record.provider == .opencode,
           let binary = bundledMCPBinaryPath(),
           let content = Self.openCodeConfigContent(
               for: record,
               binaryPath: binary,
               scope: ProjectScopeService.shared
                   .resolve(for: record.provider, projectID: record.projectID).scope
           ) {
            env.append("OPENCODE_CONFIG_CONTENT=\(content)")
        }
        return env
    }

    /// The inline OpenCode config registering `uncoil-mcp` for one session.
    /// Static and pure so a test can assert the exact shape OpenCode expects
    /// (`mcp.<name>.type/command/environment`) without launching anything.
    nonisolated static func openCodeConfigContent(
        for record: SessionRecord,
        binaryPath: String,
        scope: ProjectExtensionScope = .unrestricted
    ) -> String? {
        var mcp: [String: Any] = [
            ControlPlaneMCPName: [
                "type": "local",
                "command": [binaryPath],
                "enabled": true,
                "environment": ControlProtocol.mcpEnvironment(
                    for: record, socketPath: ControlPlaneServer.defaultSocketPath()),
            ],
        ]
        // The content is merged over the user's own file, so naming a server
        // here with nothing but `enabled: false` switches it off without
        // restating — or losing — anything else it declares.
        for name in scope.excludedMCPNames where name != ControlPlaneMCPName {
            mcp[name] = ["enabled": false]
        }
        let config: [String: Any] = ["mcp": mcp]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func environmentDictionary(
        for account: AccountProfile?,
        settings: SettingsStore,
        record: SessionRecord
    ) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for entry in environment(for: account, settings: settings, record: record) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return result
    }

    private func bundledMCPBinaryPath() -> String? {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uncoil-mcp")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary.path : nil
    }

    /// Writes a per-session MCP config and returns its path. The user's
    /// `~/.claude.json` is never touched.
    ///
    /// The file plays one of two roles, and which one is decided by whether the
    /// project excludes anything. Normally it registers the bundled
    /// `uncoil-mcp` server alone and Claude Code merges it over the user's own
    /// config. Once a project has refused a server the file becomes the
    /// session's whole answer — it carries every allowed server too, and
    /// `launchCommand` adds `--strict-mcp-config` so nothing else is read.
    private func writeMCPConfig(
        for record: SessionRecord,
        binaryPath: String,
        scoped: ProjectScopeService.Resolved = .unrestricted
    ) -> String? {
        var servers: [String: Any] = [
            ControlPlaneMCPName: [
                "command": binaryPath,
                "env": ControlProtocol.mcpEnvironment(
                    for: record, socketPath: ControlPlaneServer.defaultSocketPath()),
            ],
        ]
        // The project's allow-list only has to be spelled out when the file is
        // about to become the session's *only* source of servers. While nothing
        // is excluded the file stays as it always was — one entry, merged over
        // the user's own config — and `--strict-mcp-config` is not passed.
        if !scoped.scope.excludedMCPNames.isEmpty {
            let allowed = ProjectExtensionScope.filteredMCPServers(
                rawConfig: scoped.rawConfig,
                allowing: scoped.scope.allowedMCPNames
            )
            // `uncoil` is added above and is not the project's to override.
            for (name, entry) in allowed where name != ControlPlaneMCPName {
                servers[name] = entry
            }
        }
        let config: [String: Any] = ["mcpServers": servers]
        let dir = ProjectStore.defaultDirectory().appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(record.id.uuidString).json")
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            return nil
        }
        try? data.write(to: fileURL, options: .atomic)
        return fileURL.path
    }

    /// Whether this session can actually go back into its conversation.
    ///
    /// Each provider is asked about its own store, and only about stores whose
    /// shape has been checked against a real install. A provider Uncoil cannot
    /// read answers `.unknown`, which resumes — refusing one that would have
    /// worked is worse than the error it would have avoided.
    nonisolated static func resumeDecision(
        for record: SessionRecord,
        cwd: String,
        configDirectory: URL?
    ) -> AgentResumeDecision {
        AgentResume.decide(
            provider: record.provider,
            providerSessionID: record.providerSessionID
        ) { id in
            switch record.provider {
            case .claude:
                ClaudeSessionStore.state(
                    configDirectory: configDirectory ?? ClaudeSessionStore.defaultConfigDirectory(),
                    cwd: cwd,
                    sessionID: id
                )
            case .codex:
                CodexSessionStore.state(
                    codexHome: configDirectory ?? CodexSessionStore.defaultHome(),
                    threadID: id
                )
            // OpenCode, Grok, Cursor and Hermes each keep their conversations
            // somewhere Uncoil has not verified against a real install, and a
            // guess here would refuse resumes that work today.
            default:
                .unknown
            }
        }
    }

    /// Shell arguments launching the agent. `exec` replaces the shell so the
    /// user never sees a typed command and closing the agent ends the session.
    /// -i: also source ~/.zshrc, for users whose PATH is set there.
    private func shellArguments(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        projectContext: String?
    ) -> (shell: String, args: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var args: [String] = ["-l"]
        let mcpBinaryPath = record.provider.wiresControlPlane ? bundledMCPBinaryPath() : nil
        // What this project lets the agent load. Resolved once here and handed
        // down, so the file that is written and the flags that point at it are
        // computed from the same answer.
        let scoped = ProjectScopeService.shared.resolve(
            for: record.provider,
            projectID: record.projectID,
            configDirectory: account?.configDirectory(profilesRoot: settings.profilesRootURL)
        )
        let mcpConfigPath = record.provider == .claude
            ? mcpBinaryPath.flatMap {
                writeMCPConfig(for: record, binaryPath: $0, scoped: scoped)
            }
            : nil
        let mcpEnvironment = ControlProtocol.mcpEnvironment(
            for: record, socketPath: ControlPlaneServer.defaultSocketPath())
        // Asked of the provider's own store rather than assumed from having an
        // id: a resume flag the CLI cannot honour is not a degraded launch, it
        // is a session that dies on its first line.
        let resume = Self.resumeDecision(
            for: record,
            cwd: record.workingDirectory(in: project),
            configDirectory: account?.configDirectory(profilesRoot: settings.profilesRootURL)
        )
        resumeObstacles[record.id] = resume.obstacle
        if let command = Self.launchCommand(
            for: record,
            binaryPath: settings.binaryPath(for: record.provider),
            resume: resume,
            mcpConfigPath: mcpConfigPath,
            mcpBinaryPath: mcpBinaryPath,
            mcpEnvironment: mcpEnvironment,
            scope: scoped.scope,
            extraArguments: settings.extraArguments[record.provider.rawValue],
            presetArguments: record.extraArguments,
            modeArguments: settings.workingModeArguments(for: record.provider),
            projectContext: projectContext
        ) {
            args = ["-l", "-i", "-c", "exec \(command)"]
        }
        return (shell, args)
    }

    /// Paints a terminal in the app's palette — and tells the terminal itself,
    /// not just the view.
    ///
    /// `nativeBackgroundColor` is what AppKit draws; `terminal.backgroundColor`
    /// is what SwiftTerm reports when an agent asks "what colour is this
    /// terminal?" (OSC 11). Agent CLIs use that answer to pick their own light
    /// or dark theme, so setting it is what keeps Claude Code and Codex from
    /// rendering a dark theme inside a light Uncoil.
    private func applyTheme(_ view: TerminalView) {
        let palette = ThemeStore.shared.palette
        view.nativeBackgroundColor = NSColor(Color(hex: palette.terminalBg))
        view.nativeForegroundColor = NSColor(Color(hex: palette.terminalFg))
        let terminal = view.getTerminal()
        terminal.backgroundColor = SwiftTerm.Color(rgb24: palette.terminalBg)
        terminal.foregroundColor = SwiftTerm.Color(rgb24: palette.terminalFg)
    }

    /// Hands SwiftTerm the user's "Option is Meta" choice.
    ///
    /// Off by default, as in Terminal.app: with Meta on, SwiftTerm swallows
    /// Option and emits ⎋<key>, so a Turkish-Q layout can never type `@` (⌥Q)
    /// or `#` (⌥3). `TerminalKeyTranslation.editingBytes` supplies ⌥←/→ word
    /// navigation in the off case so nothing is lost by the default.
    private func applyOptionAsMeta(_ view: TerminalView, settings: SettingsStore) {
        view.optionAsMetaKey = settings.optionAsMetaKey
    }

    /// Applies an "Option is Meta" change to every open terminal at once.
    func applyOptionAsMetaToLiveTerminals(_ enabled: Bool) {
        for view in terminals.values { view.optionAsMetaKey = enabled }
    }

    /// Raises an attention row when an agent's process ends badly.
    ///
    /// Every exit used to look the same — the row went quiet and that was it —
    /// so an agent that died mid-task was indistinguishable from one the user
    /// closed, and a crash in a session that was not on screen was silent.
    /// Selecting the session still relaunches it, which is the restart; what
    /// was missing was being told that it needed one.
    func reportExit(
        _ recordID: UUID,
        exitCode: Int32?,
        project: Project,
        record: SessionRecord
    ) {
        let exit = SessionExit.classify(
            exitCode: exitCode, isAgent: record.provider.isAgent
        )
        guard exit.isCrash, let reason = exit.reason else { return }
        AttentionStore.shared.report(
            kind: .agentCrashed,
            title: record.displayTitle,
            detail: String(
                localized: "\(record.provider.displayName) stopped on its own (\(reason)). Open the session to start it again."
            ),
            projectID: project.id,
            sessionID: recordID
        )
    }

    /// Re-paints every open terminal after a theme change.
    ///
    /// A running agent keeps the colours it chose when it started — nothing can
    /// re-ask it without restarting the session, and a session's history is
    /// worth more than its palette — but the terminal's own surface follows
    /// immediately, and the next agent to start reads the new answer.
    func applyThemeToLiveTerminals() {
        for view in terminals.values {
            applyTheme(view)
            view.needsDisplay = true
        }
    }

    private func makeCodexAppServerTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        guard let binaryPath = settings.binaryPath(for: .codex) else {
            return makeRuntimeTerminal(
                record: record,
                project: project,
                account: account,
                settings: settings,
                sessionStore: sessionStore,
                projectStore: projectStore
            )
        }
        let view = UncoilTerminalView(frame: .zero)
        applyTheme(view)
        applyOptionAsMeta(view, settings: settings)
        let mode = record.launchSelection?.workingMode ?? settings.workingMode(for: .codex)
        let codexConfig = try? String(
            contentsOf: (account?.configDirectory(profilesRoot: settings.profilesRootURL)
                ?? CodexSessionStore.defaultHome())
                .appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        let (approvalPolicy, sandbox) = AgentLaunchCatalog.codexApproval(
            mode: mode, config: codexConfig
        )
        var config: [String: JSONValue] = [:]
        // The app server takes no CLI flags; the same selection lands as config.
        if let model = record.launchSelection?.model {
            config["model"] = .string(model)
        }
        if let effort = record.launchSelection?.effort {
            config["model_reasoning_effort"] = .string(effort)
        }
        // This path takes no command line, so the project's scope arrives as
        // config the same way the model and the effort level do.
        let scope = ProjectScopeService.shared.resolve(
            for: record.provider,
            projectID: record.projectID,
            configDirectory: account?.configDirectory(profilesRoot: settings.profilesRootURL)
        ).scope
        var mcpServers: [String: JSONValue] = [:]
        if let mcpBinaryPath = bundledMCPBinaryPath() {
            mcpServers[ControlPlaneMCPName] = .object([
                "command": .string(mcpBinaryPath),
                "env": .object(ControlProtocol.mcpEnvironment(
                    for: record, socketPath: ControlPlaneServer.defaultSocketPath()
                ).mapValues(JSONValue.string)),
            ])
        }
        for name in scope.excludedMCPNames where name != ControlPlaneMCPName {
            mcpServers[name] = .object(["enabled": .bool(false)])
        }
        if !mcpServers.isEmpty {
            config["mcp_servers"] = .object(mcpServers)
        }
        let refusedSkills = scope.skills.filter { !$0.isEnabled }
        if !refusedSkills.isEmpty {
            config["skills"] = .object([
                "config": .array(refusedSkills.map { skill in
                    .object([
                        "path": .string(skill.path),
                        "enabled": .bool(false),
                    ])
                }),
            ])
        }
        let recordID = record.id
        let session = CodexAppServerSession(
            record: record,
            project: project,
            binaryPath: binaryPath,
            environment: environmentDictionary(for: account, settings: settings, record: record),
            config: .object(config),
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            terminal: view,
            settings: settings,
            sessionStore: sessionStore,
            projectStore: projectStore,
            fallback: { [weak view, weak settings, weak sessionStore, weak projectStore] reason in
                guard let view, let settings, let sessionStore, let projectStore else { return }
                TerminalRegistry.shared.structuredSessions[recordID] = nil
                TerminalRegistry.shared.configureRuntimeTerminal(
                    view,
                    record: record,
                    project: project,
                    account: account,
                    settings: settings,
                    sessionStore: sessionStore,
                    projectStore: projectStore
                )
                sessionStore.setStatus(.idle, detail: String(localized: "PTY fallback: \(reason)"), origin: .lifecycle, for: recordID)
            }
        )
        let delegate = StructuredSessionTerminalDelegate(session: session, terminal: view)
        session.draftHandler = { [weak delegate] in delegate?.prefill($0) }
        view.terminalDelegate = delegate
        delegates[record.id] = delegate
        structuredSessions[record.id] = session
        session.start()
        return view
    }

    private func makeClaudeStreamTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        guard let binaryPath = settings.binaryPath(for: .claude) else {
            return makeRuntimeTerminal(
                record: record, project: project, account: account,
                settings: settings, sessionStore: sessionStore, projectStore: projectStore)
        }
        let view = UncoilTerminalView(frame: .zero)
        applyTheme(view)
        applyOptionAsMeta(view, settings: settings)
        let configDirectory = account?.configDirectory(profilesRoot: settings.profilesRootURL)
        let cwd = record.workingDirectory(in: project)
        let scoped = ProjectScopeService.shared.resolve(
            for: record.provider, projectID: record.projectID, configDirectory: configDirectory)
        // Asked of Claude's own store, exactly as the terminal launch asks: a
        // resume flag for a transcript that is gone ends the session at once.
        let resume = Self.resumeDecision(for: record, cwd: cwd, configDirectory: configDirectory)
        let providerSessionID = resume.sessionID ?? UUID().uuidString.lowercased()
        let arguments = ClaudeStreamProtocol.arguments(
            record: record,
            resume: resume,
            newSessionID: providerSessionID,
            mcpConfigPath: bundledMCPBinaryPath().flatMap {
                writeMCPConfig(for: record, binaryPath: $0, scoped: scoped)
            },
            scope: scoped.scope,
            modeArguments: settings.workingModeArguments(for: .claude),
            projectContext: projectStore.agentContext(for: project.id))
        let transport = ClaudeProcessTransport(
            executable: binaryPath,
            arguments: arguments,
            directory: cwd,
            environment: environmentDictionary(for: account, settings: settings, record: record))
        let transcript = resume.sessionID.map {
            ClaudeSessionStore.transcriptURL(
                configDirectory: configDirectory ?? ClaudeSessionStore.defaultConfigDirectory(),
                cwd: cwd, sessionID: $0)
        }
        let recordID = record.id
        let obstacle = resume.obstacle
        let session = ClaudeStreamSession(
            record: record,
            providerSessionID: providerSessionID,
            startNotice: obstacle?.message(for: .claude),
            transport: transport,
            history: {
                guard let transcript else { return [] }
                return await Task.detached(priority: .userInitiated) {
                    ClaudeEventNormalizer.history(contentsOf: transcript)
                }.value
            },
            terminal: view,
            settings: settings,
            sessionStore: sessionStore,
            projectStore: projectStore,
            fallback: { [weak view, weak settings, weak sessionStore, weak projectStore] reason in
                guard let view, let settings, let sessionStore, let projectStore else { return }
                TerminalRegistry.shared.structuredSessions[recordID] = nil
                TerminalRegistry.shared.configureRuntimeTerminal(
                    view, record: record, project: project, account: account,
                    settings: settings, sessionStore: sessionStore, projectStore: projectStore)
                sessionStore.setStatus(.idle, detail: String(localized: "PTY fallback: \(reason)"), origin: .lifecycle, for: recordID)
            })
        let delegate = StructuredSessionTerminalDelegate(session: session, terminal: view)
        session.draftHandler = { [weak delegate] in delegate?.prefill($0) }
        view.terminalDelegate = delegate
        delegates[record.id] = delegate
        structuredSessions[record.id] = session
        session.start()
        return view
    }

    // MARK: - Daemon-backed terminal

    private func makeRuntimeTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        let view = UncoilTerminalView(frame: .zero)
        configureRuntimeTerminal(
            view,
            record: record,
            project: project,
            account: account,
            settings: settings,
            sessionStore: sessionStore,
            projectStore: projectStore
        )
        return view
    }

    private func configureRuntimeTerminal(
        _ view: UncoilTerminalView,
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) {
        applyTheme(view)
        applyOptionAsMeta(view, settings: settings)
        let provider = record.provider
        view.resolveShiftEnterNewline = { [weak settings] in
            settings?.shiftEnterNewline(for: provider) ?? provider.defaultShiftEnterNewline
        }
        view.newlineSequence = provider.descriptor.newlineSequence
        view.handleImagePaste = Self.imagePasteHandler(
            record: record, project: project, settings: settings
        )

        let (shell, args) = shellArguments(
            for: record, project: project, account: account, settings: settings,
            projectContext: projectStore.agentContext(for: project.id)
        )
        let spec = RuntimeClient.LaunchSpec(
            shell: shell,
            args: args,
            env: environment(for: account, settings: settings, record: record),
            cwd: record.workingDirectory(in: project)
        )

        let delegate = RuntimeTerminalDelegate(recordID: record.id, projectStore: projectStore)
        view.terminalDelegate = delegate
        delegates[record.id] = delegate

        let recordID = record.id
        RuntimeClient.shared.open(
            sid: record.id,
            spec: spec,
            cols: view.getTerminal().cols,
            rows: view.getTerminal().rows,
            onData: { [weak view, weak settings] data in
                if let settings {
                    settings.transcriptStore.append(
                        data,
                        sessionID: recordID,
                        policy: settings.transcriptRetentionPolicy
                    )
                }
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            },
            onExit: { [weak sessionStore, weak projectStore] code in
                // An exit we asked for is not an ending: the session is asleep
                // and its record has to stay intact for the wake.
                guard !TerminalRegistry.shared.isHibernating(recordID) else { return }
                sessionStore?.setStatus(.terminated, for: recordID)
                projectStore?.markSessionEnded(recordID, exitCode: code)
                TerminalRegistry.shared.reportExit(
                    recordID, exitCode: code, project: project, record: record
                )
                TerminalRegistry.shared.markDead(recordID)
            }
        )
    }

    // MARK: - In-process fallback (daemon unreachable)

    private func makeInProcessTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        let view = UncoilLocalTerminalView(frame: .zero)
        applyTheme(view)
        applyOptionAsMeta(view, settings: settings)
        let provider = record.provider
        view.resolveShiftEnterNewline = { [weak settings] in
            settings?.shiftEnterNewline(for: provider) ?? provider.defaultShiftEnterNewline
        }
        view.newlineSequence = provider.descriptor.newlineSequence
        view.handleImagePaste = Self.imagePasteHandler(
            record: record, project: project, settings: settings
        )
        let recordID = record.id
        view.onDataReceived = { [weak settings] data in
            if let settings {
                settings.transcriptStore.append(
                    data,
                    sessionID: recordID,
                    policy: settings.transcriptRetentionPolicy
                )
            }
        }
        let (shell, args) = shellArguments(
            for: record, project: project, account: account, settings: settings,
            projectContext: projectStore.agentContext(for: project.id)
        )
        view.startProcess(
            executable: shell,
            args: args,
            environment: environment(for: account, settings: settings, record: record),
            execName: nil,
            currentDirectory: record.workingDirectory(in: project)
        )
        let delegate = SessionProcessDelegate(
            recordID: record.id,
            sessionStore: sessionStore,
            projectStore: projectStore
        )
        view.processDelegate = delegate
        delegates[record.id] = delegate
        return view
    }

    /// Sessions whose process is being ended on purpose, to be brought back.
    ///
    /// Killing a PTY is indistinguishable from an agent crashing: both arrive as
    /// an exit. Without this, hibernating a session would mark it ended and it
    /// would come back as a closed one — with the wake button on a row the app
    /// believes is finished.
    private var hibernating: Set<UUID> = []

    func isHibernating(_ recordID: UUID) -> Bool { hibernating.contains(recordID) }

    /// Ends the process but keeps the session: its record, its title and above
    /// all its provider session id, which is what waking resumes from.
    func hibernateTerminal(for recordID: UUID) {
        hibernating.insert(recordID)
        closeTerminal(for: recordID)
    }

    /// Called when a hibernated session is woken, before it is relaunched.
    func clearHibernating(_ recordID: UUID) {
        hibernating.remove(recordID)
    }

    /// Answers ⌘V for one session, when the clipboard holds an image and the
    /// setting says Uncoil should.
    ///
    /// Built here because this is the one place that has the session, its
    /// project and the settings together; the key monitor has only the view
    /// that holds the keyboard. A shell is never answered — a plain terminal
    /// has no prompt to attach anything to, and taking its ⌘V would break
    /// pasting into `vim`.
    @MainActor
    private static func imagePasteHandler(
        record: SessionRecord, project: Project, settings: SettingsStore?
    ) -> () -> Bool {
        guard record.provider.isAgent else { return { false } }
        return { [weak settings] in
            guard let settings else { return false }
            return SessionImageDropService.handlePaste(
                record: record,
                project: project,
                mode: settings.imagePasteMode,
                onProgress: { SessionDropReporter.shared.report($0, for: record.id) }
            )
        }
    }

    func closeTerminal(for recordID: UUID) {
        structuredSessions[recordID]?.stop(terminateServer: true)
        structuredSessions[recordID] = nil
        AgentEventHub.shared.end(recordID)
        RuntimeClient.shared.kill(sid: recordID)
        CodexThreadTracker.shared.stop(recordID)
        terminals[recordID] = nil
        delegates[recordID] = nil
        deadSessions.remove(recordID)
        deadOrder.removeAll { $0 == recordID }
    }

    func prepareForApplicationTermination(terminateSessions: Bool) {
        structuredSessions.values.forEach {
            $0.prepareForApplicationTermination(terminateServer: terminateSessions)
        }
        structuredSessions.removeAll()
    }

    /// Submits a prompt into a session.
    ///
    /// `namesTheSession` is false for the text Uncoil sends on its own account
    /// — a branch-change note, a repair prompt, a handoff's opening line. A
    /// session named after something the user never asked would be worse than
    /// one still called "new session".
    func submitText(
        _ text: String,
        for recordID: UUID,
        provider: AgentProvider,
        namesTheSession: Bool = true
    ) async {
        if namesTheSession, let candidate = SessionAutoTitle.candidate(from: text) {
            titleStore?.adoptAutomaticTitle(candidate, for: recordID)
        }
        await submitTextIgnoringTitle(text, for: recordID, provider: provider)
    }

    private func submitTextIgnoringTitle(
        _ text: String, for recordID: UUID, provider: AgentProvider
    ) async {
        // A terminal's content is invisible to accessibility queries, so
        // without the journal the difference between "the prompt reached the
        // session" and "the prompt went nowhere" cannot be asserted at all —
        // which is how a handoff that delivered nothing once passed its test.
        if LaunchConfig.shared.isUITesting {
            UITestJournal.append("SUBMIT", "\(recordID.uuidString)\t\(text)")
        }
        await control(for: recordID, provider: provider).submit(text)
    }

    /// Types a prompt into the session without submitting it: the user reads,
    /// edits, and starts the turn themselves.
    func typeText(_ text: String, for recordID: UUID, provider: AgentProvider) async {
        await control(for: recordID, provider: provider).draft(text)
    }

    /// Whether the session runs as a structured session (Claude stream,
    /// Codex app-server, Uncoil Auto) rather than a terminal.
    func isStructured(_ recordID: UUID) -> Bool {
        structuredSessions[recordID] != nil
    }

    /// The way into a session, whatever is behind it: the structured Codex
    /// session when there is one, the terminal otherwise.
    func control(for recordID: UUID, provider: AgentProvider) -> AgentSessionControl {
        if let session = structuredSessions[recordID] {
            return session
        }
        return PTYAgentSessionControl(
            sessionID: recordID,
            provider: provider,
            bracketedPaste: { [weak self] in
                self?.terminals[recordID]?.getTerminal().bracketedPasteMode == true
            }
        )
    }

    /// Text as the agent can actually receive it.
    ///
    /// A newline written straight into a PTY *is* Enter. A prompt with a blank
    /// line in it therefore arrives as several submissions, the agent answers
    /// the last fragment, and everything before it is gone — which is what a
    /// long instruction handed to a session used to do.
    ///
    /// Bracketed paste is how a terminal says "this is one lump of text,
    /// newlines included": exactly what happens when a person pastes. It is
    /// only used when the running agent has actually turned the mode on
    /// (DECSET 2004), which the emulator already tracks, so nothing is assumed
    /// about a CLI that may not support it.
    ///
    /// Without it, runs of newlines are collapsed to single spaces. That loses
    /// the shape of the text, which is a real cost — but the alternative is
    /// losing all of it but the last paragraph.
    ///
    /// Pure, so both branches are testable without a PTY.
    nonisolated static func deliverable(
        _ text: String, bracketedPaste: Bool
    ) -> String {
        guard text.contains("\n") else { return text }
        if bracketedPaste {
            return "\u{1B}[200~" + text + "\u{1B}[201~"
        }
        return text
            .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sendRaw(_ data: Data, for recordID: UUID) {
        control(for: recordID).sendRaw(data)
    }

    func interrupt(_ recordID: UUID) {
        control(for: recordID).interrupt()
    }

    func respondToCodexApproval(
        sessionID: UUID,
        request: CodexApprovalRequest,
        decision: String
    ) {
        control(for: sessionID).respond(toApproval: request.id, decision: decision)
    }

    /// For calls that don't depend on how a prompt is typed.
    private func control(for recordID: UUID) -> AgentSessionControl {
        control(for: recordID, provider: .terminal)
    }

    func output(for recordID: UUID) async -> Data? {
        if let session = structuredSessions[recordID] {
            return await session.outputSnapshot()
        }
        return await RuntimeClient.shared.peek(sid: recordID)
    }

    /// Full command line for a provider session (nil = plain shell).
    /// Prefers the resolved absolute binary path so launch works even when
    /// the login shell's PATH misses user-local install dirs.
    /// Kept static and pure so tests can cover resume/extra-arg composition.
    nonisolated static func launchCommand(
        for record: SessionRecord,
        binaryPath: String? = nil,
        /// Required rather than defaulted: a caller that forgets it would
        /// silently start a fresh conversation where the user expected theirs
        /// back, and nothing would say so.
        resume: AgentResumeDecision,
        mcpConfigPath: String? = nil,
        mcpBinaryPath: String? = nil,
        mcpEnvironment: [String: String] = [:],
        scope: ProjectExtensionScope = .unrestricted,
        extraArguments: String?,
        presetArguments: [String]? = nil,
        modeArguments: [String] = [],
        /// What Uncoil knows about the project (`ProjectContextBuilder`);
        /// nil = nothing to tell the agent.
        projectContext: String? = nil
    ) -> String? {
        if record.provider == .terminal, let shellCommand = record.shellCommand, !shellCommand.isEmpty {
            return shellCommand.map(shellQuote).joined(separator: " ")
        }
        guard let name = record.provider.launchCommand else { return nil }
        var command = binaryPath.map { "\"\($0)\"" } ?? name
        let resumeID = resume.sessionID
        if record.provider == .claude, let sid = resumeID {
            command += " --resume \(shellQuote(sid))"
        }
        if record.provider == .codex, let sid = resumeID {
            command += " resume \(shellQuote(sid))"
        }
        if record.provider == .opencode, let sid = resumeID {
            command += " --session \(shellQuote(sid))"
        }
        if record.provider == .grok, let sid = resumeID {
            command += " --resume \(shellQuote(sid))"
        }
        if record.provider == .cursor, let sid = resumeID {
            command += " --resume \(shellQuote(sid))"
        }
        if record.provider == .hermes, let sid = resumeID {
            // `--no-restore-cwd` is not optional here. Hermes records a
            // session's working directory and cd's back into it on resume, so
            // waking a session would silently move it out of the worktree
            // Uncoil started it in — and the agent would then work in the wrong
            // checkout while the UI still showed the right one. Uncoil chose the
            // directory; the resume must not overrule it.
            command += " --resume \(shellQuote(sid)) --no-restore-cwd"
        }
        if record.provider == .claude, let mcpConfigPath {
            command += " --mcp-config \"\(mcpConfigPath)\""
            // Only once the project actually refuses something. Passing this
            // unconditionally would make every session ignore the user's own
            // `~/.claude.json`, which is the opposite of what an unconfigured
            // project asked for.
            if !scope.excludedMCPNames.isEmpty {
                command += " --strict-mcp-config"
            }
        }
        if record.provider == .codex {
            // Subtractive, and deliberately so: Codex's own entries stay put,
            // so nothing has to re-state a server's secrets to switch its
            // neighbour off.
            for name in scope.excludedMCPNames {
                command += " -c \(shellQuote("mcp_servers.\(name).enabled=false"))"
            }
            // Subtractive here too. Measured against the installed CLI with
            // `codex debug prompt-input`: an override array is merged into the
            // config's own `[[skills.config]]` rather than replacing it, so
            // naming one skill removes exactly that skill and leaves the other
            // 48 listed. Sending the full list with `enabled=true` on the
            // allowed ones would add ~3 KB of argv to assert a default, and
            // would be Uncoil overruling a skill the user disabled globally.
            let refused = scope.skills.filter { !$0.isEnabled }
            if !refused.isEmpty {
                let entries = refused.map { "{path=\(tomlString($0.path)),enabled=false}" }
                command += " -c \(shellQuote("skills.config=[\(entries.joined(separator: ","))]"))"
            }
        }
        // The project's context rides on the system prompt rather than in a
        // file the user maintains: nothing is written into the repository, and
        // a resumed session is told the current answer, not the one it had.
        let mcpAttached = (record.provider == .claude && mcpConfigPath != nil)
            || (record.provider == .codex && mcpBinaryPath != nil)
        let projectContext = mcpAttached
            ? ProjectContextBuilder.withUncoilTools(projectContext)
            : projectContext
        if let projectContext, !projectContext.isEmpty {
            if record.provider == .claude {
                command += " --append-system-prompt \(shellQuote(projectContext))"
            }
            if record.provider == .codex {
                // Verified with `codex debug prompt-input -c developer_instructions=…`:
                // the value arrives as a `developer` message ahead of the turn.
                command += " -c \(shellQuote("developer_instructions=" + tomlString(projectContext)))"
            }
        }
        if record.provider == .codex, let mcpBinaryPath {
            let escaped = mcpBinaryPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let override = "mcp_servers.uncoil.command=\"\(escaped)\""
                .replacingOccurrences(of: "'", with: "'\"'\"'")
            command += " -c '\(override)'"
            for key in mcpEnvironment.keys.sorted() {
                guard let value = mcpEnvironment[key] else { continue }
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let environmentOverride = "mcp_servers.uncoil.env.\(key)=\"\(escapedValue)\""
                    .replacingOccurrences(of: "'", with: "'\"'\"'")
                command += " -c '\(environmentOverride)'"
            }
        }
        // The dispatch-time selection (model / effort / mode) rides on the
        // record. Its mode replaces the settings-wide default only when it set
        // one — picking just a model must not silently drop the mode flags.
        let selectionArguments = record.launchSelection.map {
            AgentLaunchCatalog.launchArguments(for: record.provider, selection: $0)
        } ?? []
        if !selectionArguments.isEmpty {
            command += " " + selectionArguments.map(shellQuote).joined(separator: " ")
        }
        if record.launchSelection?.workingMode == nil, !modeArguments.isEmpty {
            command += " " + modeArguments.joined(separator: " ")
        }
        if let presetArguments, !presetArguments.isEmpty {
            command += " " + presetArguments.map(shellQuote).joined(separator: " ")
        }
        if let extra = extraArguments?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
            command += " " + extra
        }
        return command
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// A TOML basic string. Codex parses a `-c` value as TOML and silently
    /// falls back to treating it as a bare literal when the parse fails, so a
    /// path holding a quote or a backslash has to arrive escaped — otherwise
    /// the whole `skills.config` array is read as one meaningless string and
    /// the override does nothing at all.
    nonisolated private static func tomlString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
    }
}

/// Routes terminal-view events to the runtime daemon.
final class RuntimeTerminalDelegate: TerminalViewDelegate {
    private let recordID: UUID
    private weak var projectStore: ProjectStore?
    /// Watches the keys going past for the session's first prompt, and is
    /// dropped the moment the session has a name — after that it would be
    /// reading everything the user types for no reason at all.
    private var typedLine: SessionAutoTitle.TypedLineBuffer?

    @MainActor
    init(recordID: UUID, projectStore: ProjectStore? = nil) {
        self.recordID = recordID
        self.projectStore = projectStore
        let record = projectStore?.sessions.first { $0.id == recordID }
        if record?.hasPlaceholderTitle ?? false { typedLine = .init() }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Keystrokes arrive from AppKit, which is the main thread by
        // definition; the protocol simply does not say so.
        if typedLine != nil {
            MainActor.assumeIsolated { watchForFirstPrompt(data) }
        }
        RuntimeClient.shared.sendInput(Data(data), sid: recordID)
    }

    @MainActor
    private func watchForFirstPrompt(_ data: ArraySlice<UInt8>) {
        if let line = typedLine?.feed(data) {
            projectStore?.adoptAutomaticTitle(line, for: recordID)
            typedLine = nil
        } else if projectStore?.sessions.first(where: { $0.id == recordID })?
            .hasPlaceholderTitle == false {
            // Named by another route — a hook, or a prompt sent through the
            // app — so there is nothing left to watch for.
            typedLine = nil
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        RuntimeClient.shared.resize(sid: recordID, cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// Marks the session terminated when its in-process fallback PTY exits.
final class SessionProcessDelegate: LocalProcessTerminalViewDelegate {
    private let recordID: UUID
    private weak var sessionStore: SessionStore?
    private weak var projectStore: ProjectStore?

    init(
        recordID: UUID,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) {
        self.recordID = recordID
        self.sessionStore = sessionStore
        self.projectStore = projectStore
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = recordID
        Task { @MainActor [weak sessionStore, weak projectStore] in
            guard !TerminalRegistry.shared.isHibernating(id) else { return }
            sessionStore?.setStatus(.terminated, for: id)
            projectStore?.markSessionEnded(id, exitCode: exitCode)
            if let record = projectStore?.sessions.first(where: { $0.id == id }),
               let project = projectStore?.projects.first(where: { $0.id == record.projectID }) {
                TerminalRegistry.shared.reportExit(
                    id, exitCode: exitCode, project: project, record: record
                )
            }
            // Keep the frozen output visible; the next selection recreates
            // the terminal automatically (resuming Claude when possible).
            TerminalRegistry.shared.markDead(id)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct TerminalHostView: NSViewRepresentable {
    let record: SessionRecord
    let project: Project
    let account: AccountProfile?
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore

    func makeNSView(context: Context) -> TerminalView {
        TerminalRegistry.shared.terminal(
            for: record,
            project: project,
            account: account,
            settings: settings,
            sessionStore: sessionStore,
            projectStore: projectStore
        )
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}


extension SwiftTerm.Color {
    /// SwiftTerm keeps 16-bit channels; the palette stores 0xRRGGBB.
    convenience init(rgb24 hex: UInt32) {
        func channel(_ shift: UInt32) -> UInt16 {
            UInt16((hex >> shift) & 0xFF) << 8 | UInt16((hex >> shift) & 0xFF)
        }
        self.init(red: channel(16), green: channel(8), blue: channel(0))
    }
}
