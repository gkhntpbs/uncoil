import XCTest
@testable import Uncoil

@MainActor
final class AttentionEngineTests: XCTestCase {
    private let projectID = UUID()

    private func session(
        _ title: String,
        provider: AgentProvider = .claude,
        worktree: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            projectID: projectID,
            provider: provider,
            accountID: nil,
            title: title,
            worktreePath: worktree
        )
    }

    private func snapshot(
        sessions: [SessionRecord],
        statuses: [UUID: AgentSessionStatus] = [:],
        details: [UUID: String] = [:],
        codexAuthentication: [UUID: CodexAuthenticationState] = [:],
        runtimePhase: RuntimeClient.Phase = .ready,
        conflicts: [UUID: [String]] = [:]
    ) -> AttentionSnapshot {
        var snapshot = AttentionSnapshot()
        snapshot.sessions = sessions
        snapshot.statuses = statuses
        snapshot.details = details
        snapshot.codexAuthentication = codexAuthentication
        snapshot.runtimePhase = runtimePhase
        snapshot.conflicts = conflicts
        snapshot.projectNames = [projectID: "uncoil"]
        return snapshot
    }

    func testSurfacesPermissionInputAndCompletedSessions() {
        let permission = session("claude: izin")
        let input = session("claude: soru")
        let completed = session("codex: bitti", provider: .codex)
        let running = session("claude: çalışıyor")

        let items = AttentionEngine.items(snapshot(
            sessions: [permission, input, completed, running],
            statuses: [
                permission.id: .waitingForPermission,
                input.id: .waitingForInput,
                completed.id: .completed,
                running.id: .running,
            ],
            details: [permission.id: "Bash(rm -rf build)"]
        ))

        XCTAssertEqual(Set(items.map(\.kind)), [.permission, .input, .completed])
        XCTAssertNil(items.first { $0.sessionID == running.id })
        let permissionItem = items.first { $0.kind == .permission }
        XCTAssertEqual(permissionItem?.detail, "Bash(rm -rf build)")
        XCTAssertEqual(permissionItem?.title, "uncoil › izin")
        XCTAssertEqual(permissionItem?.id, AttentionEngine.permissionID(permission.id))
    }

    func testIdleAndTerminatedSessionsRaiseNothing() {
        let idle = session("claude: hazır")
        let terminated = session("claude: kapandı")
        let items = AttentionEngine.items(snapshot(
            sessions: [idle, terminated],
            statuses: [idle.id: .idle, terminated.id: .terminated]
        ))
        XCTAssertTrue(items.isEmpty)
    }

    func testAuthenticationRequirementAndErrorSurface() {
        let required = session("codex: giriş", provider: .codex)
        let broken = session("codex: hata", provider: .codex)
        let fine = session("codex: tamam", provider: .codex)

        let items = AttentionEngine.items(snapshot(
            sessions: [required, broken, fine],
            statuses: [
                required.id: .waitingForInput,
                broken.id: .idle,
                fine.id: .idle,
            ],
            codexAuthentication: [
                required.id: .required,
                broken.id: .error("account/read başarısız"),
                fine.id: .authenticated("a@b.c"),
            ]
        ))

        let auth = items.filter { $0.kind == .authentication }
        XCTAssertEqual(auth.count, 2)
        XCTAssertNil(auth.first { $0.sessionID == fine.id })
        XCTAssertEqual(
            auth.first { $0.sessionID == broken.id }?.detail,
            "account/read başarısız"
        )
    }

    func testMergeConflictAndRuntimeProblemsSurface() {
        let items = AttentionEngine.items(snapshot(
            sessions: [],
            runtimePhase: .failed,
            conflicts: [projectID: ["App/Core/Models.swift", "TODO.md"]]
        ))
        XCTAssertEqual(
            items.first { $0.kind == .mergeConflict }?.id,
            AttentionEngine.conflictID(projectID)
        )
        XCTAssertEqual(items.first { $0.kind == .runtime }?.id, AttentionEngine.runtimeID)

        let healthy = AttentionEngine.items(snapshot(
            sessions: [], runtimePhase: .ready, conflicts: [projectID: []]
        ))
        XCTAssertTrue(healthy.isEmpty)

        let mismatch = AttentionEngine.items(snapshot(sessions: [], runtimePhase: .incompatible("1.1 vs 2.0")))
        XCTAssertEqual(mismatch.first?.detail, "1.1 vs 2.0")
    }

    func testConflictDetailSummarizesLongLists() {
        XCTAssertTrue(
            AttentionEngine.conflictDetail(["a", "b", "c", "d"]).contains("4 files")
        )
        XCTAssertFalse(
            AttentionEngine.conflictDetail(["a"]).contains("files")
        )
    }

    func testSortingPutsPermissionFirstThenRecency() {
        let old = AttentionItem(
            id: "completed:1", kind: .completed, title: "eski", detail: nil,
            projectID: nil, sessionID: nil, createdAt: Date(timeIntervalSince1970: 10)
        )
        let new = AttentionItem(
            id: "completed:2", kind: .completed, title: "yeni", detail: nil,
            projectID: nil, sessionID: nil, createdAt: Date(timeIntervalSince1970: 20)
        )
        let permission = AttentionItem(
            id: "permission:1", kind: .permission, title: "izin", detail: nil,
            projectID: nil, sessionID: nil, createdAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(
            AttentionEngine.sorted([old, new, permission]).map(\.id),
            ["permission:1", "completed:2", "completed:1"]
        )
    }
}

