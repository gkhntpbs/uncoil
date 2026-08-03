import XCTest
@testable import Uncoil

/// The list of providers was written out by hand in twenty-two places — some
/// including the terminal, some not, and nothing said which was which. Adding a
/// provider meant finding all of them, and missing one meant an agent that
/// existed everywhere except the screen that was forgotten.
///
/// These tests are the reason the lists can now be trusted: they are derived
/// from the cases, so the next provider joins them by construction.
final class AgentProviderListTests: XCTestCase {
    func testEveryCaseIsEitherAnAgentOrAShell() {
        XCTAssertEqual(
            Set(AgentProvider.agents).union([.terminal]),
            Set(AgentProvider.allCases),
            "a new provider has to be classified, not silently dropped from both lists"
        )
    }

    func testTheAgentListIsExactlyTheProvidersThatRunAnAgent() {
        XCTAssertEqual(AgentProvider.agents, AgentProvider.allCases.filter(\.isAgent))
        XCTAssertFalse(AgentProvider.agents.contains(.terminal))
        XCTAssertFalse(AgentProvider.agents.isEmpty)
    }

    func testSessionKindsCoversEveryCase() {
        XCTAssertEqual(Set(AgentProvider.sessionKinds), Set(AgentProvider.allCases))
        XCTAssertTrue(AgentProvider.sessionKinds.contains(.terminal))
    }

    /// Both lists are shown to the user, so their order is a design decision
    /// rather than an accident of the enum: agents first, the plain shell last.
    func testTheShellIsOfferedLast() {
        XCTAssertEqual(AgentProvider.sessionKinds.last, .terminal)
        XCTAssertEqual(
            Array(AgentProvider.sessionKinds.dropLast()), AgentProvider.agents
        )
    }

    /// What separates the two lists, stated once: an agent is a thing Uncoil
    /// launches and tracks, and everything that follows from that — hooks,
    /// the control plane, a status — hangs off this answer.
    func testAnAgentIsSomethingUncoilLaunches() {
        for provider in AgentProvider.agents {
            XCTAssertNotNil(
                provider.launchCommand,
                "\(provider.rawValue) is listed as an agent but launches nothing"
            )
        }
        XCTAssertNil(AgentProvider.terminal.launchCommand)
    }
}
