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

    func testCodexAppServerAndApprovalFixturesRequireExplicitOptIn() {
        let regular = LaunchConfig(arguments: ["Uncoil"])
        XCTAssertTrue(regular.codexAppServerEnabled)
        XCTAssertFalse(regular.codexApprovalFixture)

        let uiDefault = LaunchConfig(arguments: ["Uncoil", "-ui-testing"])
        XCTAssertFalse(uiDefault.codexAppServerEnabled)
        XCTAssertFalse(uiDefault.codexApprovalFixture)

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
