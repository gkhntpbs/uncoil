import XCTest
@testable import Uncoil

@MainActor
final class ProjectTaskMetadataStoreTests: XCTestCase {
    private var directory: URL!
    private let projectID = UUID()
    private let sessionA = UUID()
    private let sessionB = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTaskMeta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func store() -> ProjectTaskMetadataStore {
        ProjectTaskMetadataStore(projectID: projectID, dataDirectory: directory)
    }

    private var tasks: [ProjectTask] {
        TodoParser.parse("## A\n- [ ] bir\n- [ ] iki\n", path: "/p/TODO.md").tasks
    }

    // MARK: - Assignments

    func testAssignmentSurvivesAReload() {
        let store = store()
        let task = tasks[0]
        store.assign(
            taskID: task.id, sourcePath: task.sourcePath,
            sessionID: sessionA, role: .implementer, now: now
        )

        let reloaded = self.store()
        XCTAssertEqual(reloaded.assignments(for: task.id).count, 1)
        XCTAssertEqual(reloaded.assignments(forSession: sessionA).count, 1)
        XCTAssertEqual(reloaded.assignments(for: task.id).first?.role, .implementer)
        XCTAssertEqual(reloaded.executionState(for: task.id), .assigned)
    }

    func testReassigningTheSameWorkUpdatesRatherThanDuplicates() {
        let store = store()
        let task = tasks[0]
        let first = store.assign(
            taskID: task.id, sourcePath: task.sourcePath,
            sessionID: sessionA, role: .implementer, now: now
        )
        store.setState(.failed, assignmentID: first.id, now: now)
        let second = store.assign(
            taskID: task.id, sourcePath: task.sourcePath,
            sessionID: sessionA, role: .implementer, now: now
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.assignments(for: task.id).count, 1)
        XCTAssertEqual(store.assignments(for: task.id).first?.state, .assigned)
    }

    func testDifferentRolesCoexistOnOneTask() {
        let store = store()
        let task = tasks[0]
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer)
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .reviewer)
        XCTAssertEqual(store.assignments(for: task.id).count, 2)
        XCTAssertEqual(Set(store.assignments(for: task.id).map(\.role)), [.implementer, .reviewer])
    }

    func testCardStateShowsTheMostUrgentAssignment() {
        let store = store()
        let task = tasks[0]
        let implement = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer
        )
        let review = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .reviewer
        )
        store.setState(.running, assignmentID: implement.id)
        store.setState(.waitingForPermission, assignmentID: review.id)
        XCTAssertEqual(
            store.executionState(for: task.id), .waitingForPermission,
            "something wanting the user outranks work in flight"
        )

        store.setState(.running, assignmentID: review.id)
        XCTAssertEqual(store.executionState(for: task.id), .running)
    }

    func testUnassignedIsTheDefaultState() {
        XCTAssertEqual(store().executionState(for: "yok"), .unassigned)
    }

    func testRemovingAnAssignmentLeavesTheOthers() {
        let store = store()
        let task = tasks[0]
        let first = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer
        )
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .reviewer)
        store.removeAssignment(id: first.id)
        XCTAssertEqual(store.assignments(for: task.id).map(\.role), [.reviewer])
    }

    func testAssignmentsGroupedByTask() {
        let store = store()
        store.assign(taskID: tasks[0].id, sourcePath: "/p/TODO.md", sessionID: sessionA, role: .implementer)
        store.assign(taskID: tasks[1].id, sourcePath: "/p/TODO.md", sessionID: sessionB, role: .implementer)
        XCTAssertEqual(store.assignmentsByTask.count, 2)
    }

    // MARK: - Relinking

    func testTrackedFingerprintsCoverEveryAssignment() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer
        )
        let tracked = store.trackedFingerprints(in: tasks)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked[assignment.id.uuidString]?.filePath, "/p/TODO.md")
    }

    func testMarkingNeedsRelinkingIsVisibleAndPersisted() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer
        )
        store.markNeedsRelinking(assignmentIDs: [assignment.id.uuidString])
        XCTAssertTrue(store.assignments(for: task.id).first?.needsRelinking ?? false)
        XCTAssertEqual(store.document.needsRelinking, [task.id])

        let reloaded = self.store()
        XCTAssertTrue(reloaded.assignments(for: task.id).first?.needsRelinking ?? false)

        store.markNeedsRelinking(assignmentIDs: [])
        XCTAssertFalse(store.assignments(for: task.id).first?.needsRelinking ?? true)
        XCTAssertTrue(store.document.needsRelinking.isEmpty)
    }

    // MARK: - Leases

    func testOneSessionAtATimeHoldsATask() {
        let store = store()
        let task = tasks[0]
        XCTAssertNotNil(store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, now: now
        ))
        XCTAssertNil(
            store.claim(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, now: now),
            "a live claim blocks a second session"
        )
    }

    func testRenewalBumpsTheGeneration() {
        let store = store()
        let task = tasks[0]
        let first = store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, now: now
        )
        let renewed = store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(renewed?.id, first?.id)
        XCTAssertEqual(renewed?.generation, (first?.generation ?? 0) + 1)
        XCTAssertEqual(store.document.leases.count, 1)
    }

    func testAnExpiredClaimFreesTheTask() {
        let store = store()
        let task = tasks[0]
        store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            duration: 60, now: now
        )
        let later = now.addingTimeInterval(120)
        XCTAssertNil(store.lease(for: task.id, now: later))
        XCTAssertNotNil(store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, now: later
        ))
    }

    func testReleasingFreesTheTaskImmediately() {
        let store = store()
        let task = tasks[0]
        store.claim(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, now: now)
        store.release(taskID: task.id, sessionID: sessionA)
        XCTAssertNil(store.lease(for: task.id, now: now))
        XCTAssertNotNil(store.claim(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, now: now
        ))
    }

    // MARK: - Preferences

    func testPreferencesPersistSeparatelyFromMetadata() {
        let store = store()
        store.preferences.mode = .kanban
        store.preferences.columnOrder = ["Todo"]
        store.savePreferences()

        let reloaded = self.store()
        XCTAssertEqual(reloaded.preferences.mode, .kanban)
        XCTAssertEqual(reloaded.preferences.columnOrder, ["Todo"])
        XCTAssertTrue(
            reloaded.document.assignments.isEmpty,
            "view preferences are not task state"
        )
    }

    func testNothingIsWrittenIntoTheTodoFile() throws {
        // The store's own paths must live under Application Support, never
        // beside the user's TODO.md.
        let store = store()
        store.assign(taskID: tasks[0].id, sourcePath: "/p/TODO.md", sessionID: sessionA, role: .implementer)
        let written = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.allSatisfy { $0.contains("tasks/") })
    }
}

