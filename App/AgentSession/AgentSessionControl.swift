import Foundation

/// The way into an agent session — the mirror of `AgentEvent`, which is the
/// way out.
///
/// Everything that acts on a session — the prompt bar, a handoff, a repair
/// prompt, the control plane, an approval panel — goes through this, and
/// never asks whether there is a PTY behind it. A session driven over a
/// structured protocol and a session that is only a terminal both answer the
/// same calls; what differs is declared in `capabilities`, so a caller can
/// tell "not supported here" from "failed".
@MainActor
protocol AgentSessionControl: AnyObject {
    var sessionID: UUID { get }
    var capabilities: AgentControlCapabilities { get }

    /// Starts a turn with the prompt.
    func submit(_ prompt: String) async
    /// Puts the prompt where the user can edit it, without starting a turn.
    func draft(_ prompt: String) async
    /// Hands files to the session for the prompt being written. Like a draft,
    /// it starts nothing: the user still says what the files are for.
    func attach(_ attachments: [AgentAttachment]) async
    /// Stops the turn in progress.
    func interrupt()
    /// Answers a pending approval by its `AgentApproval.id`. False when the
    /// session has no such approval.
    @discardableResult
    func respond(toApproval approvalID: String, decision: String) -> Bool
    /// Bytes as if typed. Only meaningful with `.rawInput`; a structured
    /// session reads them as a prompt.
    func sendRaw(_ data: Data)
}

struct AgentControlCapabilities: OptionSet, Equatable {
    let rawValue: Int

    /// Prompts arrive as structured turns, not as keystrokes into a TUI.
    static let structuredTurns = AgentControlCapabilities(rawValue: 1 << 0)
    /// Approvals are answered through Uncoil, not in the agent's own UI.
    static let approvals = AgentControlCapabilities(rawValue: 1 << 1)
    /// The session is a terminal and accepts raw keystrokes.
    static let rawInput = AgentControlCapabilities(rawValue: 1 << 2)
    /// The session publishes `AgentEvent`s, so its timeline is authoritative.
    static let events = AgentControlCapabilities(rawValue: 1 << 3)
    /// Images reach the agent as images, not as paths it may or may not open.
    static let imageAttachments = AgentControlCapabilities(rawValue: 1 << 4)

    var names: [String] {
        [
            (Self.structuredTurns, "structured_turns"),
            (Self.approvals, "approvals"),
            (Self.rawInput, "raw_input"),
            (Self.events, "events"),
            (Self.imageAttachments, "image_attachments"),
        ]
        .filter { contains($0.0) }
        .map(\.1)
    }
}

/// A session that is only a terminal: its agent's own TUI reads what is typed.
///
/// This is the escape hatch, and it stays one. It carries what keystroke
/// delivery has always needed — waiting for the TUI to be ready, the
/// provider's own Enter, bracketed paste — so nothing above it has to.
@MainActor
final class PTYAgentSessionControl: AgentSessionControl {
    let sessionID: UUID
    let capabilities: AgentControlCapabilities = [.rawInput]

    private let provider: AgentProvider
    private let runtime: RuntimeClient
    private let bracketedPaste: () -> Bool

    init(
        sessionID: UUID,
        provider: AgentProvider,
        runtime: RuntimeClient = .shared,
        bracketedPaste: @escaping () -> Bool
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.runtime = runtime
        self.bracketedPaste = bracketedPaste
    }

    func submit(_ prompt: String) async {
        await runtime.waitUntilInputReady(sid: sessionID, provider: provider)
        await runtime.submitText(deliverable(prompt), sid: sessionID, provider: provider)
    }

    func draft(_ prompt: String) async {
        await runtime.waitUntilInputReady(sid: sessionID, provider: provider)
        runtime.sendText(
            RuntimeClient.submissionParts(deliverable(prompt), provider: provider)[0],
            sid: sessionID
        )
    }

    func attach(_ attachments: [AgentAttachment]) async {
        // A terminal agent reads files from disk; the path is the attachment.
        await draft(SessionImageDrop.promptFragment(relativePaths: attachments.map(\.promptPath)))
    }

    func interrupt() {
        runtime.interrupt(sid: sessionID)
    }

    func respond(toApproval approvalID: String, decision: String) -> Bool {
        // The agent asks in its own TUI; the answer is typed there.
        false
    }

    func sendRaw(_ data: Data) {
        runtime.sendText(data, sid: sessionID)
    }

    private func deliverable(_ text: String) -> String {
        TerminalRegistry.deliverable(text, bracketedPaste: bracketedPaste())
    }
}
