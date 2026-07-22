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

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uncoil", isDirectory: true)
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        guard !projects.contains(where: { $0.rootPath == path }) else { return }
        projects.append(Project(name: url.lastPathComponent, rootPath: path))
        save()
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
