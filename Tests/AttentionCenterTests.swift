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
            AttentionEngine.conflictDetail(["a", "b", "c", "d"]).contains("4 dosyada")
        )
        XCTAssertFalse(
            AttentionEngine.conflictDetail(["a"]).contains("dosyada")
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
            kind: .testFailure, title: "uncoil › iş", detail: "3 test başarısız",
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
