import Foundation
import SwiftUI

/// Deterministic UI-testing launch configuration.
///
/// Supported arguments:
///   -ui-testing            isolate all state under a temp directory
///   -reset-state           wipe that directory before start
///   -fixture <name>        seed data ("demo" is the only fixture today)
///   -route <route>         "project" (default) | "session"
///   -window-width <pt> / -window-height <pt>
///   -disable-animations
struct LaunchConfig {
    static let shared = LaunchConfig(arguments: ProcessInfo.processInfo.arguments)

    let isUITesting: Bool
    let resetState: Bool
    let fixture: String?
    let route: String?
    let windowWidth: Double?
    let windowHeight: Double?
    let disableAnimations: Bool
    let runtimeMismatchFixture: Bool

    /// Isolated data root when UI testing; nil = normal App Support.
    var dataDirectoryOverride: URL? {
        guard isUITesting else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilUITest", isDirectory: true)
    }

    init(arguments: [String]) {
        isUITesting = arguments.contains("-ui-testing")
        resetState = arguments.contains("-reset-state")
        disableAnimations = arguments.contains("-disable-animations")
        runtimeMismatchFixture = isUITesting
            && arguments.contains("-runtime-mismatch-fixture")
        fixture = Self.value(after: "-fixture", in: arguments)
        route = Self.value(after: "-route", in: arguments)
        windowWidth = Self.value(after: "-window-width", in: arguments).flatMap(Double.init)
        windowHeight = Self.value(after: "-window-height", in: arguments).flatMap(Double.init)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Call before any store is created.
    func prepareEnvironment() {
        guard let root = dataDirectoryOverride else { return }
        if resetState {
            try? FileManager.default.removeItem(at: root)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Seeds fixture data. Runs on first launch of a UI-testing session.
    @MainActor
    func seedFixture(projectStore: ProjectStore) {
        guard isUITesting, fixture == "demo", projectStore.projects.isEmpty,
              let root = dataDirectoryOverride else { return }
        let projectDir = root.appendingPathComponent("demo-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try? Data("# Demo\n".utf8).write(to: projectDir.appendingPathComponent("README.md"))
        projectStore.addProject(at: projectDir)
        guard let project = projectStore.projects.first else { return }
        projectStore.createSession(
            projectID: project.id, provider: .terminal, accountID: nil, title: "terminal"
        )
        projectStore.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: demo görev"
        )
    }
}

/// Animation helper honoring -disable-animations.
func uncoilAnimation(_ animation: Animation?) -> Animation? {
    LaunchConfig.shared.disableAnimations ? nil : animation
}
