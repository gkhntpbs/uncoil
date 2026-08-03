import Foundation
import SwiftUI

/// Deterministic UI-testing launch configuration.
///
/// Supported arguments:
///   -ui-testing            isolate all state under a temp directory
///   -reset-state           wipe that directory before start
///   -fixture <name>        seed data ("demo" is the only fixture today)
///   -route <route>         "project" (default) | "session" | "extensions" | "onboarding"
///   -onboarding-step <id>  step the first-run window opens on
///   -extensions-section <name>  section to show when routing to extensions
///   -extensions-query <text>    prefills the Extensions search bar
///   -extensions-expand <id>     expands that package's detail panel
///   -extensions-action <name>   runs a quick action on open (healthCheck, …)
///   -window-width <pt> / -window-height <pt>
///   -disable-animations
struct LaunchConfig {
    static let shared = LaunchConfig(arguments: ProcessInfo.processInfo.arguments)

    let isUITesting: Bool
    let resetState: Bool
    let fixture: String?
    let route: String?
    /// Which Extensions screen to open with `-route extensions`.
    let extensionsSection: String?
    /// Text the Extensions search bar starts with, for a deterministic run.
    let extensionsQuery: String?
    /// Package whose detail panel starts expanded.
    let extensionsExpand: String?
    /// Quick action to run as the Extensions window opens.
    let extensionsAction: String?
    /// Project dashboard area to open (overview|tasks|run|tests).
    let projectArea: String?
    /// Onboarding step the first-run window opens on, by step id.
    let onboardingStep: String?
    let windowWidth: Double?
    let windowHeight: Double?
    let disableAnimations: Bool
    let runtimeMismatchFixture: Bool
    let codexAppServerEnabled: Bool
    let codexApprovalFixture: Bool
    let attentionFixture: Bool
    /// Checks notification authorization and delivery, prints the result, exits.
    let notificationSelfTest: Bool

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
        // Codex sessions run the Codex CLI, the way Claude sessions run theirs.
        // The app-server path speaks JSON instead, which means Uncoil has to
        // supply the prompt, the history and the editing that the CLI's own TUI
        // already does — and a session opened onto a bare cursor with none of it
        // is not the tool the user expects. The protocol client stays behind
        // this flag rather than being deleted: it is what structured approvals
        // and turn state are built on, and it is still covered by tests.
        codexAppServerEnabled = arguments.contains("-codex-app-server")
        codexApprovalFixture = isUITesting
            && arguments.contains("-codex-approval-fixture")
        attentionFixture = isUITesting
            && arguments.contains("-attention-fixture")
        notificationSelfTest = arguments.contains("-notification-selftest")
        fixture = Self.value(after: "-fixture", in: arguments)
        route = Self.value(after: "-route", in: arguments)
        extensionsSection = Self.value(after: "-extensions-section", in: arguments)
        extensionsQuery = Self.value(after: "-extensions-query", in: arguments)
        extensionsExpand = Self.value(after: "-extensions-expand", in: arguments)
        extensionsAction = Self.value(after: "-extensions-action", in: arguments)
        projectArea = Self.value(after: "-project-area", in: arguments)
        onboardingStep = Self.value(after: "-onboarding-step", in: arguments)
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
        // A small task file so the Tasks tab is exercisable in UI runs, with a
        // numbered item because those were once silently dropped by the parser.
        try? Data("""
        # Demo TODO

        ## Interface
        - [ ] Add search to the session list
        - [x] Fix dark-theme contrast
        1. [ ] Add a shortcut for the settings window

        ## Infrastructure
        - [ ] Log the daemon heartbeat
        """.utf8).write(to: projectDir.appendingPathComponent("TODO.md"))
        projectStore.addProject(at: projectDir)
        guard let project = projectStore.projects.first else { return }
        projectStore.createSession(
            projectID: project.id, provider: .terminal, accountID: nil, title: "terminal"
        )
        let main = projectStore.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: demo task"
        )
        // A sub-agent, so the sidebar's nested session row is reachable without
        // a live control-plane `create_child`.
        let sub = projectStore.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: sub-agent"
        )
        projectStore.updateSession(sub.id) { $0.parentSessionID = main.id }
        // A hibernated session, so its screen and its sidebar orb are reachable
        // without waiting out a real agent.
        let asleep = projectStore.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: parked"
        )
        projectStore.updateSession(asleep.id) { $0.providerSessionID = "demo-resume-id" }
        projectStore.markSessionAsleep(asleep.id, mode: .hibernated)
        let history = projectStore.createSession(
            projectID: project.id,
            provider: .codex,
            accountID: nil,
            title: "codex: past task"
        )
        projectStore.updateSession(history.id) {
            $0.providerSessionID = "019efe2f-5276-77c2-bd90-5191ecd4b7a0"
        }
        projectStore.markSessionEnded(history.id, exitCode: 0)
        // A test suite plus a result, so the Tests screen shows what a run
        // looks like without one having to be waited out.
        try? TestConfigFile.save([
            TestSuiteConfiguration(
                id: "unit", name: "Unit tests", command: "swift test",
                framework: .swift, isDefault: true
            ),
            TestSuiteConfiguration(
                id: "e2e", name: "End-to-end", command: "./run-e2e.sh", framework: .unknown,
                notes: "the output format is not recognised"
            ),
        ], projectRoot: projectDir)
        TestRegistry.saveRecord(
            TestRunRecord(
                id: "demo-unit", suiteID: "unit",
                startedAt: Date(timeIntervalSinceNow: -95),
                finishedAt: Date(timeIntervalSinceNow: -90),
                exitCode: 1,
                summary: TestRunSummary(passed: 128, failed: 2, skipped: 1, isDetailed: true),
                cases: [
                    TestCaseResult(
                        suite: "SidebarChildSessionTests", name: "testACycleLosesNoSession",
                        outcome: .failed
                    ),
                    TestCaseResult(
                        suite: "DockerStatusTests", name: "testEmptyOutputIsNoContainers",
                        outcome: .failed
                    ),
                ],
                logTail: "XCTAssertEqual failed: (\"2\") is not equal to (\"3\")"
            ),
            directory: TestRegistry.shared.resultsDirectory(projectID: project.id)
        )
        TestRegistry.saveRecord(
            TestRunRecord(
                id: "demo-e2e", suiteID: "e2e",
                startedAt: Date(timeIntervalSinceNow: -400),
                finishedAt: Date(timeIntervalSinceNow: -380),
                exitCode: 0,
                summary: TestRunSummary(isDetailed: false),
                cases: [],
                logTail: "all good\n"
            ),
            directory: TestRegistry.shared.resultsDirectory(projectID: project.id)
        )
        // A group with something in it, and a pinned session: the sidebar's
        // nesting and its pin marker are otherwise only reachable by hand.
        if let group = projectStore.createGroup(projectID: project.id, name: "arka plan") {
            projectStore.moveSessions(
                [history.id], toGroup: group.id, inProject: project.id, at: -1
            )
        }
        if let pinned = projectStore.sessions(for: project.id)
            .first(where: { $0.provider == .terminal }) {
            projectStore.togglePin(pinned.id)
        }
    }

    /// Seeds one row per Attention Center source so the panel can be driven
    /// deterministically, without a real permission prompt or failing test.
    @MainActor
    func seedAttentionFixture(projectStore: ProjectStore, sessionStore: SessionStore) {
        guard attentionFixture,
              let project = projectStore.projects.first,
              let session = projectStore.sessions(for: project.id).first(where: {
                  $0.provider == .claude
              }) else { return }
        sessionStore.setStatus(
            .waitingForPermission, detail: "Bash(rm -rf build)", for: session.id
        )
        AttentionStore.shared.report(
            kind: .testFailure,
            title: "\(project.name) › \(session.displayTitle)",
            detail: "3 tests failing",
            projectID: project.id,
            sessionID: session.id,
            id: "test:fixture"
        )
        AttentionRefresher.shared.refresh(
            projectStore: projectStore, sessionStore: sessionStore
        )
    }
}

/// Animation helper honoring -disable-animations.
func uncoilAnimation(_ animation: Animation?) -> Animation? {
    LaunchConfig.shared.disableAnimations ? nil : animation
}
