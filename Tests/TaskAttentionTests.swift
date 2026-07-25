import XCTest
@testable import Uncoil

final class TaskAttentionEngineTests: XCTestCase {
    private let projectID = UUID()
    private let sessionID = UUID()
    private let now = Date(timeIntervalSince1970: 10_000)

    private func assignment(
        _ state: ProjectTaskExecutionState,
        role: TaskAgentRole = .implementer,
        session: UUID? = nil,
        needsRelinking: Bool = false
    ) -> TaskSessionAssignment {
        TaskSessionAssignment(
            taskID: "t1", sourcePath: "/repo/TODO.md", sessionID: session ?? sessionID,
            role: role, state: state, needsRelinking: needsRelinking
        )
    }

    private func task(
        _ assignments: [TaskSessionAssignment],
        review: TaskReviewResult.Verdict? = nil,
        mergeBlockers: [TaskCompletionGate.Blocker]? = nil,
        isDone: Bool = false
    ) -> TaskAttentionSnapshot {
        TaskAttentionSnapshot(tasks: [
            TaskAttentionInput(
                taskID: "t1", taskText: "daemon heartbeat ekle", projectID: projectID,
                projectName: "uncoil", sourcePath: "/repo/TODO.md",
                assignments: assignments, latestReview: review,
                mergeBlockers: mergeBlockers, isDone: isDone,
                updatedAt: Date(timeIntervalSince1970: 5_000)
            ),
        ])
    }

    private func kinds(_ snapshot: TaskAttentionSnapshot) -> [AttentionKind] {
        TaskAttentionEngine.items(snapshot, now: now).map(\.kind)
    }

    // MARK: - Every documented event

    func testAnAssignedTaskIsReported() {
        let items = TaskAttentionEngine.items(task([assignment(.assigned)]), now: now)
        XCTAssertEqual(items.map(\.kind), [.taskAssigned])
        XCTAssertTrue(items[0].title.contains("daemon heartbeat ekle"))
        XCTAssertTrue(items[0].title.contains("uncoil"))
        XCTAssertEqual(items[0].sessionID, sessionID, "the row leads back to the session")
        XCTAssertEqual(items[0].projectID, projectID)
    }

    func testWaitingStatesAreReportedAsPermissionAndInput() {
        XCTAssertEqual(kinds(task([assignment(.waitingForPermission)])), [.permission])
        XCTAssertEqual(kinds(task([assignment(.waitingForUser)])), [.input])
    }

    func testFailingTestsBlockedAndFailedAreReported() {
        XCTAssertEqual(kinds(task([assignment(.testsFailing)])), [.testFailure])
        XCTAssertEqual(kinds(task([assignment(.blocked)])), [.taskBlocked])
        XCTAssertEqual(kinds(task([assignment(.failed)])), [.taskFailed])
    }

    func testReviewRequestedAndChangesRequestedAreSeparateRows() {
        XCTAssertEqual(kinds(task([assignment(.reviewRequested)])), [.reviewRequested])
        XCTAssertEqual(
            kinds(task([assignment(.running)], review: .changesRequested)),
            [.taskAssigned, .changesRequested]
        )
        XCTAssertFalse(
            kinds(task([assignment(.running)], review: .approved)).contains(.changesRequested)
        )
    }

    func testACompletedTaskIsReportedOnce() {
        let items = TaskAttentionEngine.items(
            task([assignment(.completed)], isDone: true), now: now
        )
        XCTAssertEqual(items.map(\.kind), [.taskCompleted])
    }

    func testMergeReadinessIsOnlyReportedForWorkThatWasDone() {
        XCTAssertTrue(
            kinds(task([assignment(.running)], mergeBlockers: [])).contains(.mergeReady)
        )
        XCTAssertFalse(
            kinds(task([assignment(.running)], mergeBlockers: [.reviewMissing]))
                .contains(.mergeReady),
            "a blocked merge is not ready"
        )
        XCTAssertFalse(
            kinds(task([], mergeBlockers: [])).contains(.mergeReady),
            "an untouched task has no blockers either; that is not readiness"
        )
        XCTAssertFalse(
            kinds(task([assignment(.running)], mergeBlockers: nil)).contains(.mergeReady),
            "never asked is not the same as nothing standing in the way"
        )
    }

    func testALostLinkIsReportedOncePerTask() {
        let items = TaskAttentionEngine.items(
            task([
                assignment(.running, needsRelinking: true),
                assignment(.running, role: .tester, session: UUID(), needsRelinking: true),
            ]),
            now: now
        )
        XCTAssertEqual(items.filter { $0.kind == .relinkNeeded }.count, 1)
    }

