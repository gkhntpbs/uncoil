import Foundation

/// Something a project folder *has*, found by looking at it.
///
/// The point of naming these is that they are the only thing the project screen
/// is allowed to gate on. Before this, each feature detected its own half of the
/// answer — `TodoDiscovery.hasSources` for the Tasks tab, a `RunConfigFile`
/// read for the Run tab, `GitHubRepoDiscovery` for Issues — in its own place and
/// on its own schedule, so a new area meant a new detection, a new field on the
/// page snapshot and a new place to forget.
///
/// A capability is a fact about the folder, never about the network: a
/// repository whose issues cannot be read right now still *has* a GitHub
/// remote, and the screen says why the list is empty. Hiding it on a failed
/// request would make a rate limit look like a missing feature.
enum ProjectCapability: String, CaseIterable, Codable, Sendable {
    /// The folder is a git repository.
    case git
    /// The repository, or one of the checkouts inside the folder, has a GitHub
    /// remote — so it has issues and pull requests.
    case gitHubRepository
    /// A TODO.md (or another configured source) a session can be started on.
    case tasks
    /// At least one saved run configuration.
    case run
    /// At least one saved test suite.
    case tests
}

/// What one project has, as one value.
///
/// A set rather than a struct of booleans on purpose: adding a capability adds
/// a case, not a field on every type that carries the answer, and a view asks
/// `has(_:)` instead of knowing which boolean was named for it.
struct ProjectCapabilities: Equatable, Sendable {
    private(set) var present: Set<ProjectCapability>

    init(_ present: Set<ProjectCapability> = []) {
        self.present = present
    }

    static let none = ProjectCapabilities()

    func has(_ capability: ProjectCapability) -> Bool { present.contains(capability) }

    mutating func set(_ capability: ProjectCapability, _ isPresent: Bool) {
        if isPresent { present.insert(capability) } else { present.remove(capability) }
    }
}

/// The one place a project is looked at to decide what it has.
///
/// Blocking: every call shells out or stats the disk, so it belongs on a
/// background task. It is deliberately not a store — what to do with the answer,
/// when to re-ask and where to keep it are the caller's business.
enum ProjectDetector {
    /// Everything that can be answered from the folder alone.
    static func detect(projectRoot: String) -> ProjectCapabilities {
        let rootURL = URL(fileURLWithPath: projectRoot)
        var capabilities = ProjectCapabilities()
        capabilities.set(.tasks, TodoDiscovery.hasSources(projectRoot: projectRoot))
        capabilities.set(.run, !RunConfigFile.load(projectRoot: rootURL).configurations.isEmpty)
        capabilities.set(.tests, !TestConfigFile.load(projectRoot: rootURL).suites.isEmpty)
        // Not the root's own remote: a project folder is often a container
        // holding several checkouts, and its own directory is not a repository
        // at all. Their issues are the project's issues.
        capabilities.set(.gitHubRepository, GitHubRepoDiscovery.hasRepository(projectRoot: projectRoot))
        capabilities.set(.git, GitService.isRepository(projectRoot))
        return capabilities
    }
}
