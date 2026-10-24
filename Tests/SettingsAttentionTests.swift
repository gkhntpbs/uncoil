import XCTest
@testable import Uncoil

/// The Settings gear's badge leads to its own source.
@MainActor
final class SettingsAttentionTests: XCTestCase {
    func testNothingPendingKeepsTheLastPage() {
        XCTAssertNil(SettingsAttention.pane(for: []))
    }

    func testOneUpdateOpensThatAgentsPage() {
        let pane = SettingsAttention.pane(for: [.codex])
        XCTAssertEqual(pane, "agent.codex")
        XCTAssertEqual(pane.flatMap(SettingsView.Pane.resolve), .agent(.codex))
    }

    func testSeveralUpdatesOpenTheAgentList() {
        XCTAssertEqual(SettingsAttention.pane(for: [.claude, .codex]), "agents")
    }
}