@MainActor
final class TaskRoleAndHistoryTests: XCTestCase {
    private var directory: URL!
    private let projectID = UUID()
    private let sessionA = UUID()
    private let sessionB = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTaskRoles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func store() -> ProjectTaskMetadataStore {
        ProjectTaskMetadataStore(projectID: projectID, dataDirectory: directory)
    }

    private var tasks: [ProjectTask] {
        TodoParser.parse("## A\n- [ ] bir\n- [ ] iki\n", path: "/p/TODO.md").tasks
    }

    // MARK: - Roles

    func testEveryDocumentedRoleExists() {
        XCTAssertEqual(
            Set(TaskAgentRole.allCases),
            [.owner, .implementer, .reviewer, .tester, .observer, .orchestrator]
        )
        XCTAssertTrue(TaskAgentRole.allCases.allSatisfy { !$0.label.isEmpty })
    }

    func testOnlyWorkingRolesTouchTheTree() {
        XCTAssertTrue(TaskAgentRole.implementer.writes)
        XCTAssertTrue(TaskAgentRole.tester.writes)
        XCTAssertFalse(TaskAgentRole.reviewer.writes)
        XCTAssertFalse(TaskAgentRole.observer.writes)
        XCTAssertFalse(TaskAgentRole.owner.writes)
        XCTAssertFalse(TaskAgentRole.orchestrator.writes)
    }

