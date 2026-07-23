import Foundation

/// Persists projects and session records as JSON under Application Support/Uncoil.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [SessionRecord] = []

    private let projectsURL: URL
    private let sessionsURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        projectsURL = base.appendingPathComponent("projects.json")
        sessionsURL = base.appendingPathComponent("sessions.json")
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
                return $0.lastActivityAt > $1.lastActivityAt
            }
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
        worktreePath: String? = nil
    ) -> SessionRecord {
        let record = SessionRecord(
            projectID: projectID,
            provider: provider,
            accountID: accountID,
            title: title,
            worktreePath: worktreePath
        )
        sessions.append(record)
        save()
        return record
    }

    func updateSession(_ id: UUID, mutate: (inout SessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        save()
    }

    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: projectsURL),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessions = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: projectsURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }
}

/// Runtime status per session record (in-memory; terminals do not survive quit).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var statuses: [UUID: AgentSessionStatus] = [:]
    @Published private(set) var details: [UUID: String] = [:]
    var hookServer: HookServer?

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

    /// The session that should receive hook events for a project: the most
    /// recently started live (non-terminated) one.
    func liveSessionID(projectSessions: [SessionRecord]) -> UUID? {
        projectSessions
            .filter { (statuses[$0.id] ?? .terminated) != .terminated }
            .max { $0.createdAt < $1.createdAt }?
            .id
    }
}
