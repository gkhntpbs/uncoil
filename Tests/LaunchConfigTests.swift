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
}
