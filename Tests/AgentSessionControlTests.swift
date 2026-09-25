import XCTest
@testable import Uncoil

@MainActor
final class AgentSessionControlTests: XCTestCase {
    func testSessionWithoutStructuredIntegrationIsATerminal() {
        let id = UUID()
        let control = TerminalRegistry.shared.control(for: id, provider: .claude)
        XCTAssertTrue(control is PTYAgentSessionControl)
        XCTAssertEqual(control.sessionID, id)
        XCTAssertEqual(control.capabilities, [.rawInput])
        // A terminal's approvals are answered in its own TUI.
        XCTAssertFalse(control.respond(toApproval: "any", decision: "accept"))
    }

    func testCapabilityNamesAreStable() {
        let all: AgentControlCapabilities = [.structuredTurns, .approvals, .rawInput, .events]
        XCTAssertEqual(all.names, ["structured_turns", "approvals", "raw_input", "events"])
        XCTAssertEqual(AgentControlCapabilities().names, [])
    }
}
