import XCTest
@testable import Uncoil

final class TaskOrchestratorPlanningTests: XCTestCase {
    private let projectID = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    private func tasks(_ raw: String) -> [ProjectTask] {
        TodoParser.parse(raw, path: "/repo/TODO.md").tasks
    }

    private func input(
        _ tasks: [ProjectTask],
        settings: OrchestratorSettings = OrchestratorSettings(
            automaticReview: false, automaticTests: false
        ),
        assignments: [String: [TaskSessionAssignment]] = [:],
        claimStates: [String: TaskClaimState] = [:]
    ) -> TaskOrchestrator.Input {
        TaskOrchestrator.Input(
            projectID: projectID, tasks: tasks, assignments: assignments,
            claimStates: claimStates, settings: settings, now: now
        )
    }

    // MARK: - What gets planned

    func testDoneTasksAndTakenTasksAreNotPlanned() {
        let list = tasks("""
        - [ ] açık iş
        - [x] bitmiş iş
        - [ ] başkasında
        """)
        let plan = TaskOrchestrator.plan(input(
            list,
            claimStates: [list[2].id: .running]
        ))
        XCTAssertEqual(plan.dispatches.map(\.taskText), ["açık iş"])
        XCTAssertTrue(plan.skipped.contains { $0.taskID == list[2].id })
        XCTAssertFalse(
            plan.skipped.contains { $0.taskID == list[1].id },
            "a finished task is simply not work, not a skip to explain"
        )
    }

