import Foundation

/// Worktree policy for tasks.
///
/// Two rules shape it: a read-only role never needs its own checkout, and an
/// unfinished worktree is never removed automatically — a half-done change is
/// the user's to keep or discard.
struct TaskWorktreePolicy: Equatable, Codable {
    /// Never start two tasks that look like they touch the same files.
    var serialisesConflictingTasks = true
    var maxWorktrees = 3
    /// What may be cleaned up, and when.
    enum Cleanup: String, Equatable, Codable, CaseIterable, Identifiable {
        /// Keep everything; the user removes worktrees by hand.
        case manual
        /// Remove only worktrees whose task completed and whose tree is clean.
        case afterCompletedAndClean
        /// Remove any clean worktree, completed or not.
        case anyClean

        var id: String { rawValue }

        var label: String {
            switch self {
            case .manual: String(localized: "By hand")
            case .afterCompletedAndClean: String(localized: "Finished and clean")
            case .anyClean: String(localized: "All clean")
            }
        }
    }

    var cleanup: Cleanup = .manual

    static let `default` = TaskWorktreePolicy()

    /// Whether this role's work warrants a worktree at all.
    func needsWorktree(role: TaskAgentRole) -> Bool {
        // A reviewer or observer reads; giving them a checkout costs disk and
        // buys nothing.
        role.writes
    }

    /// Whether a worktree may be removed. An unfinished task's worktree, or one
    /// with uncommitted changes, never is.
    func mayRemove(
        worktreeIsClean: Bool,
        taskCompleted: Bool
    ) -> Bool {
        switch cleanup {
        case .manual: false
        case .afterCompletedAndClean: worktreeIsClean && taskCompleted
        case .anyClean: worktreeIsClean
        }
    }

    /// Slug for a task's worktree: derived from the task, bounded, filesystem
    /// safe, and falling back to the fingerprint when the text yields nothing.
    static func worktreeName(for task: ProjectTask) -> String {
        let slug = TaskPromptBuilder.worktreeName(for: task)
        let cleaned = slug.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        // "task" is the generic fallback for text that yields no words; leaving
        // it bare would make every unnameable task want the same worktree, so
        // the fingerprint disambiguates.
        guard cleaned.count >= 3, cleaned != "task" else {
            return "task-\(task.fingerprint.strongKey.prefix(8))"
        }
        return String(cleaned.prefix(40))
    }
}

/// A test run attached to a task.
struct TaskTestResult: Identifiable, Equatable, Codable {
    let id: UUID
    var taskID: String
    var sessionID: UUID?
    var command: String
    var passed: Bool
    var summary: String
    /// Artifact names registered for this run, so output stays with the session.
    var artifacts: [String]
    var finishedAt: Date

    init(
        id: UUID = UUID(),
        taskID: String,
        sessionID: UUID? = nil,
        command: String,
        passed: Bool,
        summary: String,
        artifacts: [String] = [],
        finishedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.command = command
        self.passed = passed
        self.summary = summary
        self.artifacts = artifacts
        self.finishedAt = finishedAt
    }
}

/// A review verdict attached to a task.
struct TaskReviewResult: Identifiable, Equatable, Codable {
    enum Verdict: String, Equatable, Codable, CaseIterable {
        case approved
        case changesRequested
        case commented

        var label: String {
            switch self {
            case .approved: String(localized: "Approved")
            case .changesRequested: String(localized: "Changes requested")
            case .commented: String(localized: "Comment left")
            }
        }
    }

    let id: UUID
    var taskID: String
    var reviewerSessionID: UUID?
    var verdict: Verdict
    var findings: [String]
    var finishedAt: Date

    init(
        id: UUID = UUID(),
        taskID: String,
        reviewerSessionID: UUID? = nil,
        verdict: Verdict,
        findings: [String] = [],
        finishedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.reviewerSessionID = reviewerSessionID
        self.verdict = verdict
        self.findings = findings
        self.finishedAt = finishedAt
    }