    func testRoleNamesFromAnEarlierBuildStillDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(TaskAgentRole.self, from: Data("\"implement\"".utf8)),
            .implementer
        )
        XCTAssertEqual(
            try decoder.decode(TaskAgentRole.self, from: Data("\"review\"".utf8)), .reviewer
        )
        XCTAssertEqual(
            try decoder.decode(TaskAgentRole.self, from: Data("\"test\"".utf8)), .tester
        )
        XCTAssertEqual(
            try decoder.decode(TaskAgentRole.self, from: Data("\"investigate\"".utf8)), .observer
        )
        XCTAssertThrowsError(
            try decoder.decode(TaskAgentRole.self, from: Data("\"nonsense\"".utf8))
        )
    }

    // MARK: - Many-to-many

    func testOneTaskManySessionsAndOneSessionManyTasks() {
        let store = store()
        let list = tasks
        store.assign(taskID: list[0].id, sourcePath: list[0].sourcePath, sessionID: sessionA, role: .implementer)
        store.assign(taskID: list[0].id, sourcePath: list[0].sourcePath, sessionID: sessionB, role: .reviewer)
        store.assign(taskID: list[1].id, sourcePath: list[1].sourcePath, sessionID: sessionA, role: .implementer)

        XCTAssertEqual(store.assignments(for: list[0].id).count, 2)
        XCTAssertEqual(store.assignments(forSession: sessionA).count, 2)
    }

    func testUnlinkingASessionLeavesTheTaskUntouched() throws {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, fingerprint: task.fingerprint
        )
        store.removeAssignment(id: assignment.id)
        XCTAssertTrue(store.assignments(for: task.id).isEmpty)
        XCTAssertEqual(store.executionState(for: task.id), .unassigned)
        // The task itself is a value read from the file; nothing about it moved.
        XCTAssertEqual(tasks[0].text, task.text)
        XCTAssertEqual(tasks[0].checkbox.mark, .open)
    }

    // MARK: - Execution history

    func testHistoryStartsAtAssignmentAndRecordsEveryTransition() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, now: now
        )
        store.setState(.running, assignmentID: assignment.id, now: now.addingTimeInterval(10))
        store.setState(
            .blocked, assignmentID: assignment.id, detail: "API anahtarı yok",
            now: now.addingTimeInterval(20)
        )

        let history = store.history(for: task.id)
        XCTAssertEqual(history.map(\.state), [.blocked, .running, .assigned], "newest first")
        XCTAssertEqual(history.first?.detail, "API anahtarı yok")
    }

    func testRepeatingTheSameStateIsNotRecordedTwice() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, now: now
        )
        store.setState(.running, assignmentID: assignment.id, now: now)
        store.setState(.running, assignmentID: assignment.id, now: now)
        XCTAssertEqual(store.history(for: task.id).filter { $0.state == .running }.count, 1)
    }

    func testHistorySurvivesAReload() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, now: now
        )
        store.setState(.completed, assignmentID: assignment.id, now: now)
        XCTAssertEqual(self.store().history(for: task.id).map(\.state), [.completed, .assigned])
    }

    func testTaskLevelStateChangeCoversEveryAssignment() {
        let store = store()
        let task = tasks[0]
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implementer)
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .reviewer)
        store.setState(.blocked, taskID: task.id, detail: "engel")
        XCTAssertTrue(store.assignments(for: task.id).allSatisfy { $0.state == .blocked })
    }

    // MARK: - Fingerprint binding

    func testAssignmentRemembersItsFingerprintSoAVanishedTaskIsStillTracked() {
        let store = store()
        let task = tasks[0]
        store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, fingerprint: task.fingerprint
        )
        // The task is gone from the current document entirely.
        let tracked = store.trackedFingerprints(in: [])
        XCTAssertEqual(tracked.count, 1, "a vanished task must still be re-resolvable")
        XCTAssertEqual(tracked.values.first?.normalizedText, task.fingerprint.normalizedText)
    }

    func testRebindingResolvesARelinkWithoutTouchingTheTask() {
        let store = store()
        let list = tasks
        let assignment = store.assign(
            taskID: list[0].id, sourcePath: list[0].sourcePath, sessionID: sessionA,
            role: .implementer, fingerprint: list[0].fingerprint
        )
        store.markNeedsRelinking(assignmentIDs: [assignment.id.uuidString])
        XCTAssertTrue(store.assignments(for: list[0].id).first?.needsRelinking ?? false)

        store.rebind(assignmentID: assignment.id, to: list[1])
        XCTAssertTrue(store.assignments(for: list[0].id).isEmpty)
        XCTAssertEqual(store.assignments(for: list[1].id).count, 1)
        XCTAssertFalse(store.assignments(for: list[1].id).first?.needsRelinking ?? true)
        XCTAssertTrue(store.document.needsRelinking.isEmpty)
    }

    func testWorktreeRelationIsStoredInMetadata() {
        let store = store()
        let task = tasks[0]
        store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA,
            role: .implementer, worktreePath: "/repo/.uncoil-worktrees/feature"
        )
        XCTAssertEqual(
            self.store().assignments(for: task.id).first?.worktreePath,
            "/repo/.uncoil-worktrees/feature"
        )
    }
}
