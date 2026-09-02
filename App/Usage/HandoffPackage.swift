import Foundation

/// Everything a fresh agent needs to carry on where another one stopped.
///
/// The test this type is written against is not "does it summarise the
/// conversation" — it is whether an agent given only this can continue without
/// asking the user what it was doing. A summary fails that test: it keeps what
/// was said and loses what was decided.
///
/// It has two halves, and knowing which is which is the point.
///
/// **What Uncoil knows** — the project, the worktree, the branch, the files
/// that changed, the task, the last test result. Always available, never wrong,
/// and available even when the agent that was working can no longer answer.
///
/// **What only the agent knows** — the objective, what it already tried, the
/// decisions that closed off other options, what it would do next. This has to
/// be asked for, and asked for early: an agent that has run out of quota cannot
/// write its own handover. That timing constraint is why the warning fires at a
/// threshold rather than at zero.
struct HandoffPackage: Codable, Equatable {
    // MARK: What Uncoil knows

    var projectName: String
    var projectPath: String
    /// Where the outgoing agent was actually working — a worktree, usually.
    var workingDirectory: String
    var worktreePath: String?
    var branch: String?
    /// Path and porcelain status code, as git reported them.
    var changedFiles: [ChangedFile] = []
    /// Truncated: a handoff is a briefing, not an archive.
    var diff: String?
    /// The task this session was attached to, if any.
    var task: TaskContext?
    /// What the tests last said, and when.
    var testResults: [TestResult] = []
    /// Long-running processes the session started, by name.
    var runningProcesses: [String] = []

    // MARK: What the outgoing agent said

    var objective: String?
    var workDone: [String] = []
    /// Decisions already taken — including the ones that closed off other
    /// options, which is what a conversation summary always loses.
    var decisions: [String] = []
    var openItems: [String] = []
    /// Dead ends: things already tried that did not work. Without these the
    /// next agent repeats them, which is the most expensive kind of restart.
    var knownProblems: [String] = []
    var suggestedNextStep: String?

    // MARK: Provenance

    var fromProvider: AgentProvider
    var fromAccountName: String?
    var fromSessionTitle: String
    var createdAt: Date
    /// Whether the outgoing agent answered at all. A package built without it
    /// is still worth handing over — it has the ground truth — but the next
    /// agent must not be told a story nobody told.
    var agentResponded: Bool = false
    /// Why the agent's half is missing, when it is.
    var agentFailureReason: String?

    struct ChangedFile: Codable, Equatable {
        var status: String
        var path: String
    }

    struct TaskContext: Codable, Equatable {
        var text: String
        var sourcePath: String
        var headingPath: [String]
    }

    struct TestResult: Codable, Equatable {
        var suite: String
        var passed: Bool
        var detail: String?
    }

    /// True when there is enough here to be worth handing on.
    ///
    /// The ground truth alone qualifies. An agent that could not answer still
    /// leaves a branch, a diff and a task, and a next agent given those is far
    /// better off than one given nothing — as long as it is not told that a
    /// silent agent said something.
    var isUsable: Bool {
        !changedFiles.isEmpty || task != nil || objective != nil || branch != nil
    }
}
