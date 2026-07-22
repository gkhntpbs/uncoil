import Foundation

/// Persists registered projects as JSON under Application Support/Uncoil.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("projects.json")
        load()
    }

    nonisolated static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uncoil", isDirectory: true)
    }

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

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        // Atomic write so a crash can never corrupt the registry.
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Tracks live agent sessions (not persisted yet — MVP keeps them in-memory).
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    var hookServer: HookServer?

    func session(for projectID: UUID) -> AgentSession? {
        sessions.first { $0.projectID == projectID && $0.status != .terminated }
    }

    @discardableResult
    func startSession(projectID: UUID, title: String) -> AgentSession {
        let session = AgentSession(projectID: projectID, title: title)
        sessions.append(session)
        return session
    }
}
