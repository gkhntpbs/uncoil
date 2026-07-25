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
        now: Date = .now
    ) -> TaskSessionAssignment {
        // One assignment per (task, session, role): re-assigning the same work
        // updates it rather than piling up duplicates.
        if let index = document.assignments.firstIndex(where: {
            $0.taskID == taskID && $0.sessionID == sessionID && $0.role == role
        }) {
            document.assignments[index].state = .assigned
            document.assignments[index].worktreePath = worktreePath
            document.assignments[index].updatedAt = now
            document.assignments[index].needsRelinking = false
            save()
            return document.assignments[index]
        }
        let assignment = TaskSessionAssignment(
            taskID: taskID, sourcePath: sourcePath, sessionID: sessionID,
            role: role, worktreePath: worktreePath, assignedAt: now, updatedAt: now
        )
        document.assignments.append(assignment)
        save()
        return assignment
    }

    func setState(
        _ state: ProjectTaskExecutionState,
        assignmentID: UUID,
        now: Date = .now
    ) {
        guard let index = document.assignments.firstIndex(where: { $0.id == assignmentID }) else {
            return
        }
        document.assignments[index].state = state
        document.assignments[index].updatedAt = now
        save()
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
                byID[assignment.taskID].map { (assignment.id.uuidString, $0.fingerprint) }
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
