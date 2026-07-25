import XCTest
@testable import Uncoil

final class TaskWorktreePolicyTests: XCTestCase {
    private var task: ProjectTask {
        TodoParser.parse(
            "- [ ] daemon heartbeat ekle\n", path: "/repo/TODO.md"
        ).tasks[0]
    }

    func testOnlyWritingRolesGetAWorktree() {
        let policy = TaskWorktreePolicy.default
        XCTAssertTrue(policy.needsWorktree(role: .implementer))
        XCTAssertTrue(policy.needsWorktree(role: .tester))
        XCTAssertFalse(
            policy.needsWorktree(role: .reviewer),
            "a reviewer reads; a checkout costs disk and buys nothing"
        )
        XCTAssertFalse(policy.needsWorktree(role: .observer))
        XCTAssertFalse(policy.needsWorktree(role: .orchestrator))
    }

    func testWorktreeNameIsASafeBoundedSlug() {
        let name = TaskWorktreePolicy.worktreeName(for: task)
        XCTAssertEqual(name, "daemon-heartbeat-ekle")
        XCTAssertTrue(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertLessThanOrEqual(name.count, 40)
    }

    func testNameFallsBackToTheFingerprintWhenTheTextYieldsNothing() {
        let punctuation = TodoParser.parse("- [ ] ??? !!!\n", path: "/repo/TODO.md").tasks[0]
        let name = TaskWorktreePolicy.worktreeName(for: punctuation)
        XCTAssertTrue(name.hasPrefix("task-"))
        XCTAssertGreaterThan(name.count, 5)
    }

    func testUnfinishedOrDirtyWorktreesAreNeverRemoved() {
        var policy = TaskWorktreePolicy.default
        XCTAssertEqual(policy.cleanup, .manual, "cleanup is the user's call by default")
        XCTAssertFalse(policy.mayRemove(worktreeIsClean: true, taskCompleted: true))

        policy.cleanup = .afterCompletedAndClean
        XCTAssertTrue(policy.mayRemove(worktreeIsClean: true, taskCompleted: true))
        XCTAssertFalse(
            policy.mayRemove(worktreeIsClean: false, taskCompleted: true),
            "uncommitted work is never thrown away"
        )
        XCTAssertFalse(
            policy.mayRemove(worktreeIsClean: true, taskCompleted: false),
            "an unfinished task keeps its worktree"
        )

        policy.cleanup = .anyClean
        XCTAssertTrue(policy.mayRemove(worktreeIsClean: true, taskCompleted: false))
        XCTAssertFalse(policy.mayRemove(worktreeIsClean: false, taskCompleted: false))
    }

    func testConflictSerialisationIsOnByDefaultAndCanBeTurnedOff() {
        var policy = TaskWorktreePolicy.default
        XCTAssertTrue(policy.serialisesConflictingTasks)
        policy.serialisesConflictingTasks = false
        XCTAssertFalse(policy.serialisesConflictingTasks)
    }

    func testPolicyRoundTripsThroughCoding() throws {
        var policy = TaskWorktreePolicy.default
        policy.cleanup = .anyClean
        policy.maxWorktrees = 7
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(TaskWorktreePolicy.self, from: data), policy)
    }
}

