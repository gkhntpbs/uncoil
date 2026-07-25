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
    private var codexSessions: [UUID: CodexAppServerSession] = [:]
    /// Sessions whose process exited; the next request recreates the terminal
    /// (auto-relaunch — the user never sees a "restart" screen).
    private var deadSessions: Set<UUID> = []

    func hasTerminal(for recordID: UUID) -> Bool {
        terminals[recordID] != nil
    }

    func markDead(_ recordID: UUID) {
        deadSessions.insert(recordID)
    }

    func terminal(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> TerminalView {
        if let existing = terminals[record.id], !deadSessions.contains(record.id) {
            return existing
        }
        deadSessions.remove(record.id)
        projectStore.markSessionStarted(record.id)

        let view: TerminalView
        let runtimePhase = RuntimeClient.shared.phase
        if shouldUseCodexAppServer(record: record, settings: settings) {
            view = makeCodexAppServerTerminal(
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
        if codexSessions[record.id] == nil {
            discoverCodexSessionID(
                for: record,
                project: project,
                account: account,
                settings: settings,
                projectStore: projectStore
            )
        }

        // The agent starts ready-and-waiting; hooks flip it to thinking/
        // running as real work happens. Deferred: this runs from makeNSView
        // (a view-update pass) where publishing changes is not allowed.
        let recordID = record.id
        DispatchQueue.main.async { [weak sessionStore] in
            sessionStore?.setStatus(.idle, for: recordID)
            if LaunchConfig.shared.codexApprovalFixture, record.provider == .codex {
                sessionStore?.setCodexApproval(
                    CodexApprovalRequest(
                        id: "fixture-approval",
                        sessionID: recordID,
                        requestID: .string("fixture-approval"),
                        kind: .command,
                        title: "git status",
                        detail: "Proje durumunu okumak için izin istiyor.",
                        permissions: nil,
                        availableDecisions: ["accept", "acceptForSession", "decline"]
                    ),
                    for: recordID
                )
                sessionStore?.setStatus(
                    .waitingForPermission,
                    detail: "git status",
                    for: recordID
                )
            }
        }
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

    private func discoverCodexSessionID(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        projectStore: ProjectStore
    ) {
        guard record.provider == .codex, record.providerSessionID == nil else { return }
        let codexHome = account?.configDirectory(profilesRoot: settings.profilesRootURL)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        let cwd = record.workingDirectory(in: project)
        let launchedAfter = Date().addingTimeInterval(-2)
        let recordID = record.id

        Task.detached(priority: .utility) {
            for _ in 0..<60 {
                let candidates = CodexSessionLocator.candidates(
                    codexHome: codexHome,
                    cwd: cwd,
                    modifiedAfter: launchedAfter
                )
                for candidate in candidates {
                    let claimed = await MainActor.run {
                        projectStore.claimProviderSessionID(candidate.id, for: recordID)
                    }
                    if claimed { return }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
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
        if record.provider != .terminal {
            env.append("UNCOIL_SESSION_ID=\(record.id.uuidString)")
            env.append("UNCOIL_PROJECT_ID=\(record.projectID.uuidString)")
            env.append("UNCOIL_CONTROL_SOCKET=\(ControlPlaneServer.defaultSocketPath())")
        }
        return env
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

    /// Writes a per-session MCP config registering the bundled `uncoil-mcp`
    /// server, and returns its path. We never touch the user's ~/.claude.json;
    /// Claude Code merges this file via `--mcp-config` (additive, not strict).
    private func bundledMCPBinaryPath() -> String? {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uncoil-mcp")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary.path : nil
    }

    private func writeMCPConfig(for record: SessionRecord, binaryPath: String) -> String? {
        let config: [String: Any] = [
            "mcpServers": [
                "uncoil": [
                    "command": binaryPath,
                    "env": [
                        "UNCOIL_SESSION_ID": record.id.uuidString,
                        "UNCOIL_PROJECT_ID": record.projectID.uuidString,
                        "UNCOIL_CONTROL_SOCKET": ControlPlaneServer.defaultSocketPath(),
                    ],
                ],
            ],
        ]
        let dir = ProjectStore.defaultDirectory().appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(record.id.uuidString).json")
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            return nil
        }
        try? data.write(to: fileURL, options: .atomic)
        return fileURL.path
    }

    /// Shell arguments launching the agent. `exec` replaces the shell so the
    /// user never sees a typed command and closing the agent ends the session.
    /// -i: also source ~/.zshrc, for users whose PATH is set there.
    private func shellArguments(for record: SessionRecord, settings: SettingsStore) -> (shell: String, args: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var args: [String] = ["-l"]
        let mcpBinaryPath = record.provider == .terminal ? nil : bundledMCPBinaryPath()
        let mcpConfigPath = record.provider == .claude
            ? mcpBinaryPath.flatMap { writeMCPConfig(for: record, binaryPath: $0) }
            : nil
        let mcpEnvironment = [
            "UNCOIL_CONTROL_SOCKET": ControlPlaneServer.defaultSocketPath(),
            "UNCOIL_PROJECT_ID": record.projectID.uuidString,
            "UNCOIL_SESSION_ID": record.id.uuidString,
        ]
        if let command = Self.launchCommand(
            for: record,
            binaryPath: settings.binaryPath(for: record.provider),
            mcpConfigPath: mcpConfigPath,
            mcpBinaryPath: mcpBinaryPath,
            mcpEnvironment: mcpEnvironment,
            extraArguments: settings.extraArguments[record.provider.rawValue],
            presetArguments: record.extraArguments,
            modeArguments: settings.workingModeArguments(for: record.provider)
        ) {
            args = ["-l", "-i", "-c", "exec \(command)"]
        }
        return (shell, args)
    }

    private func applyTheme(_ view: TerminalView) {
        let palette = ThemeStore.shared.palette
        view.nativeBackgroundColor = NSColor(Color(hex: palette.terminalBg))
        view.nativeForegroundColor = NSColor(Color(hex: palette.terminalFg))
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
        let mode = settings.workingMode(for: .codex)
        let approvalPolicy: String
        let sandbox: String
        switch mode {
        case .approveForMe:
            approvalPolicy = "never"
            sandbox = "workspace-write"
        case .fullAccess:
            approvalPolicy = "never"
            sandbox = "danger-full-access"
        default:
            approvalPolicy = "on-request"
            sandbox = "workspace-write"
        }
        var config: [String: JSONValue] = [:]
        if let mcpBinaryPath = bundledMCPBinaryPath() {
            config["mcp_servers"] = .object([
                "uncoil": .object([
                    "command": .string(mcpBinaryPath),
                    "env": .object([
                        "UNCOIL_CONTROL_SOCKET": .string(ControlPlaneServer.defaultSocketPath()),
                        "UNCOIL_PROJECT_ID": .string(record.projectID.uuidString),
                        "UNCOIL_SESSION_ID": .string(record.id.uuidString),
                    ]),
                ]),
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
                TerminalRegistry.shared.codexSessions[recordID] = nil
                TerminalRegistry.shared.configureRuntimeTerminal(
                    view,
                    record: record,
                    project: project,
                    account: account,
                    settings: settings,
                    sessionStore: sessionStore,
                    projectStore: projectStore
                )
                sessionStore.setStatus(.idle, detail: "PTY fallback: \(reason)", for: recordID)
            }
        )
        let delegate = CodexStructuredTerminalDelegate(session: session, terminal: view)
        view.terminalDelegate = delegate
        delegates[record.id] = delegate
        codexSessions[record.id] = session
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
        let provider = record.provider
        view.resolveShiftEnterNewline = { [weak settings] in
            settings?.shiftEnterNewline(for: provider) ?? provider.defaultShiftEnterNewline
        }

        let (shell, args) = shellArguments(for: record, settings: settings)
        let spec = RuntimeClient.LaunchSpec(
            shell: shell,
            args: args,
            env: environment(for: account, settings: settings, record: record),
            cwd: record.workingDirectory(in: project)
        )

        let delegate = RuntimeTerminalDelegate(recordID: record.id)
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
                sessionStore?.setStatus(.terminated, for: recordID)
                projectStore?.markSessionEnded(recordID, exitCode: code)
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
        let provider = record.provider
        view.resolveShiftEnterNewline = { [weak settings] in
            settings?.shiftEnterNewline(for: provider) ?? provider.defaultShiftEnterNewline
        }
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
        let (shell, args) = shellArguments(for: record, settings: settings)
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

    func closeTerminal(for recordID: UUID) {
        codexSessions[recordID]?.stop()
        codexSessions[recordID] = nil
        RuntimeClient.shared.kill(sid: recordID)
        terminals[recordID] = nil
        delegates[recordID] = nil
        deadSessions.remove(recordID)
    }

    func prepareForApplicationTermination(terminateSessions: Bool) {
        codexSessions.values.forEach {
            $0.prepareForApplicationTermination(terminateServer: terminateSessions)
        }
        codexSessions.removeAll()
    }

    func submitText(_ text: String, for recordID: UUID, provider: AgentProvider) async {
        if let session = codexSessions[recordID] {
            session.submit(text)
            return
        }
        await RuntimeClient.shared.waitUntilInputReady(sid: recordID, provider: provider)
        await RuntimeClient.shared.submitText(text, sid: recordID, provider: provider)
    }

    func sendRaw(_ data: Data, for recordID: UUID) {
        guard codexSessions[recordID] == nil else {
            if let text = String(data: data, encoding: .utf8) {
                codexSessions[recordID]?.submit(text.trimmingCharacters(in: .newlines))
            }
            return
        }
        RuntimeClient.shared.sendText(data, sid: recordID)
    }

    func interrupt(_ recordID: UUID) {
        if let session = codexSessions[recordID] {
            session.interrupt()
        } else {
            RuntimeClient.shared.interrupt(sid: recordID)
        }
    }

    func respondToCodexApproval(
        sessionID: UUID,
        request: CodexApprovalRequest,
        decision: String
    ) {
        codexSessions[sessionID]?.respondToApproval(request, decision: decision)
    }

    func output(for recordID: UUID) async -> Data? {
        if let session = codexSessions[recordID] {
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
        mcpConfigPath: String? = nil,
        mcpBinaryPath: String? = nil,
        mcpEnvironment: [String: String] = [:],
        extraArguments: String?,
        presetArguments: [String]? = nil,
        modeArguments: [String] = []
    ) -> String? {
        guard let name = record.provider.launchCommand else { return nil }
        var command = binaryPath.map { "\"\($0)\"" } ?? name
        if record.provider == .claude, let sid = record.providerSessionID {
            command += " --resume \(shellQuote(sid))"
        }
        if record.provider == .codex, let sid = record.providerSessionID {
            command += " resume \(shellQuote(sid))"
        }
        if record.provider == .claude, let mcpConfigPath {
            command += " --mcp-config \"\(mcpConfigPath)\""
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
        if !modeArguments.isEmpty {
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
}

/// Routes terminal-view events to the runtime daemon.
final class RuntimeTerminalDelegate: TerminalViewDelegate {
    private let recordID: UUID

    init(recordID: UUID) {
        self.recordID = recordID
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        RuntimeClient.shared.sendInput(Data(data), sid: recordID)
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
            sessionStore?.setStatus(.terminated, for: id)
            projectStore?.markSessionEnded(id, exitCode: exitCode)
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
