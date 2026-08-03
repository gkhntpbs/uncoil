import XCTest
@testable import Uncoil

/// One session, one window — and the ways that rule can go wrong.
final class SessionOwnershipTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()
    private let session = UUID()

    // MARK: - Claiming

    func testAFreeSessionGoesToWhoeverAsks() {
        var ownership = SessionOwnership()
        XCTAssertEqual(ownership.claim(session, by: windowA), .granted)
        XCTAssertEqual(ownership.holder(of: session), windowA)
    }

    func testAskingTwiceFromTheSameWindowChangesNothing() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        XCTAssertEqual(ownership.claim(session, by: windowA), .alreadyHeld)
        XCTAssertEqual(ownership.holder(of: session), windowA)
    }

    /// The rule that matters. Selecting a row in a second window must not pull
    /// a running terminal out of the window it is in — that is the bug the
    /// whole feature exists to make impossible.
    func testASecondWindowCannotTakeASessionByAsking() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        XCTAssertEqual(ownership.claim(session, by: windowB), .heldElsewhere(windowA))
        XCTAssertEqual(ownership.holder(of: session), windowA)
    }

    /// A view has to decide what to draw without changing anything while it
    /// draws it.
    func testAskingWhatWouldHappenDoesNotMakeItHappen() {
        var ownership = SessionOwnership()
        XCTAssertEqual(ownership.outcome(claiming: session, by: windowA), .granted)
        XCTAssertNil(ownership.holder(of: session))
        ownership.claim(session, by: windowA)
        XCTAssertEqual(ownership.outcome(claiming: session, by: windowB), .heldElsewhere(windowA))
    }

    // MARK: - Transferring

    func testMoveHereTakesTheSessionOutright() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        ownership.take(session, by: windowB)
        XCTAssertEqual(ownership.holder(of: session), windowB)
    }

    /// The window that just lost a session still runs its own teardown, and
    /// that teardown must not evict the window that took it.
    func testTheLoserOfATransferCannotReleaseTheWinnersSession() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        ownership.take(session, by: windowB)
        ownership.release(session, from: windowA)
        XCTAssertEqual(ownership.holder(of: session), windowB)
    }

    // MARK: - Letting go

    func testNavigatingAwayFreesTheSessionForOtherWindows() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        ownership.release(session, from: windowA)
        XCTAssertEqual(ownership.claim(session, by: windowB), .granted)
    }

    /// A closed window that kept its claims would leave every session it had
    /// visited unreachable from anywhere, with no window left to reveal.
    func testAClosedWindowFreesEverythingItHeld() {
        var ownership = SessionOwnership()
        let other = UUID()
        ownership.claim(session, by: windowA)
        ownership.claim(other, by: windowA)
        ownership.releaseAll(of: windowA)
        XCTAssertEqual(ownership.sessions(heldBy: windowA), [])
        XCTAssertEqual(ownership.claim(session, by: windowB), .granted)
    }

    func testASplitPaneAndASelectionAreBothHeldByTheSameWindow() {
        var ownership = SessionOwnership()
        let split = UUID()
        ownership.claim(session, by: windowA)
        ownership.claim(split, by: windowA)
        XCTAssertEqual(ownership.sessions(heldBy: windowA), [session, split])
    }

    // MARK: - Pruning

    func testADeletedSessionIsNobodys() {
        var ownership = SessionOwnership()
        ownership.claim(session, by: windowA)
        ownership.forget(session)
        XCTAssertNil(ownership.holder(of: session))
    }

    /// A claim held by a window that never came back would lock a session with
    /// nothing to reveal and no way out of the overlay.
    func testAClaimHeldByAWindowThatIsGoneIsDropped() {
        var ownership = SessionOwnership(holders: [session: windowA])
        ownership.prune(sessions: [session], windows: [windowB])
        XCTAssertNil(ownership.holder(of: session))
    }

    func testAClaimOnASessionThatIsGoneIsDropped() {
        var ownership = SessionOwnership(holders: [session: windowA])
        ownership.prune(sessions: [], windows: [windowA])
        XCTAssertNil(ownership.holder(of: session))
    }

    func testPruningKeepsWhatIsStillReal() {
        var ownership = SessionOwnership(holders: [session: windowA])
        ownership.prune(sessions: [session], windows: [windowA])
        XCTAssertEqual(ownership.holder(of: session), windowA)
    }
}
