import Foundation

/// Uncoil's own state about a project's tasks: which session is working what,
/// claim leases, board mapping and view preferences.
///
/// Stored beside the project under Application Support, never in `TODO.md` — the
/// file stays something any agent or editor can own.
@MainActor
final class ProjectTaskMetadataStore: ObservableObject {
    @Published private(set) var document = ProjectTaskMetadataDocument()
    @Published var preferences = ProjectTaskViewPreferences.default

    private let fileURL: URL
    private let preferencesURL: URL

    init(projectID: UUID, dataDirectory: URL? = nil) {
        let base = (dataDirectory ?? ProjectStore.defaultDirectory())
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        fileURL = base.appendingPathComponent("metadata.json")
        preferencesURL = base.appendingPathComponent("view.json")
        load()
    }

    // MARK: - Assignments

    /// Assignments grouped by task id, which is what the views need.
    var assignmentsByTask: [String: [TaskSessionAssignment]] {
        Dictionary(grouping: document.assignments, by: \.taskID)
    }

    func assignments(for taskID: String) -> [TaskSessionAssignment] {
        document.assignments.filter { $0.taskID == taskID }
    }

    func assignments(forSession sessionID: UUID) -> [TaskSessionAssignment] {
        document.assignments.filter { $0.sessionID == sessionID }
    }

    @discardableResult
    func assign(
        taskID: String,
        sourcePath: String,
        sessionID: UUID,
        role: TaskAgentRole,
        worktreePath: String? = nil,
        fingerprint: TaskFingerprint? = nil,
        now: Date = .now
    ) -> TaskSessionAssignment {
        // One assignment per (task, session, role): re-assigning the same work
        // updates it rather than piling up duplicates. A different role, or a
        // different session, is a separate link — the relationship is
        // many-to-many by design.
        if let index = document.assignments.firstIndex(where: {
            $0.taskID == taskID && $0.sessionID == sessionID && $0.role == role
        }) {
            document.assignments[index].state = .assigned
            document.assignments[index].worktreePath = worktreePath
            document.assignments[index].updatedAt = now
            document.assignments[index].needsRelinking = false
            if let fingerprint { document.assignments[index].fingerprint = fingerprint }
            document.assignments[index].history.append(
                TaskExecutionEvent(state: .assigned, at: now)
            )
            save()
            return document.assignments[index]
        }
        let assignment = TaskSessionAssignment(
            taskID: taskID, sourcePath: sourcePath, sessionID: sessionID,
            role: role, worktreePath: worktreePath, assignedAt: now, updatedAt: now,
            fingerprint: fingerprint
        )
        document.assignments.append(assignment)
        save()
        return assignment
    }

    /// Re-points an assignment at another task after the user resolved a
    /// relink. The task itself is never touched.
    func rebind(assignmentID: UUID, to task: ProjectTask, now: Date = .now) {
        guard let index = document.assignments.firstIndex(where: { $0.id == assignmentID }) else {
            return
        }
        document.assignments[index].taskID = task.id
        document.assignments[index].sourcePath = task.sourcePath
        document.assignments[index].fingerprint = task.fingerprint
        document.assignments[index].needsRelinking = false
        document.assignments[index].updatedAt = now
        document.needsRelinking = document.assignments.filter(\.needsRelinking).map(\.taskID)
        save()
    }

    func setState(
        _ state: ProjectTaskExecutionState,
        assignmentID: UUID,
        detail: String? = nil,
        now: Date = .now
    ) {
        guard let index = document.assignments.firstIndex(where: { $0.id == assignmentID }) else {
            return
        }
        guard document.assignments[index].state != state || detail != nil else { return }
        document.assignments[index].state = state
        document.assignments[index].updatedAt = now
        document.assignments[index].history.append(
            TaskExecutionEvent(state: state, at: now, detail: detail)
        )
        // History is bounded: a long-running task must not grow without limit.
        if document.assignments[index].history.count > 200 {
            document.assignments[index].history.removeFirst(
                document.assignments[index].history.count - 200
            )
        }
        save()
    }

    /// Sets the state of every assignment on a task — what a card-level action
    /// like "Mark Blocked" means.
    func setState(
        _ state: ProjectTaskExecutionState,
        taskID: String,
        detail: String? = nil,
        now: Date = .now
    ) {
        for assignment in assignments(for: taskID) {
            setState(state, assignmentID: assignment.id, detail: detail, now: now)
        }
    }

