import Foundation

/// When a cached project page is old enough to be worth rebuilding.
///
/// Pure so the rule can be tested without waiting on a clock: a page that was
/// never loaded always refreshes, one loaded a moment ago never does, and one
/// past the window refreshes on its next appearance.
enum ProjectPageFreshness {
    /// Long enough that flipping between projects is free, short enough that a
    /// commit made in a session shows up without being asked for.
    static let window: TimeInterval = 90

    static func needsRefresh(
        loadedAt: Date?,
        now: Date = .now,
        window: TimeInterval = window
    ) -> Bool {
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) >= window
    }
}

/// Everything the project dashboard draws that has to be fetched, kept between
/// visits.
///
/// The dashboard used to hold all of this in `@State`, so leaving the screen
/// threw it away and coming back re-ran a `TODO.md` scan, three git
/// subprocesses and a GitHub request before anything could be drawn. The page
/// now renders from the last snapshot immediately and refreshes behind it only
/// when that snapshot has gone stale.
@MainActor
final class ProjectPageStore: ObservableObject {
    static let shared = ProjectPageStore()

    struct Snapshot: Equatable {
        var git = GitService.Snapshot()
        var worktrees: [GitService.Worktree] = []
        var pullRequests: [GitHubService.PullRequest] = []
        var prMessage: String?
        var hasTaskSources = false
        var openTaskCount = 0
        /// When this was last built. `nil` means the project has never been
        /// opened, which is the only time the page has nothing to show.
        var loadedAt: Date?

        var hasLoaded: Bool { loadedAt != nil }
    }

    @Published private(set) var snapshots: [UUID: Snapshot] = [:]
    /// Projects being refreshed right now, so two appearances in a row do not
    /// run the same git subprocesses twice.
    private var inFlight: Set<UUID> = []

    func snapshot(for projectID: UUID) -> Snapshot {
        snapshots[projectID] ?? Snapshot()
    }

    /// Drops a project's snapshot so the next look rebuilds it — for after
    /// something the app itself did, like creating a worktree.
    func invalidate(_ projectID: UUID) {
        snapshots[projectID]?.loadedAt = nil
    }

    /// Forgets a project entirely, for when it is removed from the sidebar.
    func forget(_ projectID: UUID) {
        snapshots[projectID] = nil
    }

    /// Rebuilds the page unless a fresh snapshot is already there.
    func refreshIfNeeded(project: Project, force: Bool = false, now: Date = .now) async {
        let existing = snapshots[project.id]
        guard force || ProjectPageFreshness.needsRefresh(loadedAt: existing?.loadedAt, now: now)
        else { return }
        await refresh(project: project)
    }

    func refresh(project: Project) async {
        guard !inFlight.contains(project.id) else { return }
        inFlight.insert(project.id)
        defer { inFlight.remove(project.id) }

        let id = project.id
        let root = project.rootPath

        // Tasks first: it is a couple of stat calls and it decides whether the
        // Tasks tab exists at all.
        let present = await Task.detached(priority: .utility) {
            TodoDiscovery.hasSources(projectRoot: root)
        }.value
        var snapshot = snapshots[id] ?? Snapshot()
        snapshot.hasTaskSources = present
        snapshot.openTaskCount = 0
        snapshots[id] = snapshot

        if present {
            let loaded = await Task.detached(priority: .utility) {
                TodoDiscovery.load(projectID: id, projectRoot: root)
            }.value
            snapshot.openTaskCount = loaded.flatMap(\.document.tasks).filter { !$0.isDone }.count
            snapshots[id] = snapshot
        }

        let (git, worktrees, remote) = await Task.detached(priority: .utility) {
            (
                GitService.snapshot(repoPath: root),
                GitService.worktrees(repoPath: root),
                GitService.remoteURL(repoPath: root)
            )
        }.value
        snapshot.git = git
        snapshot.worktrees = worktrees
        snapshots[id] = snapshot

        // The network call last: the local half of the page is already on
        // screen by the time GitHub answers.
        if let remote, let slug = GitHubService.repoSlug(fromRemoteURL: remote) {
            switch await GitHubService.openPullRequests(slug: slug) {
            case .success(let pullRequests):
                snapshot.pullRequests = pullRequests
                snapshot.prMessage = pullRequests.isEmpty ? "No open PRs." : nil
            case .failure(let error):
                snapshot.pullRequests = []
                snapshot.prMessage = error.errorDescription
            }
        } else {
            snapshot.pullRequests = []
            snapshot.prMessage = "Origin is not a GitHub repo, or there is no remote."
        }

        snapshot.loadedAt = .now
        snapshots[id] = snapshot
    }
}
