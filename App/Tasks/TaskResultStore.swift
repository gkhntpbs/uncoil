import Foundation

/// What happened when a task's work was merged — or refused.
///
/// Kept whether the merge succeeded or not: "we declined to merge, and why" is
/// exactly the record a user comes back for.
struct TaskMergeRecord: Identifiable, Equatable, Codable {
    enum Outcome: Equatable, Codable {
        case merged(commit: String?)
        case refused(reason: String)
        case failed(message: String)

        var label: String {
            switch self {
            case .merged: "Merge edildi"
            case .refused: "Reddedildi"
            case .failed: "Başarısız"
            }
        }

        var succeeded: Bool {
            if case .merged = self { return true }
            return false
        }
    }

    let id: UUID
    var taskID: String
    var branch: String?
    var worktreePath: String?
    var outcome: Outcome
    /// Whether the user explicitly approved this attempt. Never inferred.
    var approvedByUser: Bool
    var at: Date

    init(
        id: UUID = UUID(),
        taskID: String,
        branch: String? = nil,
        worktreePath: String? = nil,
        outcome: Outcome,
        approvedByUser: Bool,
        at: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.branch = branch
        self.worktreePath = worktreePath
        self.outcome = outcome
        self.approvedByUser = approvedByUser
        self.at = at
    }

    /// One audit line, appended to `task-merges.jsonl`.
    var auditLine: String {
        let stamp = ISO8601DateFormatter().string(from: at)
        let detail: String
        switch outcome {
        case .merged(let commit): detail = "merged \(commit ?? "-")"
        case .refused(let reason): detail = "refused: \(reason)"
        case .failed(let message): detail = "failed: \(message)"
        }
        return "\(stamp)\t\(taskID)\t\(branch ?? "-")\t"
            + "\(approvedByUser ? "approved" : "unapproved")\t\(detail)"
    }
}

/// Test runs, reviews and merge attempts for one project's tasks.
///
/// Separate from `ProjectTaskMetadataStore` on purpose: assignments describe who
/// is working, results describe what came of it, and results have to survive an
/// assignment being removed.
@MainActor
final class TaskResultStore: ObservableObject {
    struct Document: Codable, Equatable {
        static let currentVersion = 1
        var version = Document.currentVersion
        var tests: [TaskTestResult] = []
        var reviews: [TaskReviewResult] = []
        var merges: [TaskMergeRecord] = []
    }

    @Published private(set) var document = Document()

    /// Kept bounded: a task that is tested on every save would otherwise grow
    /// the file without limit.
    private let limitPerKind = 500

    private let fileURL: URL
    private let auditURL: URL

    init(projectID: UUID, dataDirectory: URL? = nil) {
        let directory = (dataDirectory ?? ProjectStore.defaultDirectory())
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        fileURL = directory.appendingPathComponent("results.json")
        auditURL = directory.appendingPathComponent("task-merges.jsonl")
        load()
    }

    // MARK: - Reading

    func tests(for taskID: String) -> [TaskTestResult] {
        document.tests.filter { $0.taskID == taskID }.sorted { $0.finishedAt < $1.finishedAt }
    }

    func reviews(for taskID: String) -> [TaskReviewResult] {
        document.reviews.filter { $0.taskID == taskID }.sorted { $0.finishedAt < $1.finishedAt }
    }

    func latestTest(for taskID: String) -> TaskTestResult? { tests(for: taskID).last }

    func latestReview(for taskID: String) -> TaskReviewResult? { reviews(for: taskID).last }

    func merges(for taskID: String) -> [TaskMergeRecord] {
        document.merges.filter { $0.taskID == taskID }.sorted { $0.at < $1.at }
    }

    /// Tasks whose latest review asked for changes — what the board badges.
    var tasksWithRequestedChanges: Set<String> {
        Set(
            Set(document.reviews.map(\.taskID))
                .filter { latestReview(for: $0)?.verdict == .changesRequested }
        )
    }

    // MARK: - Writing

    func record(test: TaskTestResult) {
        document.tests.append(test)
        trim(&document.tests)
        save()
    }

    func record(review: TaskReviewResult) {
        document.reviews.append(review)
        trim(&document.reviews)
        save()
    }

    /// Records a merge attempt and appends its audit line. Both happen for a
    /// refusal too.
    func record(merge: TaskMergeRecord) {
        document.merges.append(merge)
        trim(&document.merges)
        save()
        appendAudit(merge)
    }

    // MARK: - Gates

    /// The blockers Uncoil enforces when a checkbox is written: a failing run,
    /// and nothing else. "No test was ever run" is a policy preference for
    /// orchestrated work, not a reason to refuse an ordinary edit.
    func failingTestBlockers(taskID: String) -> [TaskCompletionGate.Blocker] {
        var blockers = TaskCompletionGate.mayComplete(
            tests: tests(for: taskID), requiresTests: false
        )
        // A review that asked for changes also stands in the way: a task whose
        // last word was "fix this" is not done, whoever ticks the box.
        if latestReview(for: taskID)?.verdict == .changesRequested {
            blockers.append(.changesRequested)
        }
        return blockers
    }

    /// Blockers standing between this task and a ticked checkbox, under the
    /// project's own policy — what the board and `get_task_results` report.
    func completionBlockers(
        taskID: String,
        settings: OrchestratorSettings
    ) -> [TaskCompletionGate.Blocker] {
        TaskCompletionGate.mayComplete(
            tests: tests(for: taskID), requiresTests: settings.automaticTests
        )
    }

    /// Everything the merge screen shows, blockers included.
    func mergePreview(
        taskID: String,
        branch: String?,
        changedFiles: [String],
        conflictedFiles: [String],
        uncommittedChanges: Int,
        userApproved: Bool,
        settings: OrchestratorSettings
    ) -> TaskCompletionGate.MergePreview {
        let tests = tests(for: taskID)
        let reviews = reviews(for: taskID)
        return TaskCompletionGate.MergePreview(
            branch: branch,
            changedFiles: changedFiles,
            conflictedFiles: conflictedFiles,
            tests: tests,
            reviews: reviews,
            blockers: TaskCompletionGate.mayMerge(
                tests: tests,
                reviews: reviews,
                conflictedFiles: conflictedFiles,
                uncommittedChanges: uncommittedChanges,
                userApproved: userApproved,
                settings: settings
            )
        )
    }

    // MARK: - Persistence

    private func trim<T>(_ values: inout [T]) {
        if values.count > limitPerKind {
            values.removeFirst(values.count - limitPerKind)
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return }
        AtomicFile.write(data, to: fileURL)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Document.self, from: data),
              decoded.version <= Document.currentVersion else { return }
        document = decoded
    }

    /// Append-only: the audit is not rewritten when the document is.
    private func appendAudit(_ merge: TaskMergeRecord) {
        try? FileManager.default.createDirectory(
            at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = (merge.auditLine + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: auditURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: auditURL)
        }
    }

    /// The audit file, for the UI and for tests.
    var auditFileURL: URL { auditURL }
}
