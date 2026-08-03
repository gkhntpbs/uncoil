import Foundation

/// The first-run flow, as data.
///
/// Every step is optional: the user can skip one ("not now") or leave the whole
/// flow from the persistent Skip in the corner. What that costs is visible
/// afterwards — an unfinished step stays listed in the sidebar's resume row
/// rather than silently never happening.
enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case clis
    case accounts
    case workingModes
    case hooks
    case notifications
    case capabilities
    case tools
    case project
    case tasks
    case extensions
    case palette
    case finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .clis: String(localized: "Agent CLIs")
        case .accounts: String(localized: "Accounts")
        case .workingModes: String(localized: "Working modes")
        case .hooks: String(localized: "Status tracking")
        case .notifications: String(localized: "Notifications")
        case .capabilities: String(localized: "Agent capabilities")
        case .tools: String(localized: "Optional tools")
        case .project: String(localized: "First project")
        case .tasks: String(localized: "Tasks")
        case .extensions: String(localized: "Extensions")
        case .palette: String(localized: "Command palette")
        case .finish: String(localized: "Ready")
        }
    }

    /// Steps that set something up. The bookends only explain, so they are never
    /// counted as work left undone.
    var isActionable: Bool {
        switch self {
        case .welcome, .finish: false
        default: true
        }
    }
}

/// Pure navigation over ``OnboardingStep``, kept free of SwiftUI so the order,
/// the resume list and the version gate are unit-testable on their own.
enum OnboardingFlow {
    /// Bumped when a step is added that an existing user should still see.
    /// A stamped version lower than this reopens the flow at the new steps only.
    ///
    /// 3: the working-mode and optional-tools steps.
    static let currentVersion = 3

    static var all: [OnboardingStep] { OnboardingStep.allCases }

    static func index(of step: OnboardingStep) -> Int {
        all.firstIndex(of: step) ?? 0
    }

    static func next(after step: OnboardingStep) -> OnboardingStep? {
        let position = index(of: step) + 1
        return all.indices.contains(position) ? all[position] : nil
    }

    static func previous(before step: OnboardingStep) -> OnboardingStep? {
        let position = index(of: step) - 1
        return all.indices.contains(position) ? all[position] : nil
    }

    /// Actionable steps the user has not completed, in flow order — what the
    /// resume row counts and where "continue setup" lands.
    static func remaining(completed: Set<String>) -> [OnboardingStep] {
        all.filter { $0.isActionable && !completed.contains($0.rawValue) }
    }

    /// Whether the flow should open on launch: never seen, or seen at an older
    /// version that has since gained steps.
    static func shouldPresent(stampedVersion: Int?) -> Bool {
        guard let stampedVersion else { return true }
        return stampedVersion < currentVersion
    }

    /// Where to resume: the first unfinished actionable step, else the welcome.
    static func resumeStep(completed: Set<String>) -> OnboardingStep {
        remaining(completed: completed).first ?? .welcome
    }
}

/// Which of the extensions found on this machine onboarding may offer to take
/// over. Pure, so "does detection actually work" is a test rather than a demo:
/// an install Uncoil already owns is not offered, and a blocked finding takes a
/// package out of the list entirely.
enum OnboardingAdoption {
    static func adoptable(
        packages: [ExtensionPackage],
        findings: [SecurityFinding]
    ) -> [ExtensionPackage] {
        let blocked = Set(
            findings
                .filter { $0.severity == .blocked && !$0.isAccepted }
                .map(\.extensionID)
        )
        return packages.filter { package in
            guard case .detectedExternal = package.source else { return false }
            return !blocked.contains(package.id)
        }
    }
}
