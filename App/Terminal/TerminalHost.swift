import AppKit
import SwiftUI
import SwiftTerm

/// Keeps one live terminal per project so switching in the sidebar
/// never kills a running agent.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for project: Project) -> LocalProcessTerminalView {
        if let existing = terminals[project.id] {
            return existing
        }
        let view = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: nil,
            currentDirectory: project.rootPath
        )
        terminals[project.id] = view
        return view
    }

    func send(text: String, to project: Project) {
        terminals[project.id]?.send(txt: text)
    }

    func hasTerminal(for project: Project) -> Bool {
        terminals[project.id] != nil
    }
}

struct TerminalHostView: NSViewRepresentable {
    let project: Project

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        TerminalRegistry.shared.terminal(for: project)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
