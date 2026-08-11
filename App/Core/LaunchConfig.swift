import Foundation
import SwiftUI

/// Deterministic UI-testing launch configuration.
///
/// Supported arguments:
///   -ui-testing            isolate all state under a temp directory
///   -reset-state           wipe that directory before start
///   -fixture <name>        seed data ("demo" is the only fixture today)
///   -tests-run <suite id>  start that suite as soon as the Tests screen opens
///   -tests-step <suite id> open that suite's leading step in its detail window
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
    /// A test suite to start as soon as the Tests screen appears, so the live
    /// step stream can be watched without a click.
    let testsRun: String?
    /// A suite whose first step opens its detail window as the screen appears.
    let testsStep: String?
    /// Onboarding step the first-run window opens on, by step id.
    let onboardingStep: String?
    let windowWidth: Double?
    let windowHeight: Double?
    let disableAnimations: Bool
    let runtimeMismatchFixture: Bool
    let codexAppServerEnabled: Bool
    let codexApprovalFixture: Bool
    let attentionFixture: Bool
    /// Seeds synthetic usage snapshots and opens the usage card.
    let usageFixture: Bool
    /// Answers the handoff's "ask the outgoing agent" step with a stub script
    /// instead of a real CLI, so the whole ask-and-merge path runs in a test
    /// without a login or a quota. The path everything else takes is
    /// unchanged; only the executable differs.
    let handoffAgentStub: Bool
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
        // Usage figures come from the provider's own account, so on a machine
        // with no login — or with a plan that reports nothing — the populated
        // chip and its card cannot be reached at all. This seeds one snapshot
        // per band so both can be looked at without a subscription, and opens
        // the card, since a popover has no other way to be shown on demand.
        usageFixture = isUITesting && arguments.contains("-usage-fixture")
        handoffAgentStub = isUITesting && arguments.contains("-handoff-agent-stub")
        notificationSelfTest = arguments.contains("-notification-selftest")
        fixture = Self.value(after: "-fixture", in: arguments)
        route = Self.value(after: "-route", in: arguments)
        extensionsSection = Self.value(after: "-extensions-section", in: arguments)
        extensionsQuery = Self.value(after: "-extensions-query", in: arguments)
        extensionsExpand = Self.value(after: "-extensions-expand", in: arguments)
        extensionsAction = Self.value(after: "-extensions-action", in: arguments)
        projectArea = Self.value(after: "-project-area", in: arguments)
        testsRun = isUITesting ? Self.value(after: "-tests-run", in: arguments) : nil
        testsStep = isUITesting ? Self.value(after: "-tests-step", in: arguments) : nil
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
        if handoffAgentStub {
            writeHandoffStub(into: root)
        }
    }

    /// Where the handoff's stub agent lives, when it was asked for.
    var handoffStubPath: String? {
        guard handoffAgentStub, let root = dataDirectoryOverride else { return nil }
        return root.appendingPathComponent("handoff-agent-stub.sh").path
    }

    /// A script that answers exactly the way a logged-in `claude -p` does:
    /// reads the prompt from stdin, prints an envelope whose `result` carries
    /// the handover JSON. Everything downstream of the executable — the shell
    /// invocation, the parsing, the merge, the wording shown to the user — is
    /// the production path.
    private func writeHandoffStub(into root: URL) {
        let handover = #"{\"objective\": \"Finish the demo feature\", \"workDone\": [\"wrote the parser\"], \"decisions\": [\"kept the tolerant reader\"], \"openItems\": [\"wire the UI\"], \"knownProblems\": [\"the first approach deadlocked\"], \"suggestedNextStep\": \"run the tests\"}"#
        let script = """
        #!/bin/sh
        cat - > /dev/null
        printf '%s' '{"result": "\(handover)", "is_error": false}'
        """
        let url = root.appendingPathComponent("handoff-agent-stub.sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
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
                id: "stream", name: "Streaming suite", command: "sh stream-tests.sh",
                framework: .swift,
                notes: "prints XCTest-shaped lines slowly, so the live view has something to show"
            ),
            TestSuiteConfiguration(
                id: "e2e", name: "End-to-end flows",
                command: "maestro test .maestro --debug-output build/screenshots",
                framework: .maestro,
                notes: "a Maestro flow, the way a mobile or web end-to-end suite reports",
                artifacts: "build/screenshots"
            ),
        ], projectRoot: projectDir)
        let shot = Self.seedFixtureScreenshot(projectRoot: projectDir)
        Self.seedFixtureStreamingSuite(projectRoot: projectDir)
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
                        outcome: .failed, duration: 0.184,
                        message: "XCTAssertEqual failed: (\"2\") is not equal to (\"3\")"
                    ),
                    TestCaseResult(
                        suite: "DockerStatusTests", name: "testEmptyOutputIsNoContainers",
                        outcome: .failed, duration: 0.021,
                        message: "XCTAssertTrue failed — the parser read a blank line as a container"
                    ),
                    TestCaseResult(
                        suite: "TodoParserTests", name: "testFrontmatterIsRead",
                        outcome: .passed, duration: 0.003
                    ),
                    TestCaseResult(
                        suite: "HandoffTests", name: "testPromptIsBuilt",
                        outcome: .passed, duration: 0.012
                    ),
                    TestCaseResult(
                        suite: "UsageAttentionTests", name: "testAnAccountIsWarnedOnce",
                        outcome: .skipped
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
                summary: TestRunSummary(passed: 5, failed: 1, isDetailed: true),
                cases: [
                    TestCaseResult(
                        suite: "smoke", name: "Launch app \"com.example.app\"", outcome: .passed
                    ),
                    TestCaseResult(
                        suite: "smoke", name: "Tap on \"Sign in\"", outcome: .passed
                    ),
                    TestCaseResult(
                        suite: "smoke", name: "Take screenshot smoke-01-home",
                        outcome: .passed, artifacts: shot.map { [$0] } ?? []
                    ),
                    TestCaseResult(
                        suite: "smoke", name: "Assert that \"Welcome back\" is visible",
                        outcome: .failed,
                        message: "Assertion is false: \"Welcome back\" is visible"
                    ),
                    TestCaseResult(
                        suite: "checkout", name: "Open https://example.com", outcome: .passed
                    ),
                    TestCaseResult(
                        suite: "checkout", name: "Tap on \"Buy\"", outcome: .passed
                    ),
                ],
                logTail: "Running on iPhone 16 Pro\n"
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

    /// A suite that actually runs, and takes long enough to be watched.
    ///
    /// The Tests screen's other two fixtures are results without runs — enough
    /// to show what a finished suite looks like, and no use at all for the part
    /// that streams. This one prints XCTest's own line shape, one test at a
    /// time, so pressing Run shows the steps arriving.
    static func seedFixtureStreamingSuite(projectRoot: URL) {
        let script = """
        #!/bin/sh
        for name in testTheParserReadsFrontmatter testASleepingSessionWakes \
                    testTheQueueDrains testABranchChangeIsAnnounced \
                    testTheCacheSurvivesRestart testNothingIsLostOnCancel; do
          echo "Test Case 'StreamingTests.$name' started."
          sleep 1
          echo "Test Case 'StreamingTests.$name' passed (1.0 seconds)."
        done
        echo "Test Case 'StreamingTests.testTheOneThatBreaks' started."
        sleep 1
        echo "\(projectRoot.lastPathComponent)/Stream.swift:12: error: -[StreamingTests testTheOneThatBreaks] : XCTAssertEqual failed: (\"7\") is not equal to (\"8\")"
        echo "Test Case 'StreamingTests.testTheOneThatBreaks' failed (1.0 seconds)."
        exit 1
        """
        try? script.write(
            to: projectRoot.appendingPathComponent("stream-tests.sh"),
            atomically: true, encoding: .utf8
        )
    }

    /// Writes one small image into the demo project, so the Tests screen has a
    /// real artifact to open rather than a row pointing at nothing.
    ///
    /// Drawn rather than bundled: a fixture image shipped in the app would be
    /// weight every user carries for a screen only a UI test opens.
    static func seedFixtureScreenshot(projectRoot: URL) -> TestArtifact? {
        let directory = projectRoot.appendingPathComponent("build/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("smoke-01-home.png")
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.47, green: 0.34, blue: 0.85, alpha: 1).setFill()
        NSRect(x: 24, y: 200, width: 300, height: 56).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        try? png.write(to: url, options: .atomic)
        return TestArtifact(
            path: url.path, name: url.lastPathComponent, kind: .image, modifiedAt: Date()
        )
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

/// A usage snapshot for `-usage-fixture`, so the chip and its card can be
/// inspected without a subscription, a login, or the network.
///
/// Applied by `UsageStore` as it is built, not from a view. Seeding it from
/// `onAppear` cost a morning: mutating the store while the first window is
/// being assembled leaves the app running with no window at all — no crash, no
/// log, nothing to search for.
///
/// The account is deliberately in trouble. The state this whole feature exists
/// for is the one hardest to reach on purpose, and a picture of a healthy
/// account proves the least. The windows also disagree with one another — a
/// comfortable session, a tight week, an exhausted model — because "which limit
/// binds first" is the question the card answers, and a uniform fixture would
/// never show it being answered.
enum UsageFixture {
    static func snapshot(now: Date, provider: AgentProvider = .claude) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            identity: UsageIdentity(email: "you@example.com", plan: "Max", organization: nil),
            primaryWindow: UsageWindow(
                id: "fixture.session", title: "Session limit", usedPercent: 34,
                resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), windowMinutes: 300
            ),
            secondaryWindow: UsageWindow(
                id: "fixture.week", title: "Weekly limit", usedPercent: 78,
                resetsAt: now.addingTimeInterval(3 * 86_400), windowMinutes: 10080
            ),
            extraWindows: [
                UsageWindow(
                    id: "fixture.opus", title: "Weekly limit · Opus", usedPercent: 92,
                    resetsAt: now.addingTimeInterval(3 * 86_400), modelID: "opus"
                ),
            ],
            credits: UsageCredits(balance: 12.5, currency: "USD", summary: nil),
            source: .claudeOAuthAPI,
            updatedAt: now.addingTimeInterval(-140)
        )
    }

    static let key = UsageKey(provider: .claude, accountID: nil)
}

/// Animation helper honoring -disable-animations.
func uncoilAnimation(_ animation: Animation?) -> Animation? {
    LaunchConfig.shared.disableAnimations ? nil : animation
}
