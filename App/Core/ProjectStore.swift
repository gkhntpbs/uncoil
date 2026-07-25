import Foundation

/// Persists projects and session records as JSON under Application Support/Uncoil.
@MainActor
final class ProjectStore: ObservableObject {
    nonisolated static let currentSessionSchemaVersion = SessionRecord.currentMetadataVersion

    struct SessionDocument: Codable, Equatable {
        var schemaVersion: Int
        var sessions: [SessionRecord]
    }

    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var sessionGroups: [SessionGroup] = []

    private let projectsURL: URL
    private let sessionsURL: URL
    private let sessionGroupsURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        projectsURL = base.appendingPathComponent("projects.json")
        sessionsURL = base.appendingPathComponent("sessions.json")
        sessionGroupsURL = base.appendingPathComponent("session-groups.json")
        load()
    }

    nonisolated static func defaultDirectory() -> URL {
        if let override = LaunchConfig.shared.dataDirectoryOverride {
            return override
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uncoil", isDirectory: true)
    }

    // MARK: - Projects

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        guard !projects.contains(where: { $0.rootPath == path }) else { return }
        projects.append(Project(name: url.lastPathComponent, rootPath: path))
        sortProjects()
        save()
    }

    /// Sidebar order: pinned first, then whatever the user dragged into place,
    /// then the order they were added in. Held in the array itself so every
    /// screen that reads `projects` shows the same order.
    func sortProjects() {
        projects.sort {
            let leftPinned = $0.isPinned ?? false
            let rightPinned = $1.isPinned ?? false
            if leftPinned != rightPinned { return leftPinned }
            switch ($0.sortIndex, $1.sortIndex) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return $0.createdAt < $1.createdAt
            }
        }
    }

    /// Drag-reorder: places `draggedID` before `targetID`. The first manual move
    /// freezes the current display order into indexes.
    func moveProject(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = projects.firstIndex(where: { $0.id == draggedID }),
              var to = projects.firstIndex(where: { $0.id == targetID }) else { return }
        var ordered = projects
        let moved = ordered.remove(at: from)
        if from < to { to -= 1 }
        ordered.insert(moved, at: to)
        for (index, project) in ordered.enumerated() {
            guard let position = projects.firstIndex(where: { $0.id == project.id }) else { continue }
            projects[position].sortIndex = Double(index)
        }
        sortProjects()
        save()
    }

    /// Drag-reorder to an exact slot: `index` is a position in the current
    /// display order, the way an insertion point between two rows reads. Pinned
    /// projects still sort first afterwards, so a slot above them is honoured
    /// only as far as the pin allows.
    func moveProject(_ draggedID: UUID, toIndex index: Int) {
        guard projects.contains(where: { $0.id == draggedID }) else { return }
        let ordered = SidebarReorder.moved(projects.map(\.id), dragged: draggedID, toIndex: index)
        applyProjectOrder(ordered)
    }

    private func applyProjectOrder(_ ordered: [UUID]) {
        for (index, id) in ordered.enumerated() {
            guard let position = projects.firstIndex(where: { $0.id == id }) else { continue }
            projects[position].sortIndex = Double(index)
        }
        sortProjects()
        save()
    }

    /// Moves a project one step up or down among its peers, for the context
    /// menu — dragging is not the only way to reorder.
    func nudgeProject(_ id: UUID, by offset: Int) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard projects.indices.contains(target) else { return }
        // Crossing the pinned boundary takes the pinned state along; otherwise
        // the sort would put the project straight back where it was.
        if (projects[index].isPinned ?? false) != (projects[target].isPinned ?? false) {
            projects[index].isPinned = projects[target].isPinned
        }
        projects.swapAt(index, target)
        for position in projects.indices {
            projects[position].sortIndex = Double(position)
        }
        sortProjects()
        save()
    }

    func toggleProjectPin(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isPinned = !(projects[index].isPinned ?? false)
        sortProjects()
        save()
    }

    /// Longest-prefix match so agents running in worktree subdirectories
    /// still resolve to their project.
    func project(containing path: String) -> Project? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return projects
            .filter { normalized == $0.rootPath || normalized.hasPrefix($0.rootPath + "/") }
            .max { $0.rootPath.count < $1.rootPath.count }
    }

    func updateProject(_ id: UUID, mutate: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&projects[index])
        save()
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        sessions.removeAll { $0.projectID == project.id }
        sessionGroups.removeAll { $0.projectID == project.id }
        // The cached page and task stores are kept alive per project so
        // reopening one is instant; a project that is gone keeps nothing.
        ProjectPageStore.shared.forget(project.id)
        ProjectTaskStores.forget(projectID: project.id)
        save()
    }

    func groups(for projectID: UUID) -> [SessionGroup] {
        sessionGroups
            .filter { $0.projectID == projectID }
            .sorted {
                switch ($0.sortIndex, $1.sortIndex) {
                case let (left?, right?): return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return $0.createdAt < $1.createdAt
                }
            }
    }

    @discardableResult
    func createGroup(projectID: UUID, name: String) -> SessionGroup? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              projects.contains(where: { $0.id == projectID }) else { return nil }
        let group = SessionGroup(projectID: projectID, name: normalized)
        sessionGroups.append(group)
        save()
        return group
    }

    func updateGroup(_ id: UUID, mutate: (inout SessionGroup) -> Void) {
        guard let index = sessionGroups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessionGroups[index])
        save()
    }

    func removeGroup(_ id: UUID) {
        sessionGroups.removeAll { $0.id == id }
        for index in sessions.indices where sessions[index].groupID == id {
            sessions[index].groupID = nil
        }
        save()
    }

    func assignSessions(_ ids: Set<UUID>, to groupID: UUID?) {
        let projectID = groupID.flatMap { id in
            sessionGroups.first(where: { $0.id == id })?.projectID
        }
        for index in sessions.indices where ids.contains(sessions[index].id) {
            if let projectID, sessions[index].projectID != projectID { continue }
            sessions[index].groupID = groupID
        }
        save()
    }

    // MARK: - Sessions

    func sessions(for projectID: UUID) -> [SessionRecord] {
        sessions
            .filter { $0.projectID == projectID }
            .sorted {
                let leftPinned = $0.isPinned ?? false
                let rightPinned = $1.isPinned ?? false
                if leftPinned != rightPinned { return leftPinned }
                switch ($0.sortIndex, $1.sortIndex) {
                case let (left?, right?): return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return $0.lastActivityAt > $1.lastActivityAt
                }
            }
    }

    func sessions(in groupID: UUID) -> [SessionRecord] {
        guard let group = sessionGroups.first(where: { $0.id == groupID }) else { return [] }
        return sessions(for: group.projectID).filter { $0.groupID == groupID }
    }

    func activeSessions(for projectID: UUID) -> [SessionRecord] {
        sessions(for: projectID).filter { $0.endedAt == nil }
    }

    func sessionHistory(for projectID: UUID) -> [SessionRecord] {
        sessions(for: projectID)
            .filter { $0.endedAt != nil }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// Drag-reorder: places `draggedID` before `targetID` in its project.
    /// The first manual move freezes the current display order into indexes.
    func moveSession(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let dragged = sessions.first(where: { $0.id == draggedID }) else { return }
        var ordered = sessions(for: dragged.projectID)
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              var to = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = ordered.remove(at: from)
        if from < to { to -= 1 }
        ordered.insert(moved, at: to)
        for (index, record) in ordered.enumerated() {
            updateSessionQuietly(record.id) { $0.sortIndex = Double(index) }
        }
        save()
        objectWillChange.send()
    }

    /// Drag-reorder plus regroup in one write: moves `ids` into `groupID`
    /// (`nil` meaning "out of any group") at child slot `index`.
    ///
    /// Session order is stored project-wide, so the slot — which the sidebar
    /// expresses relative to the rows of one group — is translated into a new
    /// order for every session in the project. One `save()`, one change
    /// notification, so the sidebar does not animate the regroup and the
    /// reorder as two separate steps.
    func moveSessions(
        _ ids: [UUID],
        toGroup groupID: UUID?,
        inProject projectID: UUID,
        at index: Int
    ) {
        if let groupID, sessionGroups.first(where: { $0.id == groupID })?.projectID != projectID {
            return
        }
        let moving = ids.filter { id in
            sessions.first(where: { $0.id == id })?.projectID == projectID
        }
        guard !moving.isEmpty else { return }

        let ordered = sessions(for: projectID)
        let siblings = ordered.filter { $0.groupID == groupID }.map(\.id)
        let newOrder = SidebarReorder.moved(
            ordered.map(\.id), siblings: siblings, dragged: moving, toIndex: index
        )
        for id in moving {
            updateSessionQuietly(id) { $0.groupID = groupID }
        }
        for (position, id) in newOrder.enumerated() {
            updateSessionQuietly(id) { $0.sortIndex = Double(position) }
        }
        save()
        objectWillChange.send()
    }

    /// Moves a session one step up or down among its siblings — the sessions in
    /// its own group, or the project's loose ones — for the context menu.
    ///
    /// Pinned sessions sort ahead of the rest, so a step that would cross that
    /// boundary carries the pin with it; otherwise the sort would put the
    /// session straight back where it was.
    func nudgeSession(_ id: UUID, by offset: Int) {
        guard let record = sessions.first(where: { $0.id == id }) else { return }
        let ordered = sessions(for: record.projectID)
        let siblings = ordered.filter { $0.groupID == record.groupID }
        guard let position = siblings.firstIndex(where: { $0.id == id }) else { return }
        let target = position + offset
        guard siblings.indices.contains(target) else { return }

        if (siblings[position].isPinned ?? false) != (siblings[target].isPinned ?? false) {
            updateSessionQuietly(id) { $0.isPinned = siblings[target].isPinned }
        }
        let newOrder = SidebarReorder.moved(
            ordered.map(\.id),
            siblings: siblings.map(\.id),
            dragged: [id],
            // A swap expressed as an insertion: stepping down lands past the
            // neighbour, which pre-removal indexing puts one further along.
            toIndex: offset < 0 ? target : target + 1
        )
        for (index, sessionID) in newOrder.enumerated() {
            updateSessionQuietly(sessionID) { $0.sortIndex = Double(index) }
        }
        save()
        objectWillChange.send()
    }

    private func updateSessionQuietly(_ id: UUID, mutate: (inout SessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
    }

    func togglePin(_ id: UUID) {
        updateSession(id) { $0.isPinned = !($0.isPinned ?? false) }
    }

    @discardableResult
    func createSession(
        projectID: UUID,
        provider: AgentProvider,
        accountID: UUID?,
        title: String,
        worktreePath: String? = nil,
        launchSelection: AgentLaunchSelection? = nil
    ) -> SessionRecord {
        var record = SessionRecord(
            projectID: projectID,
            provider: provider,
            accountID: accountID,
            title: title,
            worktreePath: worktreePath
        )
        // nil when default: an empty selection must not read as "configured".
        record.launchSelection = launchSelection?.isDefault == false ? launchSelection : nil
        sessions.append(record)
        save()
        return record
    }

    func updateSession(_ id: UUID, mutate: (inout SessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        save()
    }

    func markSessionStarted(_ id: UUID) {
        updateSession(id) {
            if $0.endedAt != nil {
                $0.restartCount = ($0.restartCount ?? 0) + 1
            }
            $0.endedAt = nil
            $0.exitCode = nil
            $0.lastActivityAt = .now
            $0.metadataVersion = Self.currentSessionSchemaVersion
        }
    }

    func markSessionEnded(_ id: UUID, exitCode: Int32?) {
        updateSession(id) {
            $0.endedAt = .now
            $0.exitCode = exitCode
            $0.lastActivityAt = .now
            $0.metadataVersion = Self.currentSessionSchemaVersion
        }
    }

    @discardableResult
    func claimProviderSessionID(_ providerSessionID: String, for id: UUID) -> Bool {
        guard !providerSessionID.isEmpty,
              !sessions.contains(where: {
                  $0.id != id && $0.providerSessionID == providerSessionID
              }),
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].providerSessionID == nil
        else { return false }
        sessions[index].providerSessionID = providerSessionID
        sessions[index].metadataVersion = Self.currentSessionSchemaVersion
        saveSessions()
        objectWillChange.send()
        return true
    }

    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func removeSessions(_ ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - Persistence

    private func load() {
        var needsSessionSave = false
        // Versioned document, falling back to the bare array an older build
        // wrote so an existing installation keeps its projects.
        if let data = try? Data(contentsOf: projectsURL),
           let decoded = VersionedDocument<[Project]>.decode(data, schema: .projects) {
            projects = decoded.payload
            sortProjects()
        }
        if let data = try? Data(contentsOf: sessionsURL) {
            if let document = try? JSONDecoder().decode(SessionDocument.self, from: data) {
                sessions = migrate(
                    document.sessions,
                    from: document.schemaVersion
                )
                if document.schemaVersion < Self.currentSessionSchemaVersion {
                    needsSessionSave = true
                }
            } else if let legacy = try? JSONDecoder().decode([SessionRecord].self, from: data) {
                sessions = migrate(legacy, from: 1)
                needsSessionSave = true
            }
        }
        if let data = try? Data(contentsOf: sessionGroupsURL),
           let decoded = VersionedDocument<[SessionGroup]>.decode(data, schema: .sessionGroups) {
            sessionGroups = decoded.payload
        }
        if needsSessionSave {
            saveSessions()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(VersionedDocument(
            schemaVersion: UncoilSchema.projects.currentVersion, payload: projects
        )) {
            try? data.write(to: projectsURL, options: .atomic)
        }
        saveSessions()
        if let data = try? JSONEncoder().encode(VersionedDocument(
            schemaVersion: UncoilSchema.sessionGroups.currentVersion, payload: sessionGroups
        )) {
            try? data.write(to: sessionGroupsURL, options: .atomic)
        }
    }

    private func saveSessions() {
        let document = SessionDocument(
            schemaVersion: Self.currentSessionSchemaVersion,
            sessions: sessions
        )
        if let data = try? JSONEncoder().encode(document) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    private func migrate(
        _ records: [SessionRecord],
        from schemaVersion: Int
    ) -> [SessionRecord] {
        records.map { record in
            var migrated = record
            if schemaVersion < 2 {
                migrated.metadataVersion = Self.currentSessionSchemaVersion
                migrated.restartCount = migrated.restartCount ?? 0
            }
            return migrated
        }
    }
}

/// Runtime status per session record (in-memory; terminals do not survive quit).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var statuses: [UUID: AgentSessionStatus] = [:]
    @Published private(set) var details: [UUID: String] = [:]
    @Published private(set) var codexAuthentication: [UUID: CodexAuthenticationState] = [:]
    @Published private(set) var codexApprovals: [UUID: CodexApprovalRequest] = [:]
    /// Bumped to force a session's terminal view to rebuild (palette "restart").
    @Published private(set) var restartCounter: [UUID: Int] = [:]

    func bumpRestart(_ id: UUID) {
        restartCounter[id, default: 0] += 1
    }
    var hookServer: HookServer?
    /// Retains the control-plane socket server (MCP → app) for its lifetime.
    var controlServer: ControlPlaneServer?
    var extensionSecretServer: ExtensionSecretServer?
    /// Directional control-plane permission requests (shared with the UI).
    var permissionService: PermissionService?
    /// Once-per-state notification dedup keys ("<sessionID>-permission" …).
    var sentNotificationKeys: Set<String> = []

    /// Sessions that sent a notification the user has not looked at yet.
    ///
    /// Status alone cannot carry this: a finished turn goes back to `.idle`,
    /// which is also what every quiet session looks like. This is what the
    /// sidebar row pulses for, and it clears the moment the session is opened.
    @Published private(set) var unseenAttention: Set<UUID> = []

    func markAttention(_ recordID: UUID) {
        unseenAttention.insert(recordID)
    }

    func clearAttention(_ recordID: UUID) {
        guard unseenAttention.contains(recordID) else { return }
        unseenAttention.remove(recordID)
    }

    func wantsAttention(_ recordID: UUID) -> Bool {
        unseenAttention.contains(recordID) || status(of: recordID).needsAttention
    }

    func status(of recordID: UUID) -> AgentSessionStatus {
        statuses[recordID] ?? .terminated
    }

    func detail(of recordID: UUID) -> String? {
        details[recordID]
    }

    func setStatus(_ status: AgentSessionStatus, detail: String? = nil, for recordID: UUID) {
        statuses[recordID] = status
        details[recordID] = detail
    }

    func setCodexAuthentication(_ state: CodexAuthenticationState, for recordID: UUID) {
        codexAuthentication[recordID] = state
    }

    func setCodexApproval(_ request: CodexApprovalRequest?, for recordID: UUID) {
        codexApprovals[recordID] = request
    }

    /// The session that should receive hook events for a project: the most
    /// recently started live (non-terminated) one.
    func liveSessionID(projectSessions: [SessionRecord]) -> UUID? {
        projectSessions
            .filter { (statuses[$0.id] ?? .terminated) != .terminated }
            .max { $0.createdAt < $1.createdAt }?
            .id
    }
}
