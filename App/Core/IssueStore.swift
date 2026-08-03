import Foundation

/// Holds a project's GitHub issues.
///
/// Per project and kept alive across screen visits, the way the task stores
/// are: an issue list is a network round trip per repository, and refetching it
/// every time the Tasks screen opens would make the screen feel like the
/// network. A stale list is shown while a refresh runs, rather than an empty
/// one — nothing here is authoritative enough to blank the screen for.
@MainActor
final class IssueStore: ObservableObject {
    @Published private(set) var issues: [GitHubIssue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshAt: Date?
    /// One line per repository that could not be read. Surfaced rather than
    /// swallowed: "no issues" and "the token cannot see this repo" look
    /// identical otherwise.
    @Published private(set) var problems: [String] = []
    /// True once a fetch has completed, so the UI can tell "not loaded yet"
    /// from "loaded, and there are none".
    @Published private(set) var hasLoadedOnce = false

    let projectID: UUID
    let projectRoot: String

    /// Injectable so the store is testable without the network.
    var fetch: (String) async -> Result<[GitHubIssue], GitHubService.FetchError> = { slug in
        await GitHubIssueService.openIssues(slug: slug)
    }
    var discoverSlugs: (String) -> [String] = { root in
        GitHubRepoDiscovery.slugs(projectRoot: root)
    }

    init(projectID: UUID, projectRoot: String) {
        self.projectID = projectID
        self.projectRoot = projectRoot
    }

    var repositories: [String] {
        var seen = Set<String>()
        return issues.map(\.repository).filter { seen.insert($0).inserted }
    }

    func issues(labelled label: String?) -> [GitHubIssue] {
        guard let label else { return issues }
        return issues.filter { $0.labels.contains { $0.name == label } }
    }

    /// Every label across the loaded issues, most-used first.
    var labels: [GitHubIssue.Label] {
        var counts: [String: (label: GitHubIssue.Label, count: Int)] = [:]
        for issue in issues {
            for label in issue.labels {
                counts[label.name, default: (label, 0)].count += 1
            }
        }
        return counts.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.label.name < $1.label.name
        }.map(\.label)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        let root = projectRoot
        let discover = discoverSlugs
        let slugs = await Task.detached(priority: .utility) { discover(root) }.value
        guard !slugs.isEmpty else {
            // No GitHub remote is a fact about the project, not a failure, and
            // saying so beats an empty list with no explanation.
            issues = []
            problems = []
            lastRefreshAt = .now
            return
        }

        var collected: [GitHubIssue] = []
        var failures: [String] = []
        for slug in slugs {
            switch await fetch(slug) {
            case .success(let batch):
                collected += batch
            case .failure(let error):
                failures.append("\(slug): \(error.localizedDescription)")
            }
        }
        // One repository failing must not hide the issues of the others.
        if collected.isEmpty, !failures.isEmpty, !issues.isEmpty {
            problems = failures
            return
        }
        issues = collected.sorted {
            $0.updatedAt ?? .distantPast > $1.updatedAt ?? .distantPast
        }
        problems = failures
        lastRefreshAt = .now
    }

    /// Folds a local change in without a round trip, so closing an issue does
    /// not leave it on screen until the next refresh.
    func apply(_ issue: GitHubIssue) {
        guard let index = issues.firstIndex(where: { $0.id == issue.id }) else { return }
        if issue.isOpen {
            issues[index] = issue
        } else {
            issues.remove(at: index)
        }
    }
}

/// One store per project, kept for the app's lifetime like the task stores.
@MainActor
enum IssueStores {
    private static var stores: [UUID: IssueStore] = [:]

    static func store(projectID: UUID, projectRoot: String) -> IssueStore {
        if let existing = stores[projectID] { return existing }
        let store = IssueStore(projectID: projectID, projectRoot: projectRoot)
        stores[projectID] = store
        return store
    }

    static func forget(_ projectID: UUID) {
        stores[projectID] = nil
    }
}
