import Foundation

/// Which parts of the project screen this project actually has.
///
/// Every area used to be offered on every project, so a folder with no TODO.md,
/// no run configuration and no GitHub remote still showed five tabs — four of
/// them leading to an empty page. That is its own problem, and it caused
/// another: the tabs are the widest thing in the project header, and with five
/// of them the header's minimum width grew past the window's, which pushed the
/// sidebar off the left edge.
///
/// An area that has nothing to show is not shown. What it would take to have
/// something is offered on the General page instead, the way the TODO.md offer
/// already worked.
enum ProjectArea: String, CaseIterable, Identifiable, Equatable {
    case overview
    case tasks
    case run
    case tests
    case issues

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "General")
        case .tasks: String(localized: "Tasks")
        case .run: String(localized: "Run")
        case .tests: String(localized: "Tests")
        case .issues: String(localized: "Issues")
        }
    }

    var iconName: String {
        switch self {
        case .overview: "layout-dashboard"
        case .tasks: "checkbox"
        case .run: "player-play"
        case .tests: "flask"
        case .issues: "circle-dot"
        }
    }

    /// What the General page offers when this area has nothing yet.
    var offerTitle: String {
        switch self {
        case .overview: ""
        case .tasks: String(localized: "Hand out work from a TODO.md")
        case .run: String(localized: "Start this project from Uncoil")
        case .tests: String(localized: "Run this project's tests from Uncoil")
        case .issues: String(localized: "Show this repository's GitHub issues")
        }
    }

    var offerDetail: String {
        switch self {
        case .overview: ""
        case .tasks:
            String(localized: "A plain Markdown checklist your agents can read and tick off. Uncoil never adds syntax of its own to it.")
        case .run:
            String(localized: "Uncoil can look for the dev server, build or compose stack this project already has, and put it behind one button.")
        case .tests:
            String(localized: "Uncoil can look for the test setup this project already has, run it, and show what failed.")
        case .issues:
            String(localized: "This folder has no GitHub remote. Add one, and the open issues of every repository in it show up here.")
        }
    }

    /// Whether the offer is something Uncoil can act on, or only explain.
    /// Nothing in the app can give a folder a GitHub remote.
    var offerIsActionable: Bool {
        switch self {
        case .tasks, .run, .tests: true
        case .overview, .issues: false
        }
    }
}

/// What a project has, as the screen sees it.
struct ProjectAreaFacts: Equatable {
    var hasTaskSources = false
    var hasRunConfigurations = false
    var hasTestSuites = false
    var hasGitHubRepository = false
}

enum ProjectAreaAvailability {
    /// The tabs to show, always led by General.
    static func areas(_ facts: ProjectAreaFacts) -> [ProjectArea] {
        var areas: [ProjectArea] = [.overview]
        if facts.hasTaskSources { areas.append(.tasks) }
        if facts.hasRunConfigurations { areas.append(.run) }
        if facts.hasTestSuites { areas.append(.tests) }
        if facts.hasGitHubRepository { areas.append(.issues) }
        return areas
    }

    /// The areas General offers to set up, in tab order.
    static func offers(_ facts: ProjectAreaFacts) -> [ProjectArea] {
        ProjectArea.allCases.filter { $0 != .overview && !areas(facts).contains($0) }
    }

    /// Where to land when the selected area is no longer available — a TODO.md
    /// deleted while its tab was open, a remote removed. General always exists,
    /// so there is always somewhere to go.
    static func resolve(_ requested: ProjectArea, facts: ProjectAreaFacts) -> ProjectArea {
        areas(facts).contains(requested) ? requested : .overview
    }
}
