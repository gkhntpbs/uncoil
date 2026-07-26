import SwiftUI

/// What kind of attention a single Attention Center row asks for.
enum AttentionKind: String, CaseIterable, Identifiable, Codable {
    case permission
    case input
    case testFailure
    case mergeConflict
    case authentication
    case runtime
    case completed
    // MARK: Task rows
    case taskAssigned
    case reviewRequested
    case changesRequested
    case taskBlocked
    case taskFailed
    case taskCompleted
    case mergeReady
    /// A task's session lost its link to a task and the user has to say which.
    case relinkNeeded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .permission: String(localized: "Waiting for permission")
        case .input: String(localized: "Waiting for a reply")
        case .testFailure: String(localized: "Test failed")
        case .mergeConflict: String(localized: "Merge conflict")
        case .authentication: String(localized: "Login required")
        case .runtime: String(localized: "Runtime problem")
        case .completed: String(localized: "Done")
        case .taskAssigned: String(localized: "An agent was assigned to the task")
        case .reviewRequested: String(localized: "Review requested")
        case .changesRequested: String(localized: "Changes requested")
        case .taskBlocked: String(localized: "Task blocked")
        case .taskFailed: String(localized: "Task failed")
        case .taskCompleted: String(localized: "Task done")
        case .mergeReady: String(localized: "Ready to merge")
        case .relinkNeeded: String(localized: "Task link lost")
        }
    }

    var iconName: String {
        switch self {
        case .permission: "shield-lock"
        case .input: "message-question"
        case .testFailure: "flask-off"
        case .mergeConflict: "git-merge"
        case .authentication: "user-exclamation"
        case .runtime: "plug-off"
        case .completed: "circle-check"
        case .taskAssigned: "user-check"
        case .reviewRequested: "eye-search"
        case .changesRequested: "message-report"
        case .taskBlocked: "hand-stop"
        case .taskFailed: "alert-triangle"
        case .taskCompleted: "checkbox"
        case .mergeReady: "git-pull-request"
        case .relinkNeeded: "unlink"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .permission: Theme.claude
        case .input: Theme.warn
        case .testFailure, .runtime, .taskFailed: Theme.danger
        case .mergeConflict: Theme.warn
        case .authentication: Theme.warn
        case .completed, .taskCompleted, .mergeReady: Theme.highlight
        case .taskAssigned: Theme.textDim
        case .reviewRequested, .changesRequested, .taskBlocked, .relinkNeeded: Theme.warn
        }
    }

    /// Higher sorts first in the panel and wins the menu-bar summary.
    var priority: Int {
        switch self {
        case .permission: 6
        case .runtime, .taskFailed: 5
        case .mergeConflict: 4
        case .testFailure: 4
        case .authentication: 3
        case .input: 3
        case .taskBlocked, .changesRequested, .reviewRequested, .relinkNeeded: 3
        case .mergeReady: 2
        case .completed, .taskCompleted, .taskAssigned: 1
        }
    }

    /// Whether this row is about a task rather than a session or the runtime.
    var isTaskRow: Bool {
        switch self {
        case .taskAssigned, .reviewRequested, .changesRequested, .taskBlocked,
             .taskFailed, .taskCompleted, .mergeReady, .relinkNeeded:
            true
        case .permission, .input, .testFailure, .mergeConflict, .authentication,
             .runtime, .completed:
            false
        }
    }

    /// Whether this row is a problem rather than a normal wait — what the
    /// menu-bar icon escalates on.
    var isProblem: Bool {
        switch self {
        case .runtime, .testFailure, .mergeConflict, .authentication,
             .taskFailed, .taskBlocked, .relinkNeeded:
            true
        case .permission, .input, .completed, .taskAssigned, .reviewRequested,
             .changesRequested, .taskCompleted, .mergeReady:
            false
        }
    }

    /// Which notification setting governs a banner for this row, if any.
    ///
    /// Permission and input rows return nil on purpose: the hook reducer already
    /// notifies about those the moment the status changes, and notifying again
    /// from here would double every banner.
    var notificationEvent: NotificationEvent? {
        switch self {
        case .authentication: .loginRequired
        case .taskCompleted: .taskCompleted
        case .mergeReady: .mergeReady
        case .runtime, .testFailure, .mergeConflict, .taskFailed, .taskBlocked, .relinkNeeded:
            .problem
        case .permission, .input, .completed, .taskAssigned, .reviewRequested, .changesRequested:
            nil
        }
    }
}

