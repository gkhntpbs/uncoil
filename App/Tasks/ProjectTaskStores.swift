import Foundation

/// One live set of task stores per project, kept between visits.
///
/// The Tasks screen used to create its stores as `@StateObject`s, so leaving the
/// screen threw away the scan, the per-file mtime stamps and the loaded
/// metadata — and coming back re-read every `TODO.md` from disk before it could
/// draw a row. Holding them here means a return costs a stat per file at most,
/// and usually nothing at all.
///
/// A project's stores are created on first use and then stay: they are small,
/// there are as many as the user has projects open, and the alternative is
/// paying the scan again every time.
@MainActor
enum ProjectTaskStores {
    private static var sources: [UUID: TodoSourceStore] = [:]
    private static var metadata: [UUID: ProjectTaskMetadataStore] = [:]
    private static var results: [UUID: TaskResultStore] = [:]

    static func sources(projectID: UUID, projectRoot: String) -> TodoSourceStore {
        if let existing = sources[projectID], existing.projectRoot == projectRoot {
            return existing
        }
        let store = TodoSourceStore(projectID: projectID, projectRoot: projectRoot)
        sources[projectID] = store
        return store
    }

    static func metadata(projectID: UUID) -> ProjectTaskMetadataStore {
        if let existing = metadata[projectID] { return existing }
        let store = ProjectTaskMetadataStore(projectID: projectID)
        metadata[projectID] = store
        return store
    }

    static func results(projectID: UUID) -> TaskResultStore {
        if let existing = results[projectID] { return existing }
        let store = TaskResultStore(projectID: projectID)
        results[projectID] = store
        return store
    }

    /// Forgets a project's stores — for when the project itself is gone.
    static func forget(projectID: UUID) {
        sources[projectID] = nil
        metadata[projectID] = nil
        results[projectID] = nil
    }
}
