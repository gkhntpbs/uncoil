import Foundation

/// What the orchestrator is allowed to do, and how far it may go on its own.
///
/// The defaults are deliberately conservative: nothing merges and nothing
/// destructive happens without the user, because an orchestrator acts while
/// nobody is watching.
struct OrchestratorSettings: Equatable, Codable {
    var maxParallelAgents = 3
    var allowedProviders: [AgentProvider] = [.claude, .codex]
    /// Empty = whatever each provider defaults to.
    var allowedModels: [String] = []
    var maxWorktrees = 3
    var automaticReview = true
    var automaticTests = true
    /// Let an agent tick the checkbox when it finishes.
    var automaticTodoUpdate = true
    var automaticRetry = false
    var maxRetries = 1
    /// Never off: merging is the user's decision.
    var requiresApprovalForMerge = true
    var requiresApprovalForDestructive = true
    /// Token budget for one orchestrator run; nil = no ceiling enforced yet.
    /// Present so the accounting has somewhere to land before it exists.
    var tokenBudget: Int?
    var costBudgetUSD: Double?

    static let `default` = OrchestratorSettings()

    /// Clamped so a bad value cannot spawn an unbounded fleet.
    var effectiveParallelism: Int { max(1, min(maxParallelAgents, 8)) }

    func allows(provider: AgentProvider) -> Bool {
        allowedProviders.contains(provider)
    }

    func allows(model: String?) -> Bool {
        guard let model, !allowedModels.isEmpty else { return true }
        return allowedModels.contains(model)
    }
}

/// One dispatch the orchestrator intends to make.
struct PlannedDispatch: Identifiable, Equatable {
    var taskID: String
    var taskText: String
    var sourcePath: String
    var role: TaskAgentRole
    var provider: AgentProvider
    /// Wave index: everything in one wave may run at the same time.
    var wave: Int
    var needsWorktree: Bool
    /// Tasks this one waits for, and why.
    var dependsOn: [String]
    var serialReason: String?

    var id: String { "\(taskID)|\(role.rawValue)" }
}

/// A whole plan, previewable before anything starts.
struct OrchestratorPlan: Equatable {
    var projectID: UUID
    var dispatches: [PlannedDispatch]
    var createdAt: Date
    /// Tasks left out, with the reason — a plan that silently drops work is
    /// worse than one that says what it skipped.
    var skipped: [(taskID: String, reason: String)]

    var waves: [[PlannedDispatch]] {
        let grouped = Dictionary(grouping: dispatches, by: \.wave)
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }

    var isEmpty: Bool { dispatches.isEmpty }

    static func == (lhs: OrchestratorPlan, rhs: OrchestratorPlan) -> Bool {
        lhs.projectID == rhs.projectID
            && lhs.dispatches == rhs.dispatches
            && lhs.createdAt == rhs.createdAt
            && lhs.skipped.map(\.taskID) == rhs.skipped.map(\.taskID)
    }