    /// Everything that happened to a task, newest first, across its sessions.
    ///
    /// Two events can share a timestamp (a state set in the same instant it was
    /// assigned), so insertion order breaks the tie — otherwise the order of a
    /// task's own history would vary between reads.
    func history(for taskID: String) -> [TaskExecutionEvent] {
        assignments(for: taskID)
            .flatMap(\.history)
            .enumerated()
            .sorted {
                $0.element.at != $1.element.at
                    ? $0.element.at > $1.element.at
                    : $0.offset > $1.offset
            }
            .map(\.element)
    }

    func removeAssignment(id: UUID) {
        document.assignments.removeAll { $0.id == id }
        save()
    }

    /// The execution state a card shows: the most urgent of its assignments.
    func executionState(for taskID: String) -> ProjectTaskExecutionState {
        let states = assignments(for: taskID).map(\.state)
        guard !states.isEmpty else { return .unassigned }
        if let attention = states.first(where: \.needsAttention) { return attention }
        if let active = states.first(where: \.isActive) { return active }
        return states.contains(.completed) ? .completed : states[0]
    }

    // MARK: - Relinking

    /// Fingerprints of the tasks Uncoil tracks, keyed by assignment id — the
    /// input the source store needs to re-resolve them after a file changed.
    func trackedFingerprints(in tasks: [ProjectTask]) -> [String: TaskFingerprint] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(
            document.assignments.compactMap { assignment in
                // The stored fingerprint comes first: looking the task up in the
                // current document would return nothing for a task that just
                // vanished, and that is precisely the case worth flagging.
                let fingerprint = assignment.fingerprint ?? byID[assignment.taskID]?.fingerprint
                return fingerprint.map { (assignment.id.uuidString, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Marks the assignments whose task could not be re-resolved. They keep
    /// pointing at their last known task so the user can decide.
    func markNeedsRelinking(assignmentIDs: Set<String>) {
        var changed = false
        for index in document.assignments.indices {
            let needs = assignmentIDs.contains(document.assignments[index].id.uuidString)
            if document.assignments[index].needsRelinking != needs {
                document.assignments[index].needsRelinking = needs
                changed = true
            }
        }
        document.needsRelinking = document.assignments
            .filter(\.needsRelinking)
            .map(\.taskID)
        if changed { save() }
    }

    // MARK: - Leases

    /// Grants a claim when nobody else holds a live one.
    func claim(
        taskID: String,
        sourcePath: String,
        sessionID: UUID,
        duration: TimeInterval = 15 * 60,
        now: Date = .now
    ) -> TaskClaimLease? {
        document.leases.removeAll { $0.isExpired(at: now) }
        if let existing = document.leases.first(where: { $0.taskID == taskID }) {
            guard existing.sessionID == sessionID else { return nil }
            // Renewal: bump the generation so a stale holder cannot win.
            document.leases.removeAll { $0.taskID == taskID }
            let renewed = TaskClaimLease(
                id: existing.id, taskID: taskID, sourcePath: sourcePath,
                sessionID: sessionID, acquiredAt: now, duration: duration,
                generation: existing.generation + 1
            )
            document.leases.append(renewed)
            save()
            return renewed
        }
        let lease = TaskClaimLease(
            taskID: taskID, sourcePath: sourcePath, sessionID: sessionID,
            acquiredAt: now, duration: duration
        )
        document.leases.append(lease)
        save()
        return lease
    }

    func release(taskID: String, sessionID: UUID) {
        document.leases.removeAll { $0.taskID == taskID && $0.sessionID == sessionID }
        save()
    }

    func lease(for taskID: String, now: Date = .now) -> TaskClaimLease? {
        document.leases.first { $0.taskID == taskID && !$0.isExpired(at: now) }
    }

    // MARK: - Persistence

    func save() {
        write(document, to: fileURL)
    }

    func savePreferences() {
        write(preferences, to: preferencesURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        AtomicFile.write(data, to: url)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: fileURL.path),
           let decoded = try? decoder.decode(ProjectTaskMetadataDocument.self, from: data),
           decoded.version <= ProjectTaskMetadataDocument.currentVersion {
            document = decoded
        }
        if let data = FileManager.default.contents(atPath: preferencesURL.path),
           let decoded = try? decoder.decode(ProjectTaskViewPreferences.self, from: data) {
            preferences = decoded
        }
    }
}
