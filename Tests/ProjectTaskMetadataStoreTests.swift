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
            sessionID: sessionA, role: .implement, now: now
        )

        let reloaded = self.store()
        XCTAssertEqual(reloaded.assignments(for: task.id).count, 1)
        XCTAssertEqual(reloaded.assignments(forSession: sessionA).count, 1)
        XCTAssertEqual(reloaded.assignments(for: task.id).first?.role, .implement)
        XCTAssertEqual(reloaded.executionState(for: task.id), .assigned)
    }

    func testReassigningTheSameWorkUpdatesRatherThanDuplicates() {
        let store = store()
        let task = tasks[0]
        let first = store.assign(
            taskID: task.id, sourcePath: task.sourcePath,
            sessionID: sessionA, role: .implement, now: now
        )
        store.setState(.failed, assignmentID: first.id, now: now)
        let second = store.assign(
            taskID: task.id, sourcePath: task.sourcePath,
            sessionID: sessionA, role: .implement, now: now
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.assignments(for: task.id).count, 1)
        XCTAssertEqual(store.assignments(for: task.id).first?.state, .assigned)
    }

    func testDifferentRolesCoexistOnOneTask() {
        let store = store()
        let task = tasks[0]
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implement)
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .review)
        XCTAssertEqual(store.assignments(for: task.id).count, 2)
        XCTAssertEqual(Set(store.assignments(for: task.id).map(\.role)), [.implement, .review])
    }

    func testCardStateShowsTheMostUrgentAssignment() {
        let store = store()
        let task = tasks[0]
        let implement = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implement
        )
        let review = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .review
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
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implement
        )
        store.assign(taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionB, role: .review)
        store.removeAssignment(id: first.id)
        XCTAssertEqual(store.assignments(for: task.id).map(\.role), [.review])
    }

    func testAssignmentsGroupedByTask() {
        let store = store()
        store.assign(taskID: tasks[0].id, sourcePath: "/p/TODO.md", sessionID: sessionA, role: .implement)
        store.assign(taskID: tasks[1].id, sourcePath: "/p/TODO.md", sessionID: sessionB, role: .implement)
        XCTAssertEqual(store.assignmentsByTask.count, 2)
    }

    // MARK: - Relinking

    func testTrackedFingerprintsCoverEveryAssignment() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implement
        )
        let tracked = store.trackedFingerprints(in: tasks)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked[assignment.id.uuidString]?.filePath, "/p/TODO.md")
    }

    func testMarkingNeedsRelinkingIsVisibleAndPersisted() {
        let store = store()
        let task = tasks[0]
        let assignment = store.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: sessionA, role: .implement
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
        store.assign(taskID: tasks[0].id, sourcePath: "/p/TODO.md", sessionID: sessionA, role: .implement)
        let written = try FileManager.default
            .subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.allSatisfy { $0.contains("tasks/") })
    }
}