@MainActor
final class AttentionStoreTests: XCTestCase {
    private let projectID = UUID()

    private func store() -> AttentionStore {
        let store = AttentionStore.shared
        store.resolveAll()
        store.refresh(AttentionSnapshot())
        return store
    }

    private func snapshot(_ session: SessionRecord, _ status: AgentSessionStatus) -> AttentionSnapshot {
        var snapshot = AttentionSnapshot()
        snapshot.sessions = [session]
        snapshot.statuses = [session.id: status]
        snapshot.projectNames = [projectID: "uncoil"]
        snapshot.runtimePhase = .ready
        return snapshot
    }

    private func session() -> SessionRecord {
        SessionRecord(projectID: projectID, provider: .claude, accountID: nil, title: "claude: iş")
    }

    func testReadStateSurvivesRefreshAndCountsUnread() {
        let store = store()
        let record = session()
        store.refresh(snapshot(record, .waitingForPermission))
        XCTAssertEqual(store.unreadCount, 1)

        store.markRead(AttentionEngine.permissionID(record.id))
        XCTAssertEqual(store.unreadCount, 0)

        store.refresh(snapshot(record, .waitingForPermission))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 0, "a still-pending row stays read")
    }

    func testResolvedRowReturnsOnlyAfterTheConditionCleared() {
        let store = store()
        let record = session()
        store.refresh(snapshot(record, .waitingForPermission))
        store.resolve(AttentionEngine.permissionID(record.id))
        XCTAssertTrue(store.items.isEmpty)

        store.refresh(snapshot(record, .waitingForPermission))
        XCTAssertTrue(store.items.isEmpty, "still the same pending permission")

        store.refresh(snapshot(record, .running))
        store.refresh(snapshot(record, .waitingForPermission))
        XCTAssertEqual(store.items.count, 1, "a new permission request shows again")
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testReportedFailureSticksAcrossRefreshUntilResolved() {
        let store = store()
        let record = session()
        store.report(
            kind: .testFailure, title: "uncoil › iş", detail: "3 tests failing",
            projectID: projectID, sessionID: record.id, id: "test:x"
        )
        XCTAssertEqual(store.count(of: .testFailure), 1)

        store.refresh(snapshot(record, .idle))
        XCTAssertEqual(store.count(of: .testFailure), 1, "reported rows are not derived")

        store.resolve("test:x")
        store.refresh(snapshot(record, .idle))
        XCTAssertEqual(store.count(of: .testFailure), 0)
    }

    func testMarkAllReadCoversEveryRow() {
        let store = store()
        let record = session()
        store.refresh(snapshot(record, .waitingForPermission))
        store.report(
            kind: .testFailure, title: "t", detail: nil,
            projectID: projectID, sessionID: record.id, id: "test:y"
        )
        XCTAssertEqual(store.unreadCount, 2)
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        store.resolveAll()
        XCTAssertTrue(store.items.isEmpty)
    }
}

final class ArtifactStatusTests: XCTestCase {
    func testFailedStatusVocabulary() {
        for value in ["failed", "FAIL", " failing ", "error", "red"] {
            XCTAssertTrue(CapabilityRouter.isFailedStatus(value), value)
        }
        for value in [nil, "", "passed", "ok", "green", "skipped"] {
            XCTAssertFalse(CapabilityRouter.isFailedStatus(value), value ?? "nil")
        }
    }
}

