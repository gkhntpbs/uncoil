import XCTest
@testable import Uncoil

/// The session status state machine. Every handler used to set a status
/// directly, so a hook that arrived after a session was closed — or while it
/// was asleep — put the row back to "Running" with no process behind it.
@MainActor
final class SessionStatusTransitionTests: XCTestCase {
    private let stopped: [AgentSessionStatus] = [.terminated, .suspended, .hibernated]
    private let live: [AgentSessionStatus] = [
        .idle, .thinking, .running, .waitingForPermission, .waitingForInput,
        .waitingForSubagents, .completed,
    ]

    func testEndingIsAlwaysLegal() {
        for status in stopped + live + [.unknown] {
            XCTAssertTrue(status.allowsTransition(to: .terminated, from: .event), "\(status)")
        }
    }

    func testEventsMoveFreelyBetweenLiveStates() {
        for from in live + [.unknown] {
            for to in live {
                XCTAssertTrue(from.allowsTransition(to: to, from: .event), "\(from) → \(to)")
            }
        }
    }

    func testEventsCannotReviveAStoppedSession() {
        for from in stopped {
            for to in live {
                XCTAssertFalse(from.allowsTransition(to: to, from: .event), "\(from) → \(to)")
            }
        }
    }

    func testEventsCannotSleepASessionOrMakeItUnknown() {
        for to: AgentSessionStatus in [.suspended, .hibernated, .unknown] {
            XCTAssertFalse(AgentSessionStatus.running.allowsTransition(to: to, from: .event), "\(to)")
        }
    }

    func testLifecycleMayMoveAnywhere() {
        for from in stopped + live + [.unknown] {
            for to in stopped + live + [.unknown] {
                XCTAssertTrue(from.allowsTransition(to: to, from: .lifecycle), "\(from) → \(to)")
            }
        }
    }

    // MARK: - Through the store

    func testLateHookAfterCloseIsIgnored() {
        let store = SessionStore()
        let id = UUID()
        store.setStatus(.running, for: id)
        store.setStatus(.terminated, detail: "closed", for: id)

        XCTAssertFalse(store.setStatus(.running, detail: "tool: Bash", for: id))
        XCTAssertEqual(store.status(of: id), .terminated)
        XCTAssertEqual(store.detail(of: id), "closed")
    }

    func testHookDuringSleepIsIgnoredAndWakeRestoresIt() {
        let store = SessionStore()
        let id = UUID()
        store.setStatus(.hibernated, origin: .lifecycle, for: id)

        store.setStatus(.thinking, for: id)
        XCTAssertEqual(store.status(of: id), .hibernated)

        store.setStatus(.idle, origin: .lifecycle, for: id)
        store.setStatus(.thinking, for: id)
        XCTAssertEqual(store.status(of: id), .thinking)
    }

    func testRelaunchRevivesAClosedSession() {
        let store = SessionStore()
        let id = UUID()
        store.setStatus(.terminated, for: id)
        XCTAssertTrue(store.setStatus(.idle, origin: .lifecycle, for: id))
        XCTAssertEqual(store.status(of: id), .idle)
    }

    func testRestoredSessionAcceptsHooksBeforeTheHandshake() {
        let store = SessionStore()
        let id = UUID()
        XCTAssertEqual(store.status(of: id), .unknown)
        store.setStatus(.running, for: id)
        XCTAssertEqual(store.status(of: id), .running)
    }
}