struct AttentionItem: Identifiable, Equatable {
    let id: String
    let kind: AttentionKind
    let title: String
    let detail: String?
    let projectID: UUID?
    let sessionID: UUID?
    let createdAt: Date
    var isRead = false

    /// What makes *this occurrence* of the row distinct from the next one with
    /// the same id. Read/resolved marks are kept against it, so a row the user
    /// cleared stays cleared across relaunches while a genuinely new event —
    /// another permission ask, a different set of conflicted files — comes back
    /// unread. Empty means "use `createdAt`", which is right for every row whose
    /// timestamp already moves with the event.
    var signature: String = ""

    /// Derived items mirror live state and disappear on their own; reported
    /// items (test results) stay until the user resolves them.
    var isDerived = true
}

/// Everything the pure engine needs to derive the current attention list.
struct AttentionSnapshot {
    var sessions: [SessionRecord] = []
    var statuses: [UUID: AgentSessionStatus] = [:]
    var details: [UUID: String] = [:]
    var projectNames: [UUID: String] = [:]
    var codexAuthentication: [UUID: CodexAuthenticationState] = [:]
    var runtimePhase: RuntimeClient.Phase = .idle
    /// projectID → unresolved conflict paths.
    var conflicts: [UUID: [String]] = [:]
    /// Task-side rows, derived by `TaskAttentionEngine`.
    var tasks = TaskAttentionSnapshot()
}

/// Derives attention rows from live app state. Pure and synchronous so the
/// whole surface is unit-testable without a running app.
enum AttentionEngine {
    static func permissionID(_ sessionID: UUID) -> String { "permission:\(sessionID.uuidString)" }
    static func inputID(_ sessionID: UUID) -> String { "input:\(sessionID.uuidString)" }
    static func completedID(_ sessionID: UUID) -> String { "completed:\(sessionID.uuidString)" }
    static func authenticationID(_ sessionID: UUID) -> String { "auth:\(sessionID.uuidString)" }
    static func conflictID(_ projectID: UUID) -> String { "conflict:\(projectID.uuidString)" }
    static let runtimeID = "runtime"