    func testAnActiveAssignmentIsSkippedWithAReason() {
        let list = tasks("- [ ] iş\n")
        let assignment = TaskSessionAssignment(
            taskID: list[0].id, sourcePath: list[0].sourcePath,
            sessionID: UUID(), role: .implementer, state: .running
        )
        let plan = TaskOrchestrator.plan(input(list, assignments: [list[0].id: [assignment]]))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.skipped.first?.reason, "already being worked on")
    }

    func testAParentWithSubtasksIsLeftToItsChildren() {
        let list = tasks("""
        - [ ] üst iş
          - [ ] alt bir
          - [ ] alt iki
        """)
        let plan = TaskOrchestrator.plan(input(list))
        XCTAssertEqual(Set(plan.dispatches.map(\.taskText)), ["alt bir", "alt iki"])
        XCTAssertTrue(plan.skipped.contains { $0.taskID == list[0].id })
    }

    // MARK: - Order and parallelism

    func testTasksFollowTheFilesOwnOrder() {
        let list = tasks("""
        - [ ] birinci
        - [ ] ikinci
        - [ ] üçüncü
        """)
        XCTAssertEqual(
            TaskOrchestrator.prioritise(list).map(\.text),
            ["birinci", "ikinci", "üçüncü"]
        )
    }

    func testIndependentTasksShareOneWave() {
        let plan = TaskOrchestrator.plan(input(tasks("""
        - [ ] ikonları çiz
        - [ ] metinleri çevir
        - [ ] sesleri ekle
        """)))
        XCTAssertEqual(plan.waves.count, 1)
        XCTAssertEqual(plan.waves[0].count, 3)
    }

    func testParallelismCeilingPushesOverflowToLaterWaves() {
        var settings = OrchestratorSettings(automaticReview: false, automaticTests: false)
        settings.maxParallelAgents = 2
        let plan = TaskOrchestrator.plan(input(tasks("""
        - [ ] bir
        - [ ] iki
        - [ ] üç
        - [ ] dört
        """), settings: settings))
        XCTAssertEqual(plan.waves.map(\.count), [2, 2])
    }

    func testParallelismIsClampedToASaneCeiling() {
        var settings = OrchestratorSettings()
        settings.maxParallelAgents = 500
        XCTAssertEqual(settings.effectiveParallelism, 8)
        settings.maxParallelAgents = 0
        XCTAssertEqual(settings.effectiveParallelism, 1)
    }

    func testTasksTouchingTheSameFileAreSerialised() {
        let plan = TaskOrchestrator.plan(input(tasks("""
        - [ ] App/Core/Models.swift içine alan ekle
        - [ ] App/Core/Models.swift içindeki alanı kullan
        - [ ] docs/README.md güncelle
        """)))
        let models = plan.dispatches.filter { $0.taskText.contains("Models.swift") }
        XCTAssertEqual(models.count, 2)
        XCTAssertNotEqual(
            models[0].wave, models[1].wave,
            "two tasks on one file must not run side by side"
        )
        XCTAssertEqual(models[1].serialReason, "touches the same files")
        XCTAssertTrue(models.allSatisfy(\.needsWorktree))
    }

    func testAFileMentionedByOneTaskOnlyIsNotAConflict() {
        let plan = TaskOrchestrator.plan(input(tasks("""
        - [ ] App/Core/Models.swift düzenle
        - [ ] docs/README.md güncelle
        """)))
        XCTAssertEqual(plan.waves.count, 1)
        XCTAssertTrue(plan.dispatches.allSatisfy { !$0.needsWorktree })
    }

    func testExplicitOrderingCreatesADependency() {
        let list = tasks("""
        - [ ] veritabanı şemasını oluştur
        - [ ] veritabanı şemasını oluştur işi bittikten sonra migration yaz
        """)
        let plan = TaskOrchestrator.plan(input(list))
        let second = plan.dispatches.first { $0.taskText.contains("migration") }
        XCTAssertEqual(second?.dependsOn, [list[0].id])
        XCTAssertGreaterThan(second?.wave ?? 0, 0)
    }

    func testOnlyAnEarlierTaskCanBeABlocker() {
        // Two tasks worded the same way, so each one's text appears in the
        // other's block and both carry an ordering word. Without the
        // earlier-only rule this pair would wait on each other forever.
        let list = tasks("""
        ## A
        - [ ] şema oluştur sonra migration yaz
        ## B
        - [ ] şema oluştur sonra migration yaz
        """)
        XCTAssertNotEqual(list[0].id, list[1].id)
        let map = TaskOrchestrator.dependencyMap(list, all: list)
        XCTAssertNil(
            map[list[0].id],
            "the first task cannot depend on one that comes after it"
        )
        XCTAssertEqual(map[list[1].id], [list[0].id])
    }

    func testWithoutAnOrderingWordAMentionIsNotADependency() {
        let list = tasks("""
        - [ ] şema oluştur
        - [ ] şema oluştur ile ilgili notları güncelle
        """)
        XCTAssertTrue(
            TaskOrchestrator.dependencyMap(list, all: list).isEmpty,
            "merely naming another task does not make it a blocker"
        )
    }

    // MARK: - Roles and providers

    func testReviewAndTestFollowTheImplementation() {
        var settings = OrchestratorSettings()
        settings.allowedProviders = [.claude, .codex]
        let plan = TaskOrchestrator.plan(input(tasks("- [ ] iş\n"), settings: settings))
        let implement = plan.dispatches.first { $0.role == .implementer }
        let review = plan.dispatches.first { $0.role == .reviewer }
        let test = plan.dispatches.first { $0.role == .tester }
        XCTAssertNotNil(implement)
        XCTAssertEqual(review?.wave, (implement?.wave ?? 0) + 1)
        XCTAssertEqual(test?.wave, (implement?.wave ?? 0) + 1)
        XCTAssertEqual(review?.dependsOn, implement.map { [$0.taskID] })
    }

    func testReviewPrefersADifferentProvider() {
        var settings = OrchestratorSettings()
        settings.allowedProviders = [.claude, .codex]
        let plan = TaskOrchestrator.plan(input(tasks("- [ ] iş\n"), settings: settings))
        let implement = plan.dispatches.first { $0.role == .implementer }
        let review = plan.dispatches.first { $0.role == .reviewer }
        XCTAssertNotEqual(
            implement?.provider, review?.provider,
            "a second pair of eyes is worth more from another model"
        )
    }

    func testASingleAllowedProviderIsUsedForEverything() {
        var settings = OrchestratorSettings()
        settings.allowedProviders = [.codex]
        let plan = TaskOrchestrator.plan(input(tasks("- [ ] iş\n"), settings: settings))
        XCTAssertTrue(plan.dispatches.allSatisfy { $0.provider == .codex })
    }

    func testDisablingAutomaticReviewAndTestsLeavesOnlyImplementation() {
        let plan = TaskOrchestrator.plan(input(tasks("- [ ] iş\n")))
        XCTAssertEqual(plan.dispatches.map(\.role), [.implementer])
    }

    // MARK: - Settings

    func testApprovalForMergeAndDestructiveIsOnByDefault() {
        let settings = OrchestratorSettings.default
        XCTAssertTrue(settings.requiresApprovalForMerge)
        XCTAssertTrue(settings.requiresApprovalForDestructive)
        XCTAssertFalse(settings.automaticRetry, "retrying is opt-in")
    }

    func testProviderAndModelAllowLists() {
        var settings = OrchestratorSettings()
        settings.allowedProviders = [.claude]
        XCTAssertTrue(settings.allows(provider: .claude))
        XCTAssertFalse(settings.allows(provider: .codex))

        XCTAssertTrue(settings.allows(model: "anything"), "empty list means no restriction")
        settings.allowedModels = ["opus"]
        XCTAssertTrue(settings.allows(model: "opus"))
        XCTAssertFalse(settings.allows(model: "haiku"))
    }

    func testBudgetFieldsExistForLaterAccounting() {
        var settings = OrchestratorSettings()
        XCTAssertNil(settings.tokenBudget)
        settings.tokenBudget = 500_000
        settings.costBudgetUSD = 12.5
        XCTAssertEqual(settings.tokenBudget, 500_000)
        XCTAssertEqual(settings.costBudgetUSD, 12.5)
    }

    // MARK: - Preview

    func testPlanSummaryNamesWavesRolesAndSkips() {
        let list = tasks("""
        - [ ] App/Core/Models.swift düzenle
        - [ ] App/Core/Models.swift tekrar düzenle
        - [ ] başkasında olan iş
        """)
        let plan = TaskOrchestrator.plan(input(
            list, claimStates: [list[2].id: .claimed]
        ))
        let summary = plan.summary()
        XCTAssertTrue(summary.contains("Wave 1"))
        XCTAssertTrue(summary.contains("Wave 2"))
        XCTAssertTrue(summary.contains("Implementer"))
        XCTAssertTrue(summary.contains("[worktree]"))
        XCTAssertTrue(summary.contains("Skipped"))
    }
}

