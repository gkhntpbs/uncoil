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

    func hasTerminal(for recordID: UUID) -> Bool {
        terminals[recordID] != nil
    }

    func terminal(
        for record: SessionRecord,
        project: Project,
        account: AccountProfile?,
        settings: SettingsStore,
        sessionStore: SessionStore
    ) -> LocalProcessTerminalView {
        if let existing = terminals[record.id] {
            return existing
        }

        let view = LocalProcessTerminalView(frame: .zero)
        view.nativeBackgroundColor = NSColor(Theme.bg)
        view.nativeForegroundColor = NSColor(Theme.text)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        if let dir = account?.configDirectory(profilesRoot: settings.profilesRootURL) {
            env.append("CLAUDE_CONFIG_DIR=\(dir.path)")
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var args: [String] = ["-l"]
        if var command = record.provider.launchCommand {
            // Reopening a Claude session with a known provider id resumes it.
            if record.provider == .claude, let sid = record.providerSessionID {
                command += " --resume \(sid)"
            }
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

        sessionStore.setStatus(record.provider == .terminal ? .idle : .running, for: record.id)
        return view
    }

    func closeTerminal(for recordID: UUID) {
        terminals[recordID] = nil
        delegates[recordID] = nil
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
            TerminalRegistry.shared.closeTerminal(for: id)
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
