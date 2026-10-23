import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders a chat transcript offscreen, the way `SleepingSessionRenderTests`
/// renders its screens: spacing, hierarchy and colour are things to look at,
/// not to assert about. Set `UNCOIL_CHAT_SAMPLE_DIR` to write the PNGs.
@MainActor
final class AgentChatRenderTests: XCTestCase {
    private struct Sampler: View {
        let model: AgentChatModel

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        AgentChatRowView(row: row, model: model, provider: .claude)
                    }
                }
                .frame(maxWidth: AgentChatView.columnWidth)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                ChatComposer(model: model, placeholder: "Message your agents — @ to choose one, / for commands")
                    .frame(maxWidth: AgentChatView.columnWidth + 24)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 12)
            .background(Theme.bg)
        }
    }

    private func write(_ model: AgentChatModel, name: String, height: CGFloat, to directory: String) throws {
        let host = NSHostingView(rootView: Sampler(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        host.layoutSubtreeIfNeeded()
        // The composer measures its text a hop after layout, as it does on screen.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    func testTheTranscriptRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_CHAT_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_CHAT_SAMPLE_DIR to write the chat samples")
        }
        let hub = AgentEventHub()
        let id = UUID()
        hub.publish(.historyLoaded(FixtureAgentSession.history), sessionID: id, provider: .claude)
        hub.publish(.turnCompleted(turnID: "h", outcome: .failed("The model is overloaded. Try again in a moment.")), sessionID: id, provider: .claude)
        hub.publish(.turnStarted(turnID: "t"), sessionID: id, provider: .claude)
        hub.publish(.itemStarted(AgentItem(id: "c", kind: .command(command: "xcodebuild -scheme Uncoil test", output: "Test Suite 'All tests' started\nTest Case 'SidebarRowReloadTests.testReload' passed (0.012 seconds)\n", exitCode: nil), status: .inProgress, native: nil)), sessionID: id, provider: .claude)
        hub.publish(.itemStarted(AgentItem(id: "e", kind: .fileChange([AgentFileChange(path: "App/UI/Sidebar.swift", kind: .update, diff: "-old\n+new")]), status: .inProgress, native: nil)), sessionID: id, provider: .claude)
        hub.publish(.approvalRequested(AgentApproval(id: "a", kind: .fileChange, title: "Edit App/UI/Sidebar.swift", detail: "Replaces the reload call.", decisions: ["accept", "acceptForSession", "decline"], native: nil)), sessionID: id, provider: .claude)
        let model = AgentChatModel(sessionID: id, hub: hub, actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        model.itemModel(for: "h-edit-1")?.isExpanded = true
        model.itemModel(for: "h-cmd-2")?.isExpanded = true
        model.itemModel(for: "h-thought-1")?.isExpanded = true
        try write(model, name: "chat-transcript.png", height: 1900, to: directory)

        // Uncoil Auto directing two agents: who said what, and the popup.
        let auto = UUID()
        let claude = AgentItemSource(sessionID: UUID(), provider: .claude, handle: "claude")
        let codex = AgentItemSource(sessionID: UUID(), provider: .codex, handle: "codex")
        func said(_ id: String, _ kind: AgentItemKind, _ source: AgentItemSource?, to: [AgentItemSource]? = nil) {
            hub.publish(.itemCompleted(AgentItem(id: id, kind: kind, status: .completed, native: nil, source: source, recipients: to)), sessionID: auto, provider: .uncoil)
        }
        said("p1", .userMessage(text: "@claude fix the flaky sidebar test", attachments: []), nil, to: [claude])
        said("c1", .command(command: "xcodebuild test -only-testing:UncoilTests/SidebarRowReloadTests", output: "", exitCode: 0), claude)
        said("c2", .fileChange([AgentFileChange(path: "App/UI/Sidebar.swift", kind: .update, diff: "-old\n+new")]), claude)
        said("c3", .agentMessage(text: "Fixed: the row reloaded twice. The test passes now."), claude)
        said("p2", .userMessage(text: "@codex review this", attachments: []), nil, to: [codex])
        hub.publish(.notice(AgentNotice(level: .info, message: "Included @claude's last reply for @codex.")), sessionID: auto, provider: .uncoil)
        said("x1", .reasoning(summary: "**Checking the change.** One call site, one test."), codex)
        said("x2", .agentMessage(text: "Looks right. One nit: `reloadRow` could be `private`."), codex)
        said("p3", .userMessage(text: "@claude /model sonnet", attachments: []), nil, to: [claude])
        said("c4", .command(command: "cd \"/Users/me/Library/Application Support/Uncoil/scratch\" && find . -type f -not -path '*/node_modules*' | head -100", output: "./README.md", exitCode: 0), claude)
        said("c5", .command(command: "/model sonnet", output: "Set model to Sonnet 5 and saved as your default for new sessions", exitCode: nil), claude)
        said("p4", .userMessage(text: "@codex /model", attachments: []), nil, to: [codex])
        hub.publish(.notice(AgentNotice(level: .info, message: "/model answers in @codex's own terminal.", action: .openTerminal(sessionID: codex.sessionID, handle: "codex"))), sessionID: auto, provider: .uncoil)
        let multi = AgentChatModel(sessionID: auto, hub: hub, actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        let roster = [
            UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: claude.sessionID, title: "fix sidebar"),
            UncoilAutoRoster.Entry(handle: "codex", provider: .codex, sessionID: codex.sessionID, title: "review"),
        ]
        multi.suggestionProvider = { UncoilAutoCompletions.suggestions(for: $0, roster: roster) }
        multi.draft = "@c"
        multi.updateCompletion(cursor: 2)
        try write(multi, name: "chat-multi-agent.png", height: 1150, to: directory)

        let empty = AgentChatModel(sessionID: UUID(), hub: hub, actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        empty.draft = "Run the sidebar tests through xcodebuild,\nthen tell me what failed."
        try write(empty, name: "chat-composer.png", height: 200, to: directory)
    }
}

/// The agents panel beside Uncoil Auto, with real stores behind it.
@MainActor
final class UncoilAutoPanelRenderTests: XCTestCase {
    func testThePanelRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_CHAT_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_CHAT_SAMPLE_DIR to write the chat samples")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = ProjectStore(directory: root)
        let project = try XCTUnwrap(projects.addProject(at: root.appendingPathComponent("repo")))
        let claude = projects.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "claude: fix the sidebar flicker")
        let codex = projects.createSession(projectID: project.id, provider: .codex, accountID: nil, title: "codex: review")
        let sessions = SessionStore()
        sessions.setStatus(.running, detail: "Running a command", for: claude.id)
        sessions.setStatus(.idle, for: codex.id)
        let usage = UsageStore(providers: [])
        usage.seed(UsageFixture.snapshot(now: Date()), for: UsageKey(provider: .claude, accountID: nil))
        let settings = SettingsStore(directory: root)

        let auto = projects.createSession(projectID: project.id, provider: .uncoil, accountID: nil, title: "uncoil: new session")
        let header = NSHostingView(rootView:
            SessionHeaderBar(record: auto, project: project, leadingIcon: "chevron.left", leadingHelp: "", onLeading: {}, onRestart: {})
                .padding(12)
                .frame(width: 900)
                .background(Theme.bg)
                .environmentObject(projects)
                .environmentObject(sessions)
                .environmentObject(settings)
                .environmentObject(usage)
        )
        header.frame = NSRect(x: 0, y: 0, width: 900, height: 90)
        header.layoutSubtreeIfNeeded()
        let headerRep = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: headerRep)
        try XCTUnwrap(headerRep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat-auto-header.png"))

        let host = NSHostingView(rootView:
            UncoilAutoAgentsPanel(projectID: project.id, conversation: UncoilAutoConversationState(sessionID: UUID()), onStart: { _ in }, onMention: { _ in })
                .frame(height: 420)
                .environmentObject(projects)
                .environmentObject(sessions)
                .environmentObject(settings)
                .environmentObject(usage)
        )
        host.frame = NSRect(x: 0, y: 0, width: UncoilAutoAgentsPanel.width, height: 420)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat-agents-panel.png"))
    }
}

