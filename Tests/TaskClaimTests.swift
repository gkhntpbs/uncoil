import XCTest
@testable import Uncoil

final class TaskClaimPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let sessionA = UUID()
    private let sessionB = UUID()

    private func lease(
        session: UUID? = nil,
        acquiredAt: Date? = nil,
        duration: TimeInterval = 900
    ) -> TaskClaimLease {
        TaskClaimLease(
            taskID: "t", sourcePath: "/p/TODO.md",
            sessionID: session ?? sessionA,
            acquiredAt: acquiredAt ?? now, duration: duration
        )
    }

    // MARK: - Which roles claim

    func testOnlyRolesThatDoTheWorkTakeALease() {
        XCTAssertTrue(TaskClaimPolicy.claims(.implementer))
        XCTAssertTrue(TaskClaimPolicy.claims(.tester))
        XCTAssertFalse(
            TaskClaimPolicy.claims(.observer),
            "an observer watches; it must not lock a task"
        )
        XCTAssertFalse(TaskClaimPolicy.claims(.reviewer))
        XCTAssertFalse(
            TaskClaimPolicy.claims(.orchestrator),
            "an orchestrator manages the task without owning the implementation"
        )
        XCTAssertFalse(TaskClaimPolicy.claims(.owner))
    }

    func testOnlyOneImplementerAtATime() {
        XCTAssertFalse(
            TaskClaimPolicy.mayClaim(
                role: .implementer, whileHeldBy: .implementer, sameSession: false
            )
        )
        XCTAssertTrue(
            TaskClaimPolicy.mayClaim(
                role: .implementer, whileHeldBy: .implementer, sameSession: true
            ),
            "the holder renews its own claim"
        )
        XCTAssertTrue(
            TaskClaimPolicy.mayClaim(role: .implementer, whileHeldBy: nil, sameSession: false)
        )
    }

    func testReviewAndTestAttachAlongsideAnImplementer() {
        XCTAssertTrue(
            TaskClaimPolicy.mayClaim(role: .tester, whileHeldBy: .implementer, sameSession: false),
            "a tester has its own job and must not be locked out"
        )
        // A reviewer does not claim at all, so it can always be attached.
        XCTAssertFalse(TaskClaimPolicy.claims(.reviewer))
    }

    func testANonClaimingRoleIsRefusedWithAUsefulReason() {
        XCTAssertFalse(
            TaskClaimPolicy.mayClaim(role: .observer, whileHeldBy: nil, sameSession: false)
        )
        XCTAssertTrue(
            TaskClaimPolicy.refusal(role: .observer, heldBy: .implementer)
                .contains("claim almaz")
        )
        XCTAssertTrue(
            TaskClaimPolicy.refusal(role: .implementer, heldBy: .implementer)
                .contains("tutuluyor")
        )
    }

    // MARK: - Claim state

    func testAvailableWhenNothingHasHappened() {
        XCTAssertEqual(
            TaskClaimPolicy.state(lease: nil, executionStates: [], checkboxDone: false, now: now),
            .available
        )
    }

    func testReleasedWhenWorkStartedButNoLeaseIsHeld() {
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: nil, executionStates: [.assigned], checkboxDone: false, now: now
            ),
            .released
        )
    }

    func testClaimedThenRunning() {
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: lease(), executionStates: [.assigned], checkboxDone: false, now: now
            ),
            .claimed
        )
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: lease(), executionStates: [.running], checkboxDone: false, now: now
            ),
            .running
        )
    }

    func testExpiredWhenTheLeaseRanOut() {
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: lease(duration: 60), executionStates: [.running],
                checkboxDone: false, now: now.addingTimeInterval(120)
            ),
            .expired
        )
    }

    func testBlockedAndCompletedOutrankTheLease() {
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: lease(), executionStates: [.running, .blocked],
                checkboxDone: false, now: now
            ),
            .blocked
        )
        XCTAssertEqual(
            TaskClaimPolicy.state(
                lease: lease(), executionStates: [.running], checkboxDone: true, now: now
            ),
            .completed
        )
    }

    func testOnlyAvailableReleasedAndExpiredAreTakeable() {
        let takeable = TaskClaimState.allCases.filter(\.isTakeable)
        XCTAssertEqual(Set(takeable), [.available, .released, .expired])
        XCTAssertTrue(TaskClaimState.allCases.allSatisfy { !$0.label.isEmpty })
    }

    // MARK: - Heartbeat

    func testALeaseGoesStaleWhenHeartbeatsStop() {
        let keeper = TaskLeaseKeeper()
        let live = lease(duration: 900)
        XCTAssertFalse(keeper.isStale(live, lastHeartbeat: now, now: now.addingTimeInterval(60)))
        XCTAssertTrue(
            keeper.isStale(live, lastHeartbeat: now, now: now.addingTimeInterval(300)),
            "three missed heartbeats is enough to let the task go"
        )
    }

    func testAnExpiredLeaseIsStaleEvenWithAFreshHeartbeat() {
        let keeper = TaskLeaseKeeper()
        let expired = lease(duration: 60)
        XCTAssertTrue(
            keeper.isStale(
                expired, lastHeartbeat: now.addingTimeInterval(119),
                now: now.addingTimeInterval(120)
            )
        )
    }

    func testRenewalExtendsAndBumpsTheGeneration() {
        let keeper = TaskLeaseKeeper()
        let original = lease(duration: 60)
        let renewed = keeper.renewed(original, now: now.addingTimeInterval(30))
        XCTAssertEqual(renewed.id, original.id)
        XCTAssertEqual(renewed.generation, original.generation + 1)
        XCTAssertGreaterThan(renewed.expiresAt, original.expiresAt)
    }
}
