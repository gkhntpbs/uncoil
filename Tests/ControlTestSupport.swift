import Foundation
@testable import Uncoil

/// A running session, as the control plane sees one: an `AgentSessionControl`
/// that records what it was asked to do instead of reaching an agent.
@MainActor
final class FakeAgentSessionControl: AgentSessionControl {
    let sessionID: UUID
    var capabilities: AgentControlCapabilities
    var isReady = true
    private(set) var submitted: [String] = []
    private(set) var drafted: [String] = []
    private(set) var raw: [Data] = []
    private(set) var interrupts = 0
    private(set) var answers: [(approvalID: String, decision: String)] = []
    /// Approvals the fake will accept an answer for.
    var pendingApprovalIDs: Set<String> = []
    /// Runs on submit — a test uses it to publish the events a real turn would.
    var onSubmit: ((String) -> Void)?

    init(sessionID: UUID, capabilities: AgentControlCapabilities) {
        self.sessionID = sessionID
        self.capabilities = capabilities
    }

    /// A Codex-like structured session.
    static func structured(_ id: UUID) -> FakeAgentSessionControl {
        FakeAgentSessionControl(
            sessionID: id, capabilities: [.structuredTurns, .approvals, .events, .imageAttachments])
    }

    /// A session that is only a terminal.
    static func terminal(_ id: UUID) -> FakeAgentSessionControl {
        FakeAgentSessionControl(sessionID: id, capabilities: [.rawInput])
    }

    func submit(_ prompt: String) async {
        submitted.append(prompt)
        onSubmit?(prompt)
    }
    func draft(_ prompt: String) async { drafted.append(prompt) }
    func attach(_ attachments: [AgentAttachment]) async {}
    func interrupt() { interrupts += 1 }
    func respond(toApproval approvalID: String, decision: String) -> Bool {
        guard pendingApprovalIDs.contains(approvalID) else { return false }
        pendingApprovalIDs.remove(approvalID)
        answers.append((approvalID, decision))
        return true
    }
    func sendRaw(_ data: Data) { raw.append(data) }
}
