import AppKit
import XCTest
@testable import Uncoil

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
