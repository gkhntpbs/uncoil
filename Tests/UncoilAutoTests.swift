import XCTest
@testable import Uncoil

/// Uncoil Auto is a session kind of its own: offered where sessions are
/// started, drawn as a chat, and never mistaken for an agent CLI or a shell.
@MainActor
final class UncoilAutoTests: XCTestCase {
    func testOnlyUncoilAutoIsDrawnAsAChat() {
        for provider in AgentProvider.allCases {
            XCTAssertEqual(
                TerminalRegistry.surface(for: provider),
                provider == .uncoil ? .chat : .terminal,
                "\(provider) keeps its own interface"
            )
        }
    }

    func testItIsASessionKindButNotAnAgent() {
        XCTAssertTrue(AgentProvider.sessionKinds.contains(.uncoil))
        XCTAssertFalse(AgentProvider.agents.contains(.uncoil))
        XCTAssertEqual(AgentProvider.uncoil.displayName, "Uncoil Auto")
        XCTAssertNil(AgentProvider.uncoil.launchCommand)
        XCTAssertFalse(AgentProvider.uncoil.wiresControlPlane)
    }

    func testQuickLaunchOffersItWithoutAnInstall() {
        let strip = LauncherPrefs.resolved(.default, installed: [.claude])
        XCTAssertTrue(strip.contains(.uncoil), "nothing to install, so nothing to hide it behind")
        XCTAssertEqual(LauncherPrefs.resolved(LauncherPrefs(order: [.uncoil]), installed: []), [.uncoil])
    }

    func testItIsNeverHandedALogin() {
        let request = SessionLaunchRequest(
            project: Project(name: "p", rootPath: "/tmp/p"),
            provider: .uncoil,
            account: AccountProfile(provider: .claude, name: "work")
        )
        XCTAssertNil(request.accountID)
        XCTAssertTrue(SessionRecord(projectID: UUID(), provider: .uncoil, accountID: nil, title: request.title).hasPlaceholderTitle)
    }
}
