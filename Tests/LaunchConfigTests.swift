import XCTest
@testable import Uncoil

final class LaunchConfigTests: XCTestCase {
    func testRuntimeMismatchFixtureRequiresUITesting() {
        XCTAssertTrue(LaunchConfig(arguments: [
            "Uncoil",
            "-ui-testing",
            "-runtime-mismatch-fixture",
        ]).runtimeMismatchFixture)
        XCTAssertFalse(LaunchConfig(arguments: [
            "Uncoil",
            "-runtime-mismatch-fixture",
        ]).runtimeMismatchFixture)
    }

    /// A Codex session runs the Codex CLI. The app-server protocol client is
    /// still there — structured approvals and turn state are built on it — but
    /// nothing reaches for it unless it is asked for by name.
    func testCodexAppServerAndApprovalFixturesRequireExplicitOptIn() {
        let regular = LaunchConfig(arguments: ["Uncoil"])
        XCTAssertFalse(regular.codexAppServerEnabled)
        XCTAssertFalse(regular.codexApprovalFixture)

        let uiDefault = LaunchConfig(arguments: ["Uncoil", "-ui-testing"])
        XCTAssertFalse(uiDefault.codexAppServerEnabled)
        XCTAssertFalse(uiDefault.codexApprovalFixture)

        let optIn = LaunchConfig(arguments: ["Uncoil", "-codex-app-server"])
        XCTAssertTrue(optIn.codexAppServerEnabled)

        let uiOptIn = LaunchConfig(arguments: [
            "Uncoil",
            "-ui-testing",
            "-codex-app-server",
            "-codex-approval-fixture",
        ])
        XCTAssertTrue(uiOptIn.codexAppServerEnabled)
        XCTAssertTrue(uiOptIn.codexApprovalFixture)
    }

    func testAttentionFixtureRequiresUITesting() {
        XCTAssertFalse(
            LaunchConfig(arguments: ["Uncoil", "-attention-fixture"]).attentionFixture
        )
        XCTAssertTrue(
            LaunchConfig(arguments: ["Uncoil", "-ui-testing", "-attention-fixture"])
                .attentionFixture
        )
    }
}