    static func items(_ snapshot: AttentionSnapshot, now: Date = .now) -> [AttentionItem] {
        var items: [AttentionItem] = []

        for session in snapshot.sessions {
            let project = snapshot.projectNames[session.projectID]
            let where_ = project.map { "\($0) › \(session.displayTitle)" } ?? session.displayTitle
            let detail = snapshot.details[session.id]

            switch snapshot.statuses[session.id] {
            case .waitingForPermission:
                items.append(AttentionItem(
                    id: permissionID(session.id), kind: .permission, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .waitingForInput:
                items.append(AttentionItem(
                    id: inputID(session.id), kind: .input, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .completed:
                items.append(AttentionItem(
                    id: completedID(session.id), kind: .completed, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            default:
                break
            }

            // Provider/MCP authentication: the agent cannot work until the
            // user finishes a login flow the CLI owns.
            switch snapshot.codexAuthentication[session.id] {
            case .required:
                items.append(AttentionItem(
                    id: authenticationID(session.id), kind: .authentication, title: where_,
                    detail: String(localized: "You need to sign in to your Codex account."),
                    projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .error(let message):
                items.append(AttentionItem(
                    id: authenticationID(session.id), kind: .authentication, title: where_,
                    detail: message, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .authenticated, .unknown, nil:
                break
            }
        }

        for (projectID, paths) in snapshot.conflicts where !paths.isEmpty {
            let name = snapshot.projectNames[projectID] ?? "Project"
            // Stamped `now` on every scan, so the files themselves — not the
            // clock — are what says whether this is the same conflict the user
            // already dealt with.
            items.append(AttentionItem(
                id: conflictID(projectID), kind: .mergeConflict, title: name,
                detail: conflictDetail(paths), projectID: projectID, sessionID: nil,
                createdAt: now, signature: paths.sorted().joined(separator: "|")
            ))
        }

        switch snapshot.runtimePhase {
        case .failed:
            items.append(AttentionItem(
                id: runtimeID, kind: .runtime, title: String(localized: "Runtime daemon"),
                detail: String(localized: "uncoil-runtimed is unreachable; sessions run on the in-app PTY."),
                projectID: nil, sessionID: nil, createdAt: now, signature: "failed"
            ))
        case .incompatible(let message):
            items.append(AttentionItem(
                id: runtimeID, kind: .runtime, title: String(localized: "Runtime mismatch"),
                detail: message, projectID: nil, sessionID: nil, createdAt: now,
                signature: "incompatible:\(message)"
            ))
        case .idle, .connecting, .ready:
            break
        }

        items.append(contentsOf: TaskAttentionEngine.items(snapshot.tasks, now: now))
        return items
    }

    static func conflictDetail(_ paths: [String]) -> String {
        let shown = paths.prefix(3).joined(separator: ", ")
        return paths.count > 3
            ? "Unresolved conflicts in \(paths.count) files: \(shown)…"
            : "Unresolved conflict: \(shown)"
    }

    /// Panel order: urgency first, then most recent.
    static func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted {
            $0.kind.priority != $1.kind.priority
                ? $0.kind.priority > $1.kind.priority
                : $0.createdAt > $1.createdAt
        }
    }
}

/// Observable Attention Center state: derived rows refreshed from live state,
/// plus reported rows (failing tests) that stick until resolved. Read and
/// resolved marks are keyed by item id, so a row that comes back after the
/// condition cleared is unread again.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var items: [AttentionItem] = []

    /// A mark records *which occurrence* was read or resolved, not merely that
    /// the id once was.
    ///
    /// Liveness alone cannot carry this across a relaunch. Rows are derived
    /// from session state, and at launch there is no state yet — pruning marks
    /// down to what is live would throw every one of them away moments before
    /// the same rows came back, which is exactly how cleared notifications
    /// reappeared after a restart. Matching occurrence signatures instead keeps
    /// a handled row handled while still letting the next occurrence of it
    /// arrive unread.
    struct Mark: Codable {
        var signature: String
        var at: Date
    }

    private var readMarks: [String: Mark] = [:]
    private var resolvedMarks: [String: Mark] = [:]
    private var reported: [AttentionItem] = []
    /// Row ids this process has actually watched go live. Only those may have
    /// their marks dropped when the row disappears — which is the old rule that
    /// makes a cleared condition come back unread when it recurs. Ids that were
    /// never live here are left alone, so a relaunch (where nothing is live yet)
    /// does not throw away every mark the user made before quitting.
    private var seenLive: Set<String> = []
    private let defaults: UserDefaults
    private let readKey = "attention.readMarks"
    private let resolvedKey = "attention.resolvedMarks"
    /// Marks older than this are dropped, so the store cannot grow forever.
    private let markLifetime: TimeInterval = 30 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        readMarks = Self.loadMarks(defaults, key: readKey)
        resolvedMarks = Self.loadMarks(defaults, key: resolvedKey)
    }

    private static func loadMarks(_ defaults: UserDefaults, key: String) -> [String: Mark] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Mark].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistMarks(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-markLifetime)
        readMarks = readMarks.filter { $0.value.at > cutoff }
        resolvedMarks = resolvedMarks.filter { $0.value.at > cutoff }
        if let data = try? JSONEncoder().encode(readMarks) {
            defaults.set(data, forKey: readKey)
        }
        if let data = try? JSONEncoder().encode(resolvedMarks) {
            defaults.set(data, forKey: resolvedKey)
        }
    }

    /// Whether `item` has already been handled: a mark counts only for the very
    /// occurrence it was made against.
    private func isMarked(_ marks: [String: Mark], _ item: AttentionItem) -> Bool {
        marks[item.id]?.signature == Self.signature(of: item)
    }

    private static func signature(of item: AttentionItem) -> String {
        item.signature.isEmpty
            ? String(Int(item.createdAt.timeIntervalSince1970))
            : item.signature
    }

    private func mark(_ item: AttentionItem, now: Date = .now) -> Mark {
        Mark(signature: Self.signature(of: item), at: now)
    }

    var unreadCount: Int { items.filter { !$0.isRead }.count }

    func count(of kind: AttentionKind) -> Int {
        items.filter { $0.kind == kind }.count
    }

    /// Called with rows that have just appeared, so they can be notified about.
    /// Never fires for the first refresh of a launch — at that point everything
    /// is "new", and the user does not want a banner per pre-existing row.
    var onNewItems: (([AttentionItem]) -> Void)?
    private var hasRefreshedOnce = false

    /// Recomputes derived rows and merges them with reported ones.
    func refresh(_ snapshot: AttentionSnapshot, now: Date = .now) {
        let derived = AttentionEngine.items(snapshot, now: now)
        let previouslyLive = seenLive

        let liveIDs = Set(derived.map(\.id)).union(reported.map(\.id))
        let cleared = seenLive.subtracting(liveIDs)
        if !cleared.isEmpty {
            for id in cleared {
                readMarks.removeValue(forKey: id)
                resolvedMarks.removeValue(forKey: id)
            }
            persistMarks(now: now)
        }
        seenLive = liveIDs

        items = AttentionEngine.sorted(derived + reported)
            .filter { !isMarked(resolvedMarks, $0) }
            .map {
                var item = $0
                item.isRead = isMarked(readMarks, $0)
                return item
            }

        defer { hasRefreshedOnce = true }
        guard hasRefreshedOnce, let onNewItems else { return }
        let fresh = items.filter { !previouslyLive.contains($0.id) && !$0.isRead }
        if !fresh.isEmpty { onNewItems(fresh) }
    }

    /// Records an item that no live state can re-derive (a failing test run).
    func report(
        kind: AttentionKind,
        title: String,
        detail: String?,
        projectID: UUID?,
        sessionID: UUID?,
        id: String? = nil,
        now: Date = .now
    ) {
        let itemID = id ?? "\(kind.rawValue):\(sessionID?.uuidString ?? "-"):\(title)"
        let item = AttentionItem(
            id: itemID, kind: kind, title: title, detail: detail,
            projectID: projectID, sessionID: sessionID, createdAt: now,
            isDerived: false
        )
        reported.removeAll { $0.id == itemID }
        reported.append(item)
        // Re-reporting is a fresh event: clear both marks.
        readMarks.removeValue(forKey: itemID)
        resolvedMarks.removeValue(forKey: itemID)
        persistMarks(now: now)
        if reported.count > 100 { reported.removeFirst(reported.count - 100) }
        items = AttentionEngine.sorted(items.filter { $0.id != itemID } + [item])
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        readMarks[id] = mark(items[index])
        items[index].isRead = true
        persistMarks()
    }

    func markAllRead() {
        for item in items { readMarks[item.id] = mark(item) }
        for index in items.indices { items[index].isRead = true }
        persistMarks()
    }

    /// Marks a row handled: it leaves the list until the condition recurs.
    func resolve(_ id: String) {
        if let item = items.first(where: { $0.id == id }) {
            resolvedMarks[id] = mark(item)
        }
        reported.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
        persistMarks()
    }

    func resolveAll() {
        for item in items { resolvedMarks[item.id] = mark(item) }
        reported.removeAll()
        items.removeAll()
        persistMarks()
    }
}

/// Bridges the live stores to `AttentionStore`: builds snapshots on demand and
/// keeps a cached merge-conflict scan (git is too slow to run inline).
@MainActor
final class AttentionRefresher {
    static let shared = AttentionRefresher()

    private var conflicts: [UUID: [String]] = [:]
    private var scanning = false
    private var scanningTasks = false
    private var taskSnapshot = TaskAttentionSnapshot()

    func refresh(projectStore: ProjectStore, sessionStore: SessionStore) {
        AttentionStore.shared.refresh(
            snapshot(projectStore: projectStore, sessionStore: sessionStore)
        )
    }

    func snapshot(projectStore: ProjectStore, sessionStore: SessionStore) -> AttentionSnapshot {
        var snapshot = AttentionSnapshot()
        snapshot.sessions = projectStore.sessions
        snapshot.statuses = sessionStore.statuses
        snapshot.details = sessionStore.details
        snapshot.codexAuthentication = sessionStore.codexAuthentication
        snapshot.projectNames = Dictionary(
            projectStore.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        snapshot.runtimePhase = RuntimeClient.shared.phase
        snapshot.conflicts = conflicts
        snapshot.tasks = taskSnapshot
        snapshot.tasks.projectNames = snapshot.projectNames
        return snapshot
    }

    /// Rescans task state for every project: which tasks have agents on them,
    /// what the reviews said, and which task sources are in conflict.
    ///
    /// Only tasks Uncoil actually tracks are read. A `TODO.md` with three hundred
    /// ticked boxes must not produce three hundred "task completed" rows, so the
    /// scan starts from the assignments and parses only the files they name.
    func scanTasks(projectStore: ProjectStore) async {
        guard !scanningTasks else { return }
        scanningTasks = true
        defer { scanningTasks = false }

        var merged = TaskAttentionSnapshot()
        for project in projectStore.projects {
            let metadata = ProjectTaskMetadataStore(projectID: project.id)
            let assignments = metadata.assignmentsByTask
            let orchestrator = OrchestratorStore(projectID: project.id)
            merged.queuedTaskCount += orchestrator.pending.count
            guard !assignments.isEmpty else { continue }

            let results = TaskResultStore(projectID: project.id)
            let paths = Set(assignments.values.flatMap { $0.map(\.sourcePath) })
            let documents = await Task.detached(priority: .utility) {
                paths.compactMap { path -> TaskDocument? in
                    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
                        return nil
                    }
                    return TodoParser.parse(raw, path: path)
                }
            }.value

            let statuses = await Task.detached(priority: .utility) { [paths] in
                TaskGitStatusReader.statuses(
                    repoRoot: project.rootPath,
                    contentsByPath: Dictionary(
                        uniqueKeysWithValues: paths.compactMap { path in
                            (try? String(contentsOfFile: path, encoding: .utf8))
                                .map { (path, $0) }
                        }
                    )
                )
            }.value
            let conflicted = statuses.filter { !$0.value.isEditable }.keys.sorted()
            if !conflicted.isEmpty {
                merged.conflictedSources[project.id] = conflicted
            }

            for (taskID, taskAssignments) in assignments {
                guard let document = documents.first(where: { $0.task(id: taskID) != nil }),
                      let task = document.task(id: taskID) else {
                    // The task is gone from the file; the relink row is what the
                    // user needs, and that comes from the assignment itself.
                    merged.tasks.append(TaskAttentionInput(
                        taskID: taskID,
                        taskText: taskAssignments.first?.fingerprint?.normalizedText ?? taskID,
                        projectID: project.id, projectName: project.name,
                        sourcePath: taskAssignments.first?.sourcePath ?? "",
                        assignments: taskAssignments.map {
                            var copy = $0
                            copy.needsRelinking = true
                            return copy
                        },
                        updatedAt: taskAssignments.map(\.updatedAt).max() ?? .distantPast
                    ))
                    continue
                }
                merged.tasks.append(TaskAttentionInput(
                    taskID: taskID,
                    taskText: task.text,
                    projectID: project.id,
                    projectName: project.name,
                    sourcePath: task.sourcePath,
                    assignments: taskAssignments,
                    latestReview: results.latestReview(for: taskID)?.verdict,
                    // Asked only for work that has a worktree: without one there
                    // is nothing to merge, and reporting readiness would be noise.
                    mergeBlockers: taskAssignments.compactMap(\.worktreePath).first.map { worktree in
                        let snapshot = GitService.snapshot(repoPath: worktree)
                        return results.mergePreview(
                            taskID: taskID,
                            branch: snapshot.branch,
                            changedFiles: snapshot.changedFiles.map(\.path),
                            conflictedFiles: GitService.conflictedFiles(repoPath: worktree),
                            uncommittedChanges: snapshot.changedFiles.count,
                            userApproved: false,
                            settings: orchestrator.settings
                        ).hardBlockers
                    },
                    isDone: task.isDone,
                    updatedAt: taskAssignments.map(\.updatedAt).max() ?? .distantPast
                ))
            }
        }
        taskSnapshot = merged
    }

    /// Rescans every project (and its session worktrees) for unresolved
    /// conflicts off the main thread, then refreshes the store.
    func scanConflicts(projectStore: ProjectStore, sessionStore: SessionStore) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        var roots: [UUID: Set<String>] = [:]
        for project in projectStore.projects {
            roots[project.id, default: []].insert(project.rootPath)
        }
        for session in projectStore.sessions {
            guard let worktree = session.worktreePath else { continue }
            roots[session.projectID, default: []].insert(worktree)
        }

        let scanned = await Task.detached(priority: .utility) {
            roots.mapValues { paths in
                Array(Set(paths.flatMap { path in
                    GitService.conflictedFiles(repoPath: path)
                })).sorted()
            }
        }.value

        conflicts = scanned.filter { !$0.value.isEmpty }
        refresh(projectStore: projectStore, sessionStore: sessionStore)
    }
}
