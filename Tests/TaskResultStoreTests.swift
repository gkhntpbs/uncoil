import XCTest
@testable import Uncoil

@MainActor
final class TaskResultStoreTests: XCTestCase {
    private var directory: URL!
    private var projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTaskResults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func store() -> TaskResultStore {
        TaskResultStore(projectID: projectID, dataDirectory: directory)
    }

    private func test(
        _ passed: Bool,
        at offset: TimeInterval = 0,
        summary: String = "3 test"
    ) -> TaskTestResult {
        TaskTestResult(
            taskID: "t1", command: "xcodebuild test", passed: passed, summary: summary,
            artifacts: ["test-output.txt"],
            finishedAt: Date(timeIntervalSince1970: 1_000 + offset)
        )
    }

    func testResultsSurviveAReload() {
        let first = store()
        first.record(test: test(true))
        first.record(review: TaskReviewResult(taskID: "t1", verdict: .approved))
        first.record(merge: TaskMergeRecord(
            taskID: "t1", branch: "uncoil/t1", outcome: .merged(commit: "abc1234"),
            approvedByUser: true
        ))

        let reloaded = store()
        XCTAssertEqual(reloaded.tests(for: "t1").count, 1)
        XCTAssertEqual(reloaded.latestReview(for: "t1")?.verdict, .approved)
        XCTAssertEqual(reloaded.merges(for: "t1").first?.outcome, .merged(commit: "abc1234"))
        XCTAssertEqual(
            reloaded.tests(for: "t1").first?.artifacts, ["test-output.txt"],
            "the artifacts stay attached to the run"
        )
    }

    func testResultsAreKeptPerTask() {
        let store = self.store()
        store.record(test: test(true))
        store.record(test: TaskTestResult(
            taskID: "t2", command: "swift test", passed: false, summary: "kırık"
        ))
        XCTAssertEqual(store.tests(for: "t1").count, 1)
        XCTAssertEqual(store.latestTest(for: "t2")?.passed, false)
        XCTAssertTrue(store.tests(for: "yok").isEmpty)
    }

    func testTheLatestRunIsTheOneThatCounts() {
        let store = self.store()
        store.record(test: test(false, at: 0, summary: "kırık"))
        store.record(test: test(true, at: 60))
        XCTAssertEqual(store.latestTest(for: "t1")?.passed, true)
        XCTAssertTrue(
            store.completionBlockers(taskID: "t1", settings: .default).isEmpty,
            "a later passing run clears the earlier failure"
        )
    }

    func testAFailingRunBlocksCompletion() {
        let store = self.store()
        store.record(test: test(false, summary: "2 başarısız"))
        let blockers = store.completionBlockers(taskID: "t1", settings: .default)
        XCTAssertEqual(blockers, [.testsFailing("2 başarısız")])
    }

    func testMissingTestsOnlyBlockWhenTestsAreAutomatic() {
        let store = self.store()
        var settings = OrchestratorSettings.default
        settings.automaticTests = true
        XCTAssertEqual(
            store.completionBlockers(taskID: "t1", settings: settings), [.testsMissing]
        )
        settings.automaticTests = false
        XCTAssertTrue(store.completionBlockers(taskID: "t1", settings: settings).isEmpty)
    }

    func testRequestedChangesAreSurfacedForTheBoard() {
        let store = self.store()
        store.record(review: TaskReviewResult(
            taskID: "t1", verdict: .changesRequested, findings: ["hata yolu yok"],
            finishedAt: Date(timeIntervalSince1970: 100)
        ))
        store.record(review: TaskReviewResult(
            taskID: "t2", verdict: .approved,
            finishedAt: Date(timeIntervalSince1970: 5)
        ))
        XCTAssertEqual(store.tasksWithRequestedChanges, ["t1"])

        // A later approval clears it — the newest verdict wins.
        store.record(review: TaskReviewResult(
            taskID: "t1", verdict: .approved, finishedAt: Date(timeIntervalSince1970: 9_999)
        ))
        XCTAssertTrue(store.tasksWithRequestedChanges.isEmpty)
    }

    func testMergePreviewCollectsEverythingTheScreenShows() {
        let store = self.store()
        store.record(test: test(true))
        store.record(review: TaskReviewResult(taskID: "t1", verdict: .approved))
        var settings = OrchestratorSettings.default
        settings.automaticTests = true
        settings.automaticReview = true

        let waiting = store.mergePreview(
            taskID: "t1", branch: "uncoil/t1", changedFiles: ["App/Core/Models.swift"],
            conflictedFiles: [], uncommittedChanges: 0, userApproved: false, settings: settings
        )
        XCTAssertEqual(waiting.branch, "uncoil/t1")
        XCTAssertEqual(waiting.changedFiles, ["App/Core/Models.swift"])
        XCTAssertEqual(waiting.tests.count, 1)
        XCTAssertFalse(waiting.isReady)
        XCTAssertTrue(
            waiting.hardBlockers.isEmpty,
            "only the user's approval is missing, which is not a problem to fix"
        )

        let approved = store.mergePreview(
            taskID: "t1", branch: "uncoil/t1", changedFiles: [], conflictedFiles: [],
            uncommittedChanges: 0, userApproved: true, settings: settings
        )
        XCTAssertTrue(approved.isReady)
    }

    func testUncommittedChangesAndConflictsBlockTheMerge() {
        let store = self.store()
        store.record(test: test(true))
        store.record(review: TaskReviewResult(taskID: "t1", verdict: .approved))
        let preview = store.mergePreview(
            taskID: "t1", branch: "b", changedFiles: ["a"], conflictedFiles: ["a"],
            uncommittedChanges: 1, userApproved: true, settings: .default
        )
        XCTAssertTrue(preview.blockers.contains(.mergeConflict(["a"])))
        XCTAssertTrue(preview.blockers.contains(.uncommittedChanges(1)))
        XCTAssertFalse(preview.hardBlockers.isEmpty)
    }

    func testEveryMergeAttemptIsAudited() throws {
        let store = self.store()
        store.record(merge: TaskMergeRecord(
            taskID: "t1", branch: "uncoil/t1",
            outcome: .refused(reason: "kullanıcı onayı bekleniyor"), approvedByUser: false,
            at: Date(timeIntervalSince1970: 0)
        ))
        store.record(merge: TaskMergeRecord(
            taskID: "t1", branch: "uncoil/t1", outcome: .merged(commit: "deadbee"),
            approvedByUser: true, at: Date(timeIntervalSince1970: 60)
        ))
        let audit = try String(contentsOf: store.auditFileURL, encoding: .utf8)
        let lines = audit.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "a refusal is audited too")
        XCTAssertTrue(lines[0].contains("refused"))
        XCTAssertTrue(lines[0].contains("unapproved"))
        XCTAssertTrue(lines[1].contains("merged deadbee"))
        XCTAssertTrue(lines[1].contains("approved"))
    }

    func testTheAuditFileIsAppendedToNotRewritten() throws {
        store().record(merge: TaskMergeRecord(
            taskID: "t1", outcome: .failed(message: "çakışma"), approvedByUser: true
        ))
        let second = store()
        second.record(merge: TaskMergeRecord(
            taskID: "t2", outcome: .merged(commit: nil), approvedByUser: true
        ))
        let audit = try String(contentsOf: second.auditFileURL, encoding: .utf8)
        XCTAssertEqual(audit.split(separator: "\n").count, 2)
        XCTAssertTrue(audit.contains("t1"))
        XCTAssertTrue(audit.contains("t2"))
    }
}
