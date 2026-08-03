import XCTest
@testable import Uncoil

/// Which login a session runs under is decided once, when the process starts:
/// the account is a config directory handed to the agent in its environment.
/// So the question a picker has to answer honestly is not "did it change" but
/// "does the running agent know". Letting someone believe they had switched
/// while the agent went on as the other account is the worst outcome here, and
/// it is the one these tests exist to prevent.
final class SessionAccountChangeTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()

    func testPickingTheSameAccountDoesNothing() {
        XCTAssertEqual(
            SessionAccountChange.classify(current: a, chosen: a, isRunning: true), .unchanged
        )
        XCTAssertNil(SessionAccountChange.unchanged.note)
    }

    func testAStoppedSessionJustTakesTheNewAccount() {
        XCTAssertEqual(
            SessionAccountChange.classify(current: a, chosen: b, isRunning: false), .recorded
        )
    }

    /// The one that matters: the environment is set at launch, so a live agent
    /// keeps the account it started with however the record now reads.
    func testARunningSessionHasToBeRestarted() {
        XCTAssertEqual(
            SessionAccountChange.classify(current: a, chosen: b, isRunning: true), .needsRestart
        )
    }

    func testASessionWithNoAccountYetCanBeGivenOne() {
        XCTAssertEqual(
            SessionAccountChange.classify(current: nil, chosen: a, isRunning: false), .recorded
        )
        XCTAssertEqual(
            SessionAccountChange.classify(current: nil, chosen: nil, isRunning: false), .unchanged
        )
    }

    /// Every outcome that changed something says so; silence is reserved for
    /// the case where nothing happened.
    func testEveryRealChangeIsExplained() {
        XCTAssertNotNil(SessionAccountChange.recorded.note)
        XCTAssertNotNil(SessionAccountChange.needsRestart.note)
        XCTAssertNotEqual(
            SessionAccountChange.recorded.note, SessionAccountChange.needsRestart.note,
            "the two cases mean different things and cannot share one message"
        )
    }
}