    func testAConflictedSourceIsReportedPerFile() {
        let snapshot = TaskAttentionSnapshot(
            conflictedSources: [projectID: ["/repo/TODO.md", "/repo/docs/TODO.md"]],
            projectNames: [projectID: "uncoil"]
        )
        let items = TaskAttentionEngine.items(snapshot, now: now)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.kind == .mergeConflict })
        XCTAssertTrue(items.contains { $0.title.contains("uncoil") })
        XCTAssertEqual(
            Set(items.map(\.id)),
            [
                TaskAttentionEngine.sourceConflictID("/repo/TODO.md"),
                TaskAttentionEngine.sourceConflictID("/repo/docs/TODO.md"),
            ]
        )
    }

    // MARK: - Identity and quiet states

    func testEachRoleGetsItsOwnRowForTheSameTask() {
        let items = TaskAttentionEngine.items(
            task([
                assignment(.waitingForPermission),
                assignment(.waitingForPermission, role: .tester, session: UUID()),
            ]),
            now: now
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2, "two sessions, two rows")
    }

    func testQuietStatesProduceNothing() {
        for state: ProjectTaskExecutionState in [.unassigned, .queued] {
            XCTAssertTrue(kinds(task([assignment(state)])).isEmpty, state.rawValue)
        }
        XCTAssertTrue(TaskAttentionEngine.items(TaskAttentionSnapshot(), now: now).isEmpty)
    }

    func testIDsAreStableAcrossRefreshes() {
        let snapshot = task([assignment(.blocked)])
        XCTAssertEqual(
            TaskAttentionEngine.items(snapshot, now: now).map(\.id),
            TaskAttentionEngine.items(snapshot, now: now.addingTimeInterval(60)).map(\.id),
            "a stable id is what keeps a read row read"
        )
    }

    func testTaskRowsFlowThroughTheMainEngine() {
        var snapshot = AttentionSnapshot()
        snapshot.tasks = task([assignment(.blocked)])
        XCTAssertEqual(AttentionEngine.items(snapshot, now: now).map(\.kind), [.taskBlocked])
    }
}

final class MenuBarTaskCountsTests: XCTestCase {
    private func item(_ kind: AttentionKind) -> AttentionItem {
        AttentionItem(
            id: "\(kind.rawValue)-\(UUID().uuidString)", kind: kind, title: "t", detail: nil,
            projectID: nil, sessionID: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testCountsComeFromTheAttentionRows() {
        let summary = MenuBarMonitorEngine.summary(
            statuses: [:],
            attention: [
                item(.taskAssigned), item(.taskAssigned),
                item(.taskBlocked), item(.changesRequested),
                item(.reviewRequested),
                item(.taskCompleted),
                item(.mergeReady),
            ],
            queuedTasks: 4
        )
        XCTAssertEqual(summary.tasks.running, 2)
        XCTAssertEqual(summary.tasks.blocked, 2, "requested changes is a blocked task")
        XCTAssertEqual(summary.tasks.awaitingReview, 1)
        XCTAssertEqual(summary.tasks.completed, 1)
        XCTAssertEqual(summary.tasks.mergeReady, 1)
        XCTAssertEqual(summary.tasks.queued, 4)
    }

    func testTheTaskLineIsHiddenWhenThereAreNoTasks() {
        let empty = MenuBarMonitorEngine.summary(statuses: [:])
        XCTAssertNil(empty.taskHeadline)
        XCTAssertTrue(empty.tasks.isEmpty)

        let busy = MenuBarMonitorEngine.summary(
            statuses: [:], attention: [item(.taskBlocked)], queuedTasks: 1
        )
        let headline = try? XCTUnwrap(busy.taskHeadline)
        XCTAssertTrue(headline?.contains("1 bloklu") ?? false, headline ?? "-")
        XCTAssertTrue(headline?.contains("1 kuyrukta") ?? false, headline ?? "-")
    }

    func testTaskProblemsEscalateTheMenuBarIcon() {
        let summary = MenuBarMonitorEngine.summary(
            statuses: [:], attention: [item(.taskFailed)]
        )
        XCTAssertTrue(summary.hasProblem)
        XCTAssertEqual(summary.symbolName, "exclamationmark.triangle.fill")

        XCTAssertFalse(
            MenuBarMonitorEngine.summary(statuses: [:], attention: [item(.mergeReady)])
                .hasProblem,
            "work waiting for approval is not a problem"
        )
    }

    func testEveryKindDeclaresWhetherItIsAProblem() {
        // A new kind must be classified, not silently fall through.
        for kind in AttentionKind.allCases {
            XCTAssertEqual(kind.isProblem, kind.isProblem)
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertFalse(kind.iconName.isEmpty)
            XCTAssertGreaterThan(kind.priority, 0)
        }
    }
}