    /// The message handed back to the implementation session.
    func feedbackPrompt(taskText: String, language: PromptLanguage = .english) -> String {
        var lines = ["Review result: \(verdict.label) — \(taskText)"]
        if !findings.isEmpty {
            lines.append("")
            lines.append(contentsOf: findings.map { "- \($0)" })
        }
        if verdict == .changesRequested {
            lines.append("")
            lines.append("Address these findings and report back. Do not tick the checkbox yet.")
        }
        if let directive = language.directive {
            lines.append("")
            lines.append(directive)
        }
        return lines.joined(separator: "\n")
    }
}

/// Whether a task may be completed, and whether it may be merged.
///
/// Both gates are conservative on purpose: a failing test must not tick a
/// checkbox, and nothing merges without a passing review and the user's word.
enum TaskCompletionGate {
    enum Blocker: Equatable {
        case testsFailing(String)
        case testsMissing
        case reviewMissing
        case changesRequested
        case mergeConflict([String])
        case uncommittedChanges(Int)
        case approvalRequired

        var message: String {
            switch self {
            case .testsFailing(let summary): "Tests failing: \(summary)"
            case .testsMissing: "No test result."
            case .reviewMissing: "No review result."
            case .changesRequested: "The review requested changes."
            case .mergeConflict(let files):
                "Merge conflict: \(files.prefix(3).joined(separator: ", "))"
            case .uncommittedChanges(let count):
                "\(count) uncommitted changes."
            case .approvalRequired: "Your approval is required."
            }
        }
    }

    /// May the checkbox be ticked? Tests decide this; review does not, because a
    /// finished task with review comments is still finished work.
    static func mayComplete(
        tests: [TaskTestResult],
        requiresTests: Bool
    ) -> [Blocker] {
        var blockers: [Blocker] = []
        if let failure = tests.filter({ !$0.passed }).max(by: { $0.finishedAt < $1.finishedAt }),
           !tests.contains(where: { $0.passed && $0.finishedAt > failure.finishedAt }) {
            blockers.append(.testsFailing(failure.summary))
        }
        if requiresTests, tests.isEmpty {
            blockers.append(.testsMissing)
        }
        return blockers
    }

    /// May the work be merged? Everything has to line up, and the user still
    /// has to say yes.
    static func mayMerge(
        tests: [TaskTestResult],
        reviews: [TaskReviewResult],
        conflictedFiles: [String],
        uncommittedChanges: Int,
        userApproved: Bool,
        settings: OrchestratorSettings
    ) -> [Blocker] {
        var blockers = mayComplete(tests: tests, requiresTests: settings.automaticTests)
        let latestReview = reviews.max { $0.finishedAt < $1.finishedAt }
        if settings.automaticReview {
            switch latestReview?.verdict {
            case .none:
                blockers.append(.reviewMissing)
            case .changesRequested:
                blockers.append(.changesRequested)
            case .approved, .commented:
                break
            }
        } else if latestReview?.verdict == .changesRequested {
            blockers.append(.changesRequested)
        }
        if !conflictedFiles.isEmpty {
            blockers.append(.mergeConflict(conflictedFiles))
        }
        if uncommittedChanges > 0 {
            blockers.append(.uncommittedChanges(uncommittedChanges))
        }
        if settings.requiresApprovalForMerge, !userApproved {
            blockers.append(.approvalRequired)
        }
        return blockers
    }

    /// What the merge screen shows before asking.
    struct MergePreview: Equatable {
        var branch: String?
        var changedFiles: [String]
        var conflictedFiles: [String]
        var tests: [TaskTestResult]
        var reviews: [TaskReviewResult]
        var blockers: [Blocker]

        var isReady: Bool { blockers.isEmpty }
        /// Blockers other than "the user has not clicked yet".
        var hardBlockers: [Blocker] {
            blockers.filter { $0 != .approvalRequired }
        }
    }
}
