import AppKit
import Foundation
import SwiftTerm

/// A session driven over a provider's structured protocol rather than a PTY:
/// the Codex app server, `claude -p` in stream-json mode. What the terminal
/// registry needs from one beyond `AgentSessionControl` — its lifecycle and
/// what it has drawn.
@MainActor
protocol StructuredAgentSession: AgentSessionControl {
    /// Ends the session. `terminateServer` false leaves a server that outlives
    /// the app running, for a provider that has one.
    func stop(terminateServer: Bool)
    func prepareForApplicationTermination(terminateServer: Bool)
    /// What the terminal has shown, for `read_output` and summaries.
    func outputSnapshot() async -> Data
}

/// The terminal of a structured session: a line editor in front of the
/// session's own `submit` and `interrupt`. Provider-neutral — it never knows
/// which protocol is behind the session it types into.
final class StructuredSessionTerminalDelegate: TerminalViewDelegate {
    private weak var session: (any AgentSessionControl)?
    private weak var terminal: TerminalView?
    private var editor = PromptLineEditor()

    init(session: any AgentSessionControl, terminal: TerminalView) {
        self.session = session
        self.terminal = terminal
    }

    /// Puts a dispatched prompt into the line editor without submitting it, so
    /// the user starts the turn themselves.
    func prefill(_ text: String) {
        editor.prefill(text)
        redraw()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let actions = editor.consume(data)
        redraw()
        for action in actions {
            switch action {
            case .interrupt:
                Task { @MainActor [weak session] in session?.interrupt() }
            case .submit(let prompt):
                echo("\r\n")
                Task { @MainActor [weak session] in await session?.submit(prompt) }
            }
        }
    }

    /// Repaints the prompt line from the editor's state, which is what lets an
    /// edit happen anywhere in the line rather than only at its end.
    private func redraw() {
        echo(PromptLineRenderer.render(text: editor.text, cursor: editor.cursor))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
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

    private func echo(_ text: String) {
        terminal?.feed(byteArray: ArraySlice([UInt8](text.utf8)))
    }
}