/// Read/cleared marks have to outlive the process: a notification the user
/// dismissed came back every time Uncoil was relaunched, because the marks were
/// held only in memory and the rows were re-derived from session state at launch.
@MainActor
final class AttentionPersistenceTests: XCTestCase {
    private let projectID = UUID()
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "uncoil-attention-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func snapshot(_ session: SessionRecord, _ status: AgentSessionStatus) -> AttentionSnapshot {
        var snapshot = AttentionSnapshot()
        snapshot.sessions = [session]
        snapshot.statuses = [session.id: status]
        snapshot.projectNames = [projectID: "uncoil"]
        snapshot.runtimePhase = .ready
        return snapshot
    }

    func testClearedRowStaysClearedAfterRelaunch() {
        let record = SessionRecord(
            projectID: projectID, provider: .claude, accountID: nil, title: "iş"
        )

        let before = AttentionStore(defaults: defaults)
        before.refresh(snapshot(record, .waitingForPermission))
        before.resolve(AttentionEngine.permissionID(record.id))
        XCTAssertTrue(before.items.isEmpty)

        // A relaunch: a fresh store, and the first refresh happens before any
        // session state exists — which is what used to wipe the marks.
        let after = AttentionStore(defaults: defaults)
        after.refresh(AttentionSnapshot())
        after.refresh(snapshot(record, .waitingForPermission))
        XCTAssertTrue(after.items.isEmpty, "a cleared row must not return on relaunch")
    }

    func testReadRowStaysReadAfterRelaunch() {
        let record = SessionRecord(
            projectID: projectID, provider: .claude, accountID: nil, title: "iş"
        )

        let before = AttentionStore(defaults: defaults)
        before.refresh(snapshot(record, .waitingForPermission))
        before.markAllRead()
        XCTAssertEqual(before.unreadCount, 0)

        let after = AttentionStore(defaults: defaults)
        after.refresh(snapshot(record, .waitingForPermission))
        XCTAssertEqual(after.items.count, 1)
        XCTAssertEqual(after.unreadCount, 0, "a read row must not go unread on relaunch")
    }

    func testANewOccurrenceOfAClearedRowComesBack() {
        var record = SessionRecord(
            projectID: projectID, provider: .claude, accountID: nil, title: "iş"
        )

        let store = AttentionStore(defaults: defaults)
        store.refresh(snapshot(record, .waitingForPermission))
        store.resolve(AttentionEngine.permissionID(record.id))
        XCTAssertTrue(store.items.isEmpty)

        // The agent worked on, then asked again: a later activity stamp is a
        // different occurrence of the same row.
        record.lastActivityAt = record.lastActivityAt.addingTimeInterval(60)
        let relaunched = AttentionStore(defaults: defaults)
        relaunched.refresh(snapshot(record, .waitingForPermission))
        XCTAssertEqual(relaunched.items.count, 1)
        XCTAssertEqual(relaunched.unreadCount, 1)
    }
}

/// Task-derived rows across a relaunch.
///
/// The session rows above were covered; the task rows the user actually sees
/// most of — an assignment running, a link that needs confirming — were not,
/// and they take a different path to their occurrence signature.
@MainActor
final class TaskAttentionPersistenceTests: XCTestCase {
    private let projectID = UUID()
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "uncoil-attention-task-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func snapshot(updatedAt: Date) -> AttentionSnapshot {
        let assignment = TaskSessionAssignment(
            taskID: "t1",
            sourcePath: "/tmp/TODO.md",
            sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            role: .implementer,
            state: .agentStarting,
            assignedAt: updatedAt,
            updatedAt: updatedAt
        )
        var snapshot = AttentionSnapshot()
        snapshot.tasks.tasks = [
            TaskAttentionInput(
                taskID: "t1",
                taskText: "ship it",
                projectID: projectID,
                projectName: "uncoil",
                sourcePath: "/tmp/TODO.md",
                assignments: [assignment],
                updatedAt: updatedAt
            ),
        ]
        return snapshot
    }

    func testClearedTaskRowStaysClearedAfterRelaunch() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let before = AttentionStore(defaults: defaults)
        before.refresh(snapshot(updatedAt: stamp))
        XCTAssertEqual(before.items.count, 1)
        before.resolveAll()
        XCTAssertTrue(before.items.isEmpty)

        let after = AttentionStore(defaults: defaults)
        after.refresh(AttentionSnapshot())
        after.refresh(snapshot(updatedAt: stamp))
        XCTAssertTrue(after.items.isEmpty, "a cleared task row must not return on relaunch")
    }

    func testReadTaskRowStaysReadAfterRelaunch() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let before = AttentionStore(defaults: defaults)
        before.refresh(snapshot(updatedAt: stamp))
        before.markAllRead()

        let after = AttentionStore(defaults: defaults)
        after.refresh(AttentionSnapshot())
        after.refresh(snapshot(updatedAt: stamp))
        XCTAssertEqual(after.items.count, 1)
        XCTAssertEqual(after.unreadCount, 0, "a read task row must not go unread on relaunch")
    }
}

extension TaskAttentionPersistenceTests {
    /// Task rows are derived from a scan that runs on its own schedule, so the
    /// snapshot legitimately has no task rows in it between scans — at launch,
    /// most of all. A row that blinks out for that reason has not been dealt
    /// with, and clearing it must survive the gap.
    func testClearedRowSurvivesASnapshotWithoutTheTaskScan() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AttentionStore(defaults: defaults)

        store.refresh(snapshot(updatedAt: stamp))
        store.resolveAll()
        XCTAssertTrue(store.items.isEmpty)

        // The task scan has not produced anything yet on this pass.
        store.refresh(AttentionSnapshot())
        // …and now it has, with exactly the same occurrence as before.
        store.refresh(snapshot(updatedAt: stamp))

        XCTAssertTrue(store.items.isEmpty, "a cleared row must not return because a scan was between passes")
    }
}
