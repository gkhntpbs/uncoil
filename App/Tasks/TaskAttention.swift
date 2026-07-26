import Foundation

/// One task as the Attention Center sees it.
struct TaskAttentionInput: Equatable {
    var taskID: String
    var taskText: String
    var projectID: UUID
    var projectName: String
    var sourcePath: String
    var assignments: [TaskSessionAssignment] = []
    /// Latest review verdict, if the task was reviewed at all.
    var latestReview: TaskReviewResult.Verdict?
    /// What still stands between this task and a merge. Empty means ready — and
    /// `nil` means the question was never asked, which is not the same thing.
    var mergeBlockers: [TaskCompletionGate.Blocker]?
    var isDone = false
    var updatedAt: Date = .distantPast
}

/// Task-side input for the Attention Center.
struct TaskAttentionSnapshot: Equatable {
    var tasks: [TaskAttentionInput] = []
    /// Task source files with an unresolved conflict, per project.
    var conflictedSources: [UUID: [String]] = [:]
    /// Project names for the conflict rows, which have no task to borrow from.
    var projectNames: [UUID: String] = [:]
    /// Tasks the orchestrator is holding in the queue. Nothing is waiting on the
    /// user, so this feeds the menu-bar count only, not an attention row.
    var queuedTaskCount = 0
}

/// Derives Attention Center rows from task state. Pure, so every rule here is
/// unit-testable without an app, a session or a file.
enum TaskAttentionEngine {
    static func id(_ kind: AttentionKind, taskID: String) -> String {
        "task-\(kind.rawValue):\(taskID)"
    }

    static func sourceConflictID(_ path: String) -> String { "todo-conflict:\(path)" }

    static func items(_ snapshot: TaskAttentionSnapshot, now: Date = .now) -> [AttentionItem] {
        var items: [AttentionItem] = []

        for task in snapshot.tasks {
            let title = String(localized: "\(task.projectName) › \(task.taskText)")

            // A lost link is reported per task, not per assignment: the question
            // the user answers is "which task was this?", asked once.
            if task.assignments.contains(where: \.needsRelinking) {
                items.append(item(
                    .relinkNeeded, task: task, title: title,
                    detail: String(localized: "The task's wording changed; which task the session belongs to must be confirmed."),
                    now: now
                ))
            }

            for assignment in task.assignments {
                let who = "\(title) — \(assignment.role.label)"
                switch assignment.state {
                case .assigned, .agentStarting, .running:
                    items.append(item(
                        .taskAssigned, task: task, title: who,
                        detail: assignment.state.label,
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .waitingForPermission:
                    items.append(item(
                        .permission, task: task, title: who,
                        detail: String(localized: "Waiting for permission for the task."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .waitingForUser:
                    items.append(item(
                        .input, task: task, title: who,
                        detail: String(localized: "Waiting for your answer on the task."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .testsFailing:
                    items.append(item(
                        .testFailure, task: task, title: who,
                        detail: String(localized: "The task's tests are failing."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .reviewRequested:
                    items.append(item(
                        .reviewRequested, task: task, title: who,
                        detail: String(localized: "Awaiting review."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .blocked:
                    items.append(item(
                        .taskBlocked, task: task, title: who,
                        detail: String(localized: "The task is blocked."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .failed:
                    items.append(item(
                        .taskFailed, task: task, title: who,
                        detail: String(localized: "The task run failed."),
                        sessionID: assignment.sessionID,
                        idSuffix: assignment.sessionID.uuidString, now: now,
                        createdAt: assignment.updatedAt
                    ))
                case .unassigned, .queued, .completed:
                    break
                }
            }

            if task.latestReview == .changesRequested {
                items.append(item(
                    .changesRequested, task: task, title: title,
                    detail: String(localized: "The review requested changes."), now: now
                ))
            }

            if task.isDone {
                items.append(item(
                    .taskCompleted, task: task, title: title,
                    detail: String(localized: "The task was marked as done."), now: now
                ))
            }

            // Merge readiness is only interesting once someone did the work: an
            // untouched task has no blockers either, and reporting that as
            // "ready to merge" would be noise.
            if let blockers = task.mergeBlockers, blockers.isEmpty, !task.assignments.isEmpty {
                items.append(item(
                    .mergeReady, task: task, title: title,
                    detail: String(localized: "Tests, review and worktree are ready; waiting for your word."),
                    now: now
                ))
            }
        }

        for (projectID, paths) in snapshot.conflictedSources where !paths.isEmpty {
            let name = snapshot.projectNames[projectID] ?? "Project"
            for path in paths {
                items.append(AttentionItem(
                    id: sourceConflictID(path),
                    kind: .mergeConflict,
                    title: String(localized: "\(name) › \(URL(fileURLWithPath: path).lastPathComponent)"),
                    detail: String(localized: "The task's source contains a conflict; editing is off."),
                    projectID: projectID, sessionID: nil, createdAt: now,
                    // Stamped `now` per scan; the path is what makes this the
                    // same conflict rather than a new one.
                    signature: path
                ))
            }
        }

        return items
    }

    private static func item(
        _ kind: AttentionKind,
        task: TaskAttentionInput,
        title: String,
        detail: String?,
        sessionID: UUID? = nil,
        idSuffix: String? = nil,
        now: Date,
        createdAt: Date? = nil
    ) -> AttentionItem {
        AttentionItem(
            id: idSuffix.map { "\(id(kind, taskID: task.taskID)):\($0)" }
                ?? id(kind, taskID: task.taskID),
            kind: kind,
            title: title,
            detail: detail,
            projectID: task.projectID,
            sessionID: sessionID,
            createdAt: createdAt ?? (task.updatedAt == .distantPast ? now : task.updatedAt)
        )
    }
}