final class TaskCompletionGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func test(
        passed: Bool,
        at offset: TimeInterval = 0,
        summary: String = "3 test"
    ) -> TaskTestResult {
        TaskTestResult(
            taskID: "t1", command: "swift test", passed: passed,
            summary: summary, finishedAt: now.addingTimeInterval(offset)
        )
    }

    private func review(
        _ verdict: TaskReviewResult.Verdict,
        at offset: TimeInterval = 0
    ) -> TaskReviewResult {
        TaskReviewResult(
            taskID: "t1", verdict: verdict, findings: ["şurada bir sorun var"],
            finishedAt: now.addingTimeInterval(offset)
        )
    }

    // MARK: - Completion

    func testAFailingTestBlocksTheCheckbox() {
        let blockers = TaskCompletionGate.mayComplete(
            tests: [test(passed: false, summary: "2 başarısız")], requiresTests: true
        )
        XCTAssertEqual(blockers, [.testsFailing("2 başarısız")])
        XCTAssertTrue(blockers[0].message.contains("2 başarısız"))
    }

    func testALaterPassingRunClearsAnEarlierFailure() {
        XCTAssertTrue(
            TaskCompletionGate.mayComplete(
                tests: [test(passed: false, at: 0), test(passed: true, at: 60)],
                requiresTests: true
            ).isEmpty
        )
    }

    func testAnEarlierPassDoesNotExcuseALaterFailure() {
        XCTAssertEqual(
            TaskCompletionGate.mayComplete(
                tests: [test(passed: true, at: 0), test(passed: false, at: 60, summary: "kırıldı")],
                requiresTests: true
            ),
            [.testsFailing("kırıldı")]
        )
    }

    func testMissingTestsBlockOnlyWhenTestsAreRequired() {
        XCTAssertEqual(
            TaskCompletionGate.mayComplete(tests: [], requiresTests: true), [.testsMissing]
        )
        XCTAssertTrue(
            TaskCompletionGate.mayComplete(tests: [], requiresTests: false).isEmpty
        )
    }

    func testReviewCommentsDoNotBlockCompletion() {
        // A finished task with review comments is still finished work; only the
        // merge gate cares about the verdict.
        XCTAssertTrue(
            TaskCompletionGate.mayComplete(
                tests: [test(passed: true)], requiresTests: true
            ).isEmpty
        )
    }

    // MARK: - Merge

    private var strictSettings: OrchestratorSettings {
        var settings = OrchestratorSettings.default
        settings.automaticReview = true
        settings.automaticTests = true
        return settings
    }

    func testEverythingLinedUpAndApprovedMerges() {
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: true)], reviews: [review(.approved)],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: strictSettings
            ).isEmpty
        )
    }

    func testMergeWaitsForTheUserEvenWhenEverythingElseIsReady() {
        let blockers = TaskCompletionGate.mayMerge(
            tests: [test(passed: true)], reviews: [review(.approved)],
            conflictedFiles: [], uncommittedChanges: 0,
            userApproved: false, settings: strictSettings
        )
        XCTAssertEqual(blockers, [.approvalRequired])
    }

    func testChangesRequestedBlocksMergeEvenWithoutAutomaticReview() {
        var settings = strictSettings
        settings.automaticReview = false
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: true)], reviews: [review(.changesRequested)],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: settings
            ).contains(.changesRequested)
        )
    }

    func testMissingReviewBlocksOnlyWhenReviewIsAutomatic() {
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: true)], reviews: [],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: strictSettings
            ).contains(.reviewMissing)
        )

        var settings = strictSettings
        settings.automaticReview = false
        XCTAssertFalse(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: true)], reviews: [],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: settings
            ).contains(.reviewMissing)
        )
    }

    func testConflictsAndUncommittedChangesBlockMerge() {
        let blockers = TaskCompletionGate.mayMerge(
            tests: [test(passed: true)], reviews: [review(.approved)],
            conflictedFiles: ["App/Core/Models.swift"], uncommittedChanges: 2,
            userApproved: true, settings: strictSettings
        )
        XCTAssertTrue(blockers.contains(.mergeConflict(["App/Core/Models.swift"])))
        XCTAssertTrue(blockers.contains(.uncommittedChanges(2)))
    }

    func testAFailingTestBlocksMergeToo() {
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: false, summary: "kırık")], reviews: [review(.approved)],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: strictSettings
            ).contains(.testsFailing("kırık"))
        )
    }

    func testTheLatestReviewIsTheOneThatCounts() {
        XCTAssertTrue(
            TaskCompletionGate.mayMerge(
                tests: [test(passed: true)],
                reviews: [review(.changesRequested, at: 0), review(.approved, at: 60)],
                conflictedFiles: [], uncommittedChanges: 0,
                userApproved: true, settings: strictSettings
            ).isEmpty
        )
    }

    func testPreviewSeparatesHardBlockersFromWaitingForTheUser() {
        let preview = TaskCompletionGate.MergePreview(
            branch: "uncoil/heartbeat",
            changedFiles: ["App/Terminal/RuntimeClient.swift"],
            conflictedFiles: [],
            tests: [test(passed: true)],
            reviews: [review(.approved)],
            blockers: [.approvalRequired]
        )
        XCTAssertFalse(preview.isReady)
        XCTAssertTrue(
            preview.hardBlockers.isEmpty,
            "waiting for the user is not a problem to fix"
        )
    }
}

final class TaskReviewResultTests: XCTestCase {
    func testFeedbackCarriesTheFindingsBackToTheImplementer() {
        let review = TaskReviewResult(
            taskID: "t1", verdict: .changesRequested,
            findings: ["hata yolu ele alınmamış", "test yok"]
        )
        let prompt = review.feedbackPrompt(taskText: "daemon heartbeat ekle")
        XCTAssertTrue(prompt.contains("Değişiklik istendi"))
        XCTAssertTrue(prompt.contains("hata yolu ele alınmamış"))
        XCTAssertTrue(prompt.contains("test yok"))
        XCTAssertTrue(
            prompt.contains("Checkbox'ı şimdi işaretleme"),
            "an implementer told to fix things must not tick the box"
        )
    }

    func testAnApprovalDoesNotTellTheImplementerToStop() {
        let prompt = TaskReviewResult(taskID: "t1", verdict: .approved)
            .feedbackPrompt(taskText: "iş")
        XCTAssertTrue(prompt.contains("Onaylandı"))
        XCTAssertFalse(prompt.contains("Checkbox'ı şimdi işaretleme"))
    }

    func testEveryVerdictHasALabel() {
        for verdict in TaskReviewResult.Verdict.allCases {
            XCTAssertFalse(verdict.label.isEmpty)
        }
    }
}

final class TaskTestResultTests: XCTestCase {
    func testATestRunCarriesItsArtifactsAndSession() {
        let session = UUID()
        let result = TaskTestResult(
            taskID: "t1", sessionID: session, command: "swift test",
            passed: false, summary: "1 başarısız", artifacts: ["test-output.txt"]
        )
        XCTAssertEqual(result.sessionID, session)
        XCTAssertEqual(result.artifacts, ["test-output.txt"])
        XCTAssertFalse(result.passed)
    }

    func testResultsRoundTripThroughCoding() throws {
        let result = TaskTestResult(
            taskID: "t1", command: "swift test", passed: true, summary: "ok",
            finishedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(TaskTestResult.self, from: data), result)
    }
}
