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
        var openTaskCount = 0
        /// What this project has, detected once. The tabs, the offers and the
        /// landing area are built from it rather than every area being offered
        /// everywhere; see `ProjectAreaAvailability`.
        var capabilities = ProjectCapabilities.none

        var hasTaskSources: Bool { capabilities.has(.tasks) }
        /// When this was last built. `nil` means the project has never been
        /// opened, which is the only time the page has nothing to show.
        var loadedAt: Date?

        var hasLoaded: Bool { loadedAt != nil }
        /// Git status and worktrees are in. Separate from `loadedAt`, which
        /// also waits for GitHub: the local panels used to sit on skeletons
        /// until a network request answered.
        var gitLoaded = false
        /// The pull-request request has answered (or there is no remote).
        var pullRequestsLoaded = false
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

        // What the project has, first: it is stat calls and one `rev-parse`,
        // and it decides which tabs exist at all.
        let capabilities = await Task.detached(priority: .userInitiated) {
            ProjectDetector.detect(projectRoot: root)
        }.value
        var snapshot = snapshots[id] ?? Snapshot()
        snapshot.capabilities = capabilities
        snapshot.openTaskCount = 0
        snapshots[id] = snapshot

        if capabilities.has(.tasks) {
            let loaded = await Task.detached(priority: .utility) {
                TodoDiscovery.load(projectID: id, projectRoot: root)
            }.value
            snapshot.openTaskCount = loaded.flatMap(\.document.tasks).filter { !$0.isDone }.count
            snapshots[id] = snapshot
        }

        // The remote is one quick `git config` read; with it known, GitHub is
        // asked at the same time as the local git commands run instead of
        // after them.
        let remote = await Task.detached(priority: .userInitiated) {
            GitService.remoteURL(repoPath: root)
        }.value
        async let pulls: (pullRequests: [GitHubService.PullRequest], message: String?) = {
            guard let remote, let slug = GitHubService.repoSlug(fromRemoteURL: remote) else {
                return ([], String(localized: "Origin is not a GitHub repo, or there is no remote."))
            }
            switch await GitHubService.openPullRequests(slug: slug) {
            case .success(let pullRequests):
                return (pullRequests, pullRequests.isEmpty ? String(localized: "No open pull requests.") : nil)
            case .failure(let error):
                return ([], error.errorDescription)
            }
        }()

        let (git, worktrees) = await Task.detached(priority: .userInitiated) {
            (GitService.snapshot(repoPath: root), GitService.worktrees(repoPath: root))
        }.value
        snapshot = snapshots[id] ?? snapshot
        snapshot.git = git
        snapshot.worktrees = worktrees
        snapshot.gitLoaded = true
        snapshots[id] = snapshot

        let answered = await pulls
        snapshot = snapshots[id] ?? snapshot
        snapshot.pullRequests = answered.pullRequests
        snapshot.prMessage = answered.message
        snapshot.pullRequestsLoaded = true
        snapshot.loadedAt = .now
        snapshots[id] = snapshot
    }
}
