import XCTest
@testable import Uncoil

/// A crash is hard to stage on demand, so the classification is tested rather
/// than reproduced. Both directions cost something: crying crash at every
/// clean exit teaches people to ignore the row, and missing a real one is the
/// bug this exists to fix.
final class SessionExitTests: XCTestCase {
    func testAZeroExitIsClean() {
        XCTAssertEqual(SessionExit.classify(exitCode: 0, isAgent: true), .clean)
        XCTAssertFalse(SessionExit.classify(exitCode: 0, isAgent: true).isCrash)
    }

    func testANonZeroExitFromAnAgentIsACrash() {
        XCTAssertEqual(
            SessionExit.classify(exitCode: 1, isAgent: true), .crashed(code: 1)
        )
        XCTAssertTrue(SessionExit.classify(exitCode: 139, isAgent: true).isCrash)
    }

    /// A shell that exits non-zero has run a command that failed and then been
    /// closed. Calling that a crash would fire on every `exit 1`.
    func testAShellExitingNonZeroIsNotACrash() {
        XCTAssertEqual(SessionExit.classify(exitCode: 1, isAgent: false), .clean)
        XCTAssertEqual(SessionExit.classify(exitCode: 139, isAgent: false), .clean)
    }

    /// No code means Uncoil lost the process rather than watched it exit — the
    /// daemon went away, or the user closed the session. Not knowing is not a
    /// crash, and reporting one would fire every time the daemon restarts.
    func testNoExitCodeIsUnknownRatherThanACrash() {
        XCTAssertEqual(SessionExit.classify(exitCode: nil, isAgent: true), .unknown)
        XCTAssertFalse(SessionExit.classify(exitCode: nil, isAgent: true).isCrash)
    }

    /// The reason is written in the terms the exit was reported in: a shell
    /// reports a signal as 128 + its number, and "killed by signal 11" is what
    /// someone can act on, where "exit code 139" is a number to go look up.
    func testASignalIsNamedAsASignal() {
        XCTAssertEqual(SessionExit.crashed(code: 139).reason, "killed by signal 11")
        XCTAssertEqual(SessionExit.crashed(code: 137).reason, "killed by signal 9")
        XCTAssertEqual(SessionExit.crashed(code: 2).reason, "exit code 2")
    }

    func testACleanExitHasNothingToReport() {
        XCTAssertNil(SessionExit.clean.reason)
        XCTAssertNil(SessionExit.unknown.reason)
    }

    /// The row has to escalate the menu-bar icon and be allowed to raise a
    /// banner; a crash nobody is shown is the same as no detection at all.
    func testTheAttentionRowCountsAsAProblem() {
        XCTAssertTrue(AttentionKind.agentCrashed.isProblem)
        XCTAssertFalse(AttentionKind.agentCrashed.isTaskRow)
        XCTAssertEqual(AttentionKind.agentCrashed.notificationEvent, .problem)
    }
}