final class TaskOrchestratorRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let session = UUID()

    private func assignment(
        _ state: ProjectTaskExecutionState,
        taskID: String = "t1",
        role: TaskAgentRole = .implementer,
        worktree: String? = nil
    ) -> TaskSessionAssignment {
        TaskSessionAssignment(
            taskID: taskID, sourcePath: "/repo/TODO.md", sessionID: session,
            role: role, state: state, worktreePath: worktree
        )
    }

    private func lease(taskID: String = "t1", duration: TimeInterval = 900) -> TaskClaimLease {
        TaskClaimLease(
            taskID: taskID, sourcePath: "/repo/TODO.md", sessionID: session,
            acquiredAt: now, duration: duration
        )
    }

    func testAFailedAgentMarksTheTaskFailedAndRaisesAttention() {
        let actions = TaskOrchestrator.recover(
            assignments: [assignment(.failed)],
            leases: [:], lastHeartbeats: [:],
            settings: .default, now: now
        )
        XCTAssertTrue(actions.contains(.markFailed(taskID: "t1", reason: "Failed")))
        XCTAssertTrue(actions.contains { action in
            if case .reportToAttention = action { return true }
            return false
        })
    }

    func testAPartialWorktreeIsShownBeforeHandoverAndNeverDiscarded() {
        let actions = TaskOrchestrator.recover(
            assignments: [assignment(.failed, worktree: "/repo/.uncoil-worktrees/x")],
            leases: [:], lastHeartbeats: [:], settings: .default, now: now
        )
        XCTAssertTrue(actions.contains(
            .showDiffBeforeHandover(taskID: "t1", worktreePath: "/repo/.uncoil-worktrees/x")
        ))
        XCTAssertFalse(
            actions.contains { action in
                if case .releaseClaim = action { return true }
                return false
            },
            "a failed run does not silently drop its claim while its diff is unreviewed"
        )
    }

    func testRequeueOnlyWhenRetryIsEnabledAndBudgetRemains() {
        var settings = OrchestratorSettings.default
        XCTAssertFalse(
            TaskOrchestrator.recover(
                assignments: [assignment(.failed)], leases: [:], lastHeartbeats: [:],
                settings: settings, now: now
            ).contains(.requeue(taskID: "t1"))
        )

        settings.automaticRetry = true
        XCTAssertTrue(
            TaskOrchestrator.recover(
                assignments: [assignment(.failed)], leases: [:], lastHeartbeats: [:],
                settings: settings, now: now
            ).contains(.requeue(taskID: "t1"))
        )

        XCTAssertFalse(
            TaskOrchestrator.recover(
                assignments: [assignment(.failed)], leases: [:], lastHeartbeats: [:],
                settings: settings, retriesSoFar: ["t1": 1], now: now
            ).contains(.requeue(taskID: "t1")),
            "the retry ceiling is respected"
        )
    }

    func testALostHeartbeatReleasesTheClaim() {
        let actions = TaskOrchestrator.recover(
            assignments: [assignment(.running)],
            leases: ["t1": lease()],
            lastHeartbeats: ["t1": now],
            settings: .default,
            now: now.addingTimeInterval(600)
        )
        XCTAssertTrue(actions.contains(.releaseClaim(taskID: "t1", reason: "the heartbeat disappeared")))
        XCTAssertTrue(actions.contains(.markFailed(taskID: "t1", reason: "the agent is not responding")))
    }

    func testALiveAgentIsLeftAlone() {
        let actions = TaskOrchestrator.recover(
            assignments: [assignment(.running)],
            leases: ["t1": lease()],
            lastHeartbeats: ["t1": now.addingTimeInterval(30)],
            settings: .default,
            now: now.addingTimeInterval(40)
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func testWaitingStatesAreNotTreatedAsFailures() {
        for state in [
            ProjectTaskExecutionState.waitingForPermission, .waitingForUser, .reviewRequested,
        ] {
            XCTAssertTrue(
                TaskOrchestrator.recover(
                    assignments: [assignment(state)], leases: [:], lastHeartbeats: [:],
                    settings: .default, now: now
                ).isEmpty,
                state.rawValue
            )
        }
    }
}

@MainActor
final class OrchestratorStoreTests: XCTestCase {
    private var directory: URL!
    private let projectID = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilOrch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func store() -> OrchestratorStore {
        OrchestratorStore(projectID: projectID, dataDirectory: directory)
    }

    private var plan: OrchestratorPlan {
        OrchestratorPlan(
            projectID: projectID,
            dispatches: [
                PlannedDispatch(
                    taskID: "t1", taskText: "bir", sourcePath: "/repo/TODO.md",
                    role: .implementer, provider: .claude, wave: 0,
                    needsWorktree: true, dependsOn: [], serialReason: nil
                ),
                PlannedDispatch(
                    taskID: "t1", taskText: "bir", sourcePath: "/repo/TODO.md",
                    role: .reviewer, provider: .codex, wave: 1,
                    needsWorktree: false, dependsOn: ["t1"], serialReason: nil
                ),
            ],
            createdAt: now,
            skipped: []
        )
    }

    func testAPlanSurvivesARestartAndResumesWhereItStopped() {
        let store = store()
        store.store(plan)
        XCTAssertEqual(store.pending.count, 2)

        store.markDispatched(taskID: "t1", role: .implementer)
        XCTAssertEqual(store.pending.map(\.role), [.reviewer])

        let reloaded = self.store()
        XCTAssertEqual(
            reloaded.pending.map(\.role), [.reviewer],
            "a restart picks the plan up rather than starting over"
        )
    }

    func testPendingIsOrderedByWave() {
        let store = store()
        store.store(plan)
        XCTAssertEqual(store.pending.map(\.wave), [0, 1])
    }

    func testAChildsResultOutlivesTheParentSession() {
        let store = store()
        store.record(result: "3 test geçti", taskID: "t1")
        XCTAssertEqual(self.store().result(for: "t1"), "3 test geçti")
    }

    func testRetriesAreCounted() {
        let store = store()
        XCTAssertEqual(store.retries(for: "t1"), 0)
        store.noteRetry(taskID: "t1")
        store.noteRetry(taskID: "t1")
        XCTAssertEqual(self.store().retries(for: "t1"), 2)
    }

    func testSettingsPersist() {
        let store = store()
        var settings = OrchestratorSettings.default
        settings.maxParallelAgents = 5
        settings.automaticRetry = true
        store.update(settings: settings)
        XCTAssertEqual(self.store().settings.maxParallelAgents, 5)
        XCTAssertTrue(self.store().settings.automaticRetry)
    }

    func testClearingThePlanKeepsResults() {
        let store = store()
        store.store(plan)
        store.record(result: "sonuç", taskID: "t1")
        store.clearPlan()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.result(for: "t1"), "sonuç")
    }
}

final class OrchestratorPresetTests: XCTestCase {
    func testTheOrchestratorPresetCanSpawnAndCutWorktreesButNotDeleteOrMerge() throws {
        let preset = try XCTUnwrap(
            SessionPreset.builtInDefaults.first { $0.id == "task-orchestrator" }
        )
        let grants = Set(preset.grantedCapabilities)
        XCTAssertTrue(grants.contains("tasks.read"))
        XCTAssertTrue(grants.contains("tasks.write"))
        XCTAssertTrue(grants.contains("tasks.orchestrate"))
        XCTAssertTrue(grants.contains("tasks.worktree"))
        XCTAssertTrue(grants.contains("projects.read"))
        XCTAssertTrue(grants.contains("worktrees.create"))
        XCTAssertTrue(grants.contains("sessions.create_children"))
        XCTAssertFalse(
            grants.contains("tasks.delete"),
            "destroying work stays with the user"
        )
        XCTAssertFalse(
            grants.contains("tasks.merge"),
            "merging stays with the user"
        )
    }
}
