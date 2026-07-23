import AppKit
import SwiftUI
import SwiftTerm

/// One live PTY per session record. Terminals survive sidebar navigation;
/// they die with the app (persistent runtime comes later).
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]
    private var delegates: [UUID: SessionProcessDelegate] = [:]
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
    ) -> LocalProcessTerminalView {
        if let existing = terminals[record.id], !deadSessions.contains(record.id) {
            return existing
        }
        deadSessions.remove(record.id)

        let view = LocalProcessTerminalView(frame: .zero)
        view.nativeBackgroundColor = NSColor(Theme.bg)
        view.nativeForegroundColor = NSColor(Theme.text)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        // SwiftTerm's helper env has no HOME/USER/PATH — without HOME the
        // login shell never reads ~/.zprofile and user-installed CLIs
        // (~/.local/bin/claude) are not on PATH.
        let processEnv = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR"] {
            if let value = processEnv[key] {
                env.append("\(key)=\(value)")
            }
        }
        if let dir = account?.configDirectory(profilesRoot: settings.profilesRootURL) {
            env.append("CLAUDE_CONFIG_DIR=\(dir.path)")
        }

        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        var args: [String] = ["-l"]
        if let command = Self.launchCommand(
            for: record,
            binaryPath: settings.binaryPath(for: record.provider),
            extraArguments: settings.extraArguments[record.provider.rawValue]
        ) {
            // `exec` replaces the shell with the agent: the user never sees
            // a typed command, and closing the agent closes the session.
            args = ["-l", "-c", "exec \(command)"]
        }
        view.startProcess(
            executable: shell,
            args: args,
            environment: env,
            execName: nil,
            currentDirectory: record.workingDirectory(in: project)
        )

        let delegate = SessionProcessDelegate(recordID: record.id, sessionStore: sessionStore)
        view.processDelegate = delegate
        delegates[record.id] = delegate
        terminals[record.id] = view

        // The agent starts ready-and-waiting; hooks flip it to thinking/
        // running as real work happens.
        sessionStore.setStatus(.idle, for: record.id)
        return view
    }

    func closeTerminal(for recordID: UUID) {
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
        extraArguments: String?
    ) -> String? {
        guard let name = record.provider.launchCommand else { return nil }
        var command = binaryPath.map { "\"\($0)\"" } ?? name
        if record.provider == .claude, let sid = record.providerSessionID {
            command += " --resume \(sid)"
        }
        if let extra = extraArguments?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
            command += " " + extra
        }
        return command
    }
}

/// Marks the session terminated when its process exits.
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

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        TerminalRegistry.shared.terminal(
            for: record,
            project: project,
            account: account,
            settings: settings,
            sessionStore: sessionStore
        )
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
