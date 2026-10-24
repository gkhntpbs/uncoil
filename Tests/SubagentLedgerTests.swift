import XCTest
@testable import Uncoil

final class SubagentLedgerTests: XCTestCase {
    private let session = UUID()

    func testStopWithNothingRunningIsTheEnd() {
        var ledger = SubagentLedger()
        XCTAssertFalse(ledger.mainStopped(in: session))
        XCTAssertFalse(ledger.isWaiting(for: session))
    }

    func testOnlyTheLastStopFinishesTheWait() {
        var ledger = SubagentLedger()
        ledger.started("a", in: session)
        ledger.started("b", in: session)
        XCTAssertTrue(ledger.mainStopped(in: session))
        XCTAssertFalse(ledger.stopped("a", in: session))
        XCTAssertTrue(ledger.stopped("b", in: session))
        XCTAssertFalse(ledger.isWaiting(for: session))
    }

    func testStopWithoutAnIdStillCountsDown() {
        var ledger = SubagentLedger()
        ledger.started(nil, in: session)
        XCTAssertTrue(ledger.mainStopped(in: session))
        XCTAssertTrue(ledger.stopped(nil, in: session))
    }

    func testAStopNobodyStartedDoesNothing() {
        var ledger = SubagentLedger()
        XCTAssertFalse(ledger.stopped("ghost", in: session))
        XCTAssertEqual(ledger.count(for: session), 0)
    }

    func testALostStopExpires() {
        var ledger = SubagentLedger()
        let start = Date()
        ledger.started("a", in: session, now: start)
        let later = start.addingTimeInterval(SubagentLedger.expiry + 1)
        XCTAssertEqual(ledger.count(for: session, now: later), 0)
        XCTAssertFalse(ledger.mainStopped(in: session, now: later))
    }

    func testANewPromptEndsTheWaitButKeepsTheCount() {
        var ledger = SubagentLedger()
        ledger.started("a", in: session)
        _ = ledger.mainStopped(in: session)
        ledger.mainResumed(in: session)
        XCTAssertFalse(ledger.isWaiting(for: session))
        XCTAssertEqual(ledger.count(for: session), 1)
    }
}