/// Uncoil Auto's surfaces: the composer's target button, the run as the
/// conversation shows it, its diagnostics, and the settings areas.
@MainActor
final class UncoilAutoRenderTests: XCTestCase {
    private func render(_ view: some View, size: NSSize, name: String, to directory: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.bg))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// A run that went through every kind of step.
    static func sampleRun() -> AutoRun {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var run = AutoRun(task: "Add a retry budget to the upload client and cover it with tests", startedAt: start)
        run.participants = [
            AutoParticipant(sessionID: UUID(), role: "main", provider: .claude, handle: "claude", model: "opus", effort: "high", state: .idle),
            AutoParticipant(sessionID: UUID(), role: "explorer", provider: .claude, handle: "explorer", model: "sonnet", effort: "medium", state: .done),
            AutoParticipant(sessionID: UUID(), role: "worker", provider: .codex, handle: "worker", model: "gpt-5-codex", effort: "medium",
                            worktreePath: "/repo/.uncoil-worktrees/auto-worker-1a2b3c", state: .working),
            AutoParticipant(sessionID: UUID(), role: "advisor", provider: .claude, handle: "advisor", model: "fable", state: .done),
        ]
        var at = start
        func log(_ kind: AutoRunEvent.Kind, _ title: String, _ detail: String? = nil) {
            at = at.addingTimeInterval(37)
            run.log(kind, title, detail: detail, at: at)
        }
        log(.phase, "Exploring the project…")
        log(.session, "Explorer · Claude · sonnet · medium started", "Directory: /repo")
        log(.handoff, "Explorer returned a structured result", "UploadClient.swift holds the retry loop.")
        log(.phase, "Planning…")
        log(.advisor, "Advisor checkpoint: pre_plan")
        log(.phase, "Implementing…")
        log(.verification, "Verification failed", "swift test: exit 1")
        log(.decision, "Failure triage: retry", "Deterministic: retry\nAuthority: shadow")
        log(.policy, "Decision overridden: escalate_to_advisor", "the same failure 2 times")
        run.record(AutoDecisionRecord(
            date: at, kind: .failureTriage, question: AutoDecisionKind.failureTriage.schema.question,
            options: AutoDecisionKind.failureTriage.schema.optionIDs, state: "Task: …\nVerdict: failed",
            authority: .shadow,
            answer: AutoDecisionAnswer(choice: "escalate_to_advisor",
                                       probabilities: ["retry": 0.21, "return_to_main": 0.08, "escalate_to_advisor": 0.71],
                                       confidence: 0.62, model: "laya", latencyMilliseconds: 41),
            deterministic: "retry", action: "retry"))
        run.verifications = [AutoVerificationRecord(
            attempt: 1, date: at, verdict: .failed, claimedStatus: "done", turnOutcome: "completed",
            suites: [.init(name: "swift test", command: "swift test", exitCode: 1, timedOut: false,
                           outputTail: "UploadClientTests.testRetryBudget: XCTAssertEqual failed: (\"3\") is not equal to (\"2\")")],
            changedFiles: ["Sources/UploadClient.swift"], workerCommands: ["swift build → exit 0"], signature: "a1b2c3d4e5f6")]
        run.phase = .implementing
        return run
    }

    func testTheRunAndTheSettingsRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_CHAT_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_CHAT_SAMPLE_DIR to write the chat samples")
        }
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        conversation.update(Self.sampleRun())

        // The composer with the run strip above it and the target button beside the field.
        let chat = AgentChatModel(sessionID: UUID(), hub: AgentEventHub(), actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        let target = UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: UUID(), title: "fix")
        try render(
            VStack(spacing: 4) {
                Spacer()
                AutoRunStrip(conversation: conversation, projectID: UUID())
                ChatComposer(
                    model: chat, placeholder: "Message @claude — /auto for an Auto run, @ for another agent",
                    leading: AnyView(UncoilAutoTargetPicker(conversation: conversation, roster: [target], resolved: target)))
            }
            .padding(16)
            .environmentObject(SessionStore()),
            size: NSSize(width: 820, height: 170), name: "auto-composer.png", to: directory)

        try render(
            AutoRunPanelSection(conversation: conversation, onOpen: { _ in })
                .padding(8)
                .frame(width: UncoilAutoAgentsPanel.width, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.sidebarSurface),
            size: NSSize(width: UncoilAutoAgentsPanel.width, height: 300), name: "auto-panel.png", to: directory)

        try render(
            AutoRunDiagnosticsView(conversation: conversation),
            size: NSSize(width: 820, height: 1100), name: "auto-diagnostics.png", to: directory)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // Installed agents are what the page lists: seed them the way
        // detection records them, with the real CLIs where they exist so the
        // model and effort lists are read from their own --help.
        SettingsStore(directory: root).save()
        let file = root.appendingPathComponent("settings.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["resolvedBinaries"] = [
            "claude": AgentAdapterSupport.locateBinary("claude") ?? "/usr/bin/true",
            "codex": AgentAdapterSupport.locateBinary("codex") ?? "/usr/bin/true",
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let settings = SettingsStore(directory: root)
        settings.updateAutoHarness {
            $0.roles[.worker]?.provider = .codex
            $0.roles[.worker]?.model = nil
            $0.roles[.worker]?.effort = "high"
        }
        for area in UncoilAutoSettingsPage.Area.allCases {
            let page = UncoilAutoSettingsPage(back: {}, area: area).environmentObject(settings)
            // The lists are read from the CLIs asynchronously; give them a moment.
            let warm = NSHostingView(rootView: page)
            warm.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
            RunLoop.main.run(until: Date().addingTimeInterval(area == .roles ? 3 : 0.5))
            try render(page, size: NSSize(width: 720, height: 1800), name: "auto-settings-\(area.rawValue).png", to: directory)
        }
    }
}
