import AppKit
import SwiftUI
import SwiftTerm

/// One live terminal per session record. PTYs are owned by uncoil-runtimed
/// (RuntimeClient) so agents survive app restarts; if the daemon is
/// unreachable we fall back to an in-process PTY that dies with the app.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var terminals: [UUID: TerminalView] = [:]
    private var delegates: [UUID: AnyObject] = [:]
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
        sessionStore: SessionStore
    ) -> TerminalView {
        if let existing = terminals[record.id], !deadSessions.contains(record.id) {
            return existing
        }
        deadSessions.remove(record.id)

        let view: TerminalView
        // Runtime path only when the daemon was actually started (not in UI
        // tests) and hasn't failed; anything else uses the in-process PTY.
        let runtimePhase = RuntimeClient.shared.phase
        if runtimePhase == .connecting || runtimePhase == .ready {
            view = makeRuntimeTerminal(record: record, project: project, account: account,
                                       settings: settings, sessionStore: sessionStore)
        } else {
            view = makeInProcessTerminal(record: record, project: project, account: account,
                                         settings: settings, sessionStore: sessionStore)
        }
        terminals[record.id] = view

        // The agent starts ready-and-waiting; hooks flip it to thinking/
        // running as real work happens. Deferred: this runs from makeNSView
        // (a view-update pass) where publishing changes is not allowed.
        let recordID = record.id
        DispatchQueue.main.async { [weak sessionStore] in
            sessionStore?.setStatus(.idle, for: recordID)
        }
        return view
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

    /// Writes a per-session MCP config registering the bundled `uncoil-mcp`
    /// server, and returns its path. We never touch the user's ~/.claude.json;
    /// Claude Code merges this file via `--mcp-config` (additive, not strict).
    private func writeMCPConfig(for record: SessionRecord) -> String? {
        guard let mcpBinary = Bundle.main.url(forResource: "uncoil-mcp", withExtension: nil) else {
            return nil
        }
        let config: [String: Any] = [
            "mcpServers": [
                "uncoil": [
                    "command": mcpBinary.path,
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
        // Register the uncoil MCP server for Claude Code (additive config,
        // never touching ~/.claude.json). Codex auto-injection is deferred.
        let mcpConfigPath = record.provider == .claude ? writeMCPConfig(for: record) : nil
        if let command = Self.launchCommand(
            for: record,
            binaryPath: settings.binaryPath(for: record.provider),
            mcpConfigPath: mcpConfigPath,
            extraArguments: settings.extraArguments[record.provider.rawValue]
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

    // MARK: - Daemon-backed terminal

    private func makeRuntimeTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore
    ) -> TerminalView {
        let view = TerminalView(frame: .zero)
        applyTheme(view)

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
            onData: { [weak view] data in
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            },
            onExit: { [weak sessionStore] _ in
                sessionStore?.setStatus(.terminated, for: recordID)
                TerminalRegistry.shared.markDead(recordID)
            }
        )
        return view
    }

    // MARK: - In-process fallback (daemon unreachable)

    private func makeInProcessTerminal(
        record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore
    ) -> TerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        applyTheme(view)
        let (shell, args) = shellArguments(for: record, settings: settings)
        view.startProcess(
            executable: shell,
            args: args,
            environment: environment(for: account, settings: settings, record: record),
            execName: nil,
            currentDirectory: record.workingDirectory(in: project)
        )
        let delegate = SessionProcessDelegate(recordID: record.id, sessionStore: sessionStore)
        view.processDelegate = delegate
        delegates[record.id] = delegate
        return view
    }

    func closeTerminal(for recordID: UUID) {
        RuntimeClient.shared.kill(sid: recordID)
        terminals[recordID] = nil
        delegates[recordID] = nil
        deadSessions.remove(recordID)
    }

    /// Full command line for a provider session (nil = plain shell).
    /// Prefers the resolved absolute binary path so launch works even when
    /// the login shell's PATH misses user-local install dirs.
    /// Kept static and pure so tests can cover resume/extra-arg composition.
    nonisolated static func launchCommand(
        for record: SessionRecord,
        binaryPath: String? = nil,
        mcpConfigPath: String? = nil,
        extraArguments: String?
    ) -> String? {
        guard let name = record.provider.launchCommand else { return nil }
        var command = binaryPath.map { "\"\($0)\"" } ?? name
        if record.provider == .claude, let sid = record.providerSessionID {
            command += " --resume \(sid)"
        }
        if record.provider == .claude, let mcpConfigPath {
            command += " --mcp-config \"\(mcpConfigPath)\""
        }
        if let extra = extraArguments?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
            command += " " + extra
        }
        return command
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

    init(recordID: UUID, sessionStore: SessionStore) {
        self.recordID = recordID
        self.sessionStore = sessionStore
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = recordID
        Task { @MainActor [weak sessionStore] in
            sessionStore?.setStatus(.terminated, for: id)
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

    func makeNSView(context: Context) -> TerminalView {
        TerminalRegistry.shared.terminal(
            for: record,
            project: project,
            account: account,
            settings: settings,
            sessionStore: sessionStore
        )
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