    /// Human-readable preview.
    func summary() -> String {
        var lines: [String] = []
        for (index, wave) in waves.enumerated() {
            lines.append("Dalga \(index + 1) — \(wave.count) agent")
            for dispatch in wave {
                var line = "  · \(dispatch.role.label) (\(dispatch.provider.displayName)): \(dispatch.taskText)"
                if dispatch.needsWorktree { line += " [worktree]" }
                if let reason = dispatch.serialReason { line += " — \(reason)" }
                lines.append(line)
            }
        }
        for entry in skipped {
            lines.append("Skipped: \(entry.taskID) — \(entry.reason)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Plans and supervises work across sessions.
///
/// Planning is pure so a plan can be shown before anything runs: the same input
/// always produces the same waves, and every exclusion is explained.
enum TaskOrchestrator {
    struct Input {
        var projectID: UUID
        var tasks: [ProjectTask]
        var assignments: [String: [TaskSessionAssignment]]
        var claimStates: [String: TaskClaimState]
        var settings: OrchestratorSettings
        var now: Date
    }

    // MARK: - Planning

    static func plan(_ input: Input) -> OrchestratorPlan {
        var skipped: [(taskID: String, reason: String)] = []
        var candidates: [ProjectTask] = []

        for task in input.tasks {
            if task.isDone {
                continue
            }
            if let state = input.claimStates[task.id], !state.isTakeable {
                skipped.append((task.id, "\(state.label): on another agent"))
                continue
            }
            if (input.assignments[task.id] ?? []).contains(where: { $0.state.isActive }) {
                skipped.append((task.id, "already being worked on"))
                continue
            }
            if task.hasChildren {
                // A parent is finished by its children; dispatching it too would
                // put two agents on the same work.
                skipped.append((task.id, "it has subtasks; those are being planned"))
                continue
            }
            candidates.append(task)
        }

        let ordered = prioritise(candidates)
        let dependencies = dependencyMap(ordered, all: input.tasks)
        let conflicts = fileConflicts(ordered)

        var dispatches: [PlannedDispatch] = []
        var waveOf: [String: Int] = [:]
        var claimedPaths: [Int: Set<String>] = [:]

        for task in ordered {
            let blockers = dependencies[task.id] ?? []
            // A task starts one wave after everything it waits for.
            var wave = blockers.compactMap { waveOf[$0] }.max().map { $0 + 1 } ?? 0
            let paths = conflicts[task.id] ?? []
            var serialReason: String?

            // Two tasks touching the same file are not run side by side.
            while !paths.isEmpty, !(claimedPaths[wave] ?? []).isDisjoint(with: paths) {
                wave += 1
                serialReason = "touches the same files"
            }
            // Respect the parallelism ceiling by pushing overflow to later waves.
            while dispatches.filter({ $0.wave == wave }).count >= input.settings.effectiveParallelism {
                wave += 1
            }

            claimedPaths[wave, default: []].formUnion(paths)
            waveOf[task.id] = wave

            let provider = provider(for: task, settings: input.settings)
            dispatches.append(PlannedDispatch(
                taskID: task.id,
                taskText: task.text,
                sourcePath: task.sourcePath,
                role: .implementer,
                provider: provider,
                wave: wave,
                needsWorktree: !paths.isEmpty && dispatches.count < input.settings.maxWorktrees,
                dependsOn: blockers,
                serialReason: serialReason
            ))

            // Review and test follow the implementation, never beside it.
            if input.settings.automaticReview {
                dispatches.append(PlannedDispatch(
                    taskID: task.id, taskText: task.text, sourcePath: task.sourcePath,
                    role: .reviewer, provider: reviewProvider(input.settings, avoiding: provider),
                    wave: wave + 1, needsWorktree: false,
                    dependsOn: [task.id], serialReason: "uygulama bitince"
                ))
            }
            if input.settings.automaticTests {
                dispatches.append(PlannedDispatch(
                    taskID: task.id, taskText: task.text, sourcePath: task.sourcePath,
                    role: .tester, provider: provider,
                    wave: wave + 1, needsWorktree: false,
                    dependsOn: [task.id], serialReason: "uygulama bitince"
                ))
            }
        }

        return OrchestratorPlan(
            projectID: input.projectID,
            dispatches: dispatches,
            createdAt: input.now,
            skipped: skipped
        )
    }

    /// File order, then heading order: a plan should follow the file the user
    /// wrote rather than invent its own priority.
    static func prioritise(_ tasks: [ProjectTask]) -> [ProjectTask] {
        tasks.sorted {
            $0.sourcePath != $1.sourcePath
                ? $0.sourcePath < $1.sourcePath
                : $0.blockRange.startByte < $1.blockRange.startByte
        }
    }

    /// Which tasks wait for which. Two signals: a task that names another
    /// task's wording, and an explicit "before/after" phrase.
    static func dependencyMap(
        _ tasks: [ProjectTask],
        all: [ProjectTask]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let normalised = tasks.map { (task: $0, text: TaskFingerprint.normalize($0.text)) }
        for entry in normalised {
            let body = TaskFingerprint.normalize(entry.task.rawBlock)
            let mentionsOrder = ["once", "sonra", "after", "before", "depends", "bagli"]
                .contains { body.contains($0) }
            var blockers: [String] = []
            for other in normalised where other.task.id != entry.task.id {
                guard other.text.split(separator: " ").count >= 2 else { continue }
                // Only a task that appears earlier can be a blocker; otherwise a
                // pair naming each other would deadlock the plan.
                guard other.task.blockRange.startByte < entry.task.blockRange.startByte else {
                    continue
                }
                if mentionsOrder, body.contains(other.text) {
                    blockers.append(other.task.id)
                }
            }
            if !blockers.isEmpty { result[entry.task.id] = blockers }
        }
        return result
    }

    /// Paths a task looks likely to touch, from path-like tokens in its block.
    /// A heuristic, and treated as one: it only ever makes the plan more
    /// serial, never less.
    static func fileConflicts(_ tasks: [ProjectTask]) -> [String: Set<String>] {
        var paths: [String: Set<String>] = [:]
        for task in tasks {
            paths[task.id] = mentionedPaths(in: task.rawBlock)
        }
        // Keep only paths that more than one task mentions.
        var counts: [String: Int] = [:]
        for set in paths.values {
            for path in set { counts[path, default: 0] += 1 }
        }
        let shared = Set(counts.filter { $0.value > 1 }.keys)
        return paths.mapValues { $0.intersection(shared) }
    }

    static func mentionedPaths(in text: String) -> Set<String> {
        let tokens = text.split(whereSeparator: { " \t\n(),:;\"'`".contains($0) })
        return Set(
            tokens
                .map(String.init)
                .filter { token in
                    // Something with a slash and an extension, or a known source
                    // file name — not prose that happens to contain a dot.
                    guard token.contains("/") || token.contains(".") else { return false }
                    guard let ext = token.split(separator: ".").last, ext.count <= 5 else {
                        return false
                    }
                    return token.count > 4 && !token.hasSuffix(".")
                }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`.,")) }
                .filter { !$0.isEmpty }
        )
    }

    static func provider(
        for task: ProjectTask,
        settings: OrchestratorSettings
    ) -> AgentProvider {
        settings.allowedProviders.first ?? .claude
    }

    /// A reviewer on a different provider when one is available: a second pair
    /// of eyes is worth more when it is not the same model.
    static func reviewProvider(
        _ settings: OrchestratorSettings,
        avoiding provider: AgentProvider
    ) -> AgentProvider {
        settings.allowedProviders.first { $0 != provider } ?? provider
    }

    // MARK: - Recovery

    enum RecoveryAction: Equatable {
        case markFailed(taskID: String, reason: String)
        case releaseClaim(taskID: String, reason: String)
        case requeue(taskID: String)
        case showDiffBeforeHandover(taskID: String, worktreePath: String)
        case reportToAttention(taskID: String, detail: String)
    }

    /// What to do about work that went wrong. Nothing here deletes a worktree or
    /// discards a diff: a partly-finished change is evidence, and the next agent
    /// (or the user) should see it before anything is handed over.
    static func recover(
        assignments: [TaskSessionAssignment],
        leases: [String: TaskClaimLease],
        lastHeartbeats: [String: Date],
        settings: OrchestratorSettings,
        keeper: TaskLeaseKeeper = TaskLeaseKeeper(),
        retriesSoFar: [String: Int] = [:],
        now: Date = .now
    ) -> [RecoveryAction] {
        var actions: [RecoveryAction] = []
        for assignment in assignments {
            switch assignment.state {
            case .failed, .testsFailing:
                actions.append(.markFailed(
                    taskID: assignment.taskID,
                    reason: assignment.state.label
                ))
                actions.append(.reportToAttention(
                    taskID: assignment.taskID,
                    detail: String(localized: "\(assignment.role.label): \(assignment.state.label)")
                ))
                if let worktree = assignment.worktreePath {
                    actions.append(.showDiffBeforeHandover(
                        taskID: assignment.taskID, worktreePath: worktree
                    ))
                }
                if settings.automaticRetry,
                   (retriesSoFar[assignment.taskID] ?? 0) < settings.maxRetries {
                    actions.append(.requeue(taskID: assignment.taskID))
                }
            case .assigned, .agentStarting, .running:
                // A live-looking assignment whose lease went quiet is not live.
                if let lease = leases[assignment.taskID],
                   keeper.isStale(
                    lease,
                    lastHeartbeat: lastHeartbeats[assignment.taskID] ?? lease.acquiredAt,
                    now: now
                   ) {
                    actions.append(.releaseClaim(
                        taskID: assignment.taskID, reason: String(localized: "the heartbeat disappeared")
                    ))
                    actions.append(.markFailed(
                        taskID: assignment.taskID, reason: String(localized: "the agent is not responding")
                    ))
                }
            case .unassigned, .queued, .waitingForPermission, .waitingForUser,
                 .reviewRequested, .blocked, .completed:
                break
            }
        }
        return actions
    }
}

/// The orchestrator's plan and settings, persisted so a restart resumes rather
/// than starts over — and so a child's result is not lost when the parent
/// session disappears.
@MainActor
final class OrchestratorStore: ObservableObject {
    struct Document: Codable, Equatable {
        static let currentVersion = 1
        var version = Document.currentVersion
        var settings = OrchestratorSettings.default
        /// The active plan, flattened for storage.
        var dispatches: [StoredDispatch] = []
        var planCreatedAt: Date?
        /// Results children reported, keyed by task id, kept independently of
        /// the parent session.
        var results: [String: String] = [:]
        var retries: [String: Int] = [:]
    }

    struct StoredDispatch: Codable, Equatable {
        var taskID: String
        var taskText: String
        var sourcePath: String
        var role: TaskAgentRole
        var provider: AgentProvider
        var wave: Int
        var needsWorktree: Bool
        var dependsOn: [String]
        var dispatched: Bool
    }

    @Published private(set) var document = Document()

    private let fileURL: URL

    init(projectID: UUID, dataDirectory: URL? = nil) {
        fileURL = (dataDirectory ?? ProjectStore.defaultDirectory())
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("orchestrator.json")
        load()
    }

    var settings: OrchestratorSettings { document.settings }

    func update(settings: OrchestratorSettings) {
        document.settings = settings
        save()
    }

    func store(_ plan: OrchestratorPlan) {
        document.dispatches = plan.dispatches.map {
            StoredDispatch(
                taskID: $0.taskID, taskText: $0.taskText, sourcePath: $0.sourcePath,
                role: $0.role, provider: $0.provider, wave: $0.wave,
                needsWorktree: $0.needsWorktree, dependsOn: $0.dependsOn,
                dispatched: false
            )
        }
        document.planCreatedAt = plan.createdAt
        save()
    }

    /// Dispatches still to run, in wave order — what a restart picks up.
    var pending: [StoredDispatch] {
        document.dispatches
            .filter { !$0.dispatched }
            .sorted { $0.wave < $1.wave }
    }

    func markDispatched(taskID: String, role: TaskAgentRole) {
        guard let index = document.dispatches.firstIndex(where: {
            $0.taskID == taskID && $0.role == role
        }) else { return }
        document.dispatches[index].dispatched = true
        save()
    }

    /// A child's result, stored where the parent's death cannot take it.
    func record(result: String, taskID: String) {
        document.results[taskID] = result
        save()
    }

    func result(for taskID: String) -> String? { document.results[taskID] }

    func noteRetry(taskID: String) {
        document.retries[taskID, default: 0] += 1
        save()
    }

    func retries(for taskID: String) -> Int { document.retries[taskID] ?? 0 }

    /// Stops the orchestrator: every dispatch that has not started is dropped,
    /// so nothing new begins. Agents already running are left alone — ending
    /// one mid-edit is the user's call, not a side effect of "stop".
    @discardableResult
    func stopDispatching() -> Int {
        let dropped = pending.count
        document.dispatches.removeAll { !$0.dispatched }
        if document.dispatches.isEmpty { document.planCreatedAt = nil }
        save()
        return dropped
    }

    func clearPlan() {
        document.dispatches = []
        document.planCreatedAt = nil
        save()
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
}
