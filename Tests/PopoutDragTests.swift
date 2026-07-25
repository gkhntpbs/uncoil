import AppKit
import XCTest
@testable import Uncoil

/// Dragging a session out of the window has to open it in its own window. It
/// used to drop a text clipping on the desktop instead: the sidebar offered
/// external drop targets a `.copy`, the Finder took it, and an accepted drag can
/// never satisfy the "refused everywhere" half of the pop-out rule.
final class SidebarDragMaskTests: XCTestCase {
    func testNothingOutsideTheAppMayAcceptASession() {
        XCTAssertEqual(
            SidebarDragMask.external, [],
            "An external drop operation is offered again — a session dragged to the "
                + "desktop will be written out as a file instead of popping out"
        )
    }

    func testInsideTheAppASessionMoves() {
        XCTAssertEqual(SidebarDragMask.local, .move)
    }

    /// The two halves together: refused everywhere *and* dropped outside the
    /// window is the only combination that pops a session out.
    func testRefusedOutsideTheWindowIsWhatPopsOut() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(
            PopoutDragDecision.shouldPopOut(
                operation: SidebarDragMask.external,
                endedAt: CGPoint(x: 1200, y: 400),
                windowFrame: window
            )
        )
        XCTAssertFalse(
            PopoutDragDecision.shouldPopOut(
                operation: .copy, endedAt: CGPoint(x: 1200, y: 400), windowFrame: window
            )
        )
    }
}

final class PopoutDragDecisionTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testADragRefusedOutsideTheWindowOpensAPopout() {
        XCTAssertTrue(
            PopoutDragDecision.shouldPopOut(
                operation: [], endedAt: CGPoint(x: 1_200, y: 400), windowFrame: window
            )
        )
    }

    func testADragThatEndedInsideTheWindowIsJustAMiss() {
        XCTAssertFalse(
            PopoutDragDecision.shouldPopOut(
                operation: [], endedAt: CGPoint(x: 400, y: 300), windowFrame: window
            ),
            "dropping on nothing inside the sidebar means nothing"
        )
    }

    func testADragSomethingElseAcceptedIsNotReinterpreted() {
        for operation: NSDragOperation in [.move, .copy, .generic] {
            XCTAssertFalse(
                PopoutDragDecision.shouldPopOut(
                    operation: operation, endedAt: CGPoint(x: 1_200, y: 400),
                    windowFrame: window
                ),
                "\(operation) was accepted by a target; it is not ours to reinterpret"
            )
        }
    }

    func testTheWindowEdgeHasSomeTolerance() {
        // A drop a couple of points past the frame is still "on the window": the
        // user let go at the edge, they did not aim at the desktop.
        XCTAssertFalse(
            PopoutDragDecision.shouldPopOut(
                operation: [], endedAt: CGPoint(x: 903, y: 400), windowFrame: window
            )
        )
        XCTAssertTrue(
            PopoutDragDecision.shouldPopOut(
                operation: [], endedAt: CGPoint(x: 950, y: 400), windowFrame: window
            )
        )
    }
}
