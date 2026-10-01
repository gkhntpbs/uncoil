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

/// The effort advisor's two surfaces: the chips above the composer, and its
/// settings page.
@MainActor
final class EffortAdvisorRenderTests: XCTestCase {
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

    func testTheSuggestionsAndTheSettingsPageRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_CHAT_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_CHAT_SAMPLE_DIR to write the chat samples")
        }
        let draft = "@claude @codex @gemini fix the typo in the README"
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        func item(_ handle: String, _ provider: AgentProvider, started: Bool, level: String, current: String?,
                  application: EffortSuggestionItem.Application) -> EffortSuggestionItem {
            let features = HeuristicEffortAdvisor.read(EffortContext(prompt: "fix the typo in the README", provider: provider))
            return EffortSuggestionItem(
                entry: .init(handle: handle, provider: provider, sessionID: started ? UUID() : nil, title: ""),
                suggestion: EffortSuggestion(provider: provider, level: level, confidence: 0.82,
                                             reasons: ["reads as trivial"], features: features, current: current),
                application: application)
        }
        conversation.publish([
            item("claude", .claude, started: true, level: "low", current: "high", application: .command),
            item("codex", .codex, started: true, level: "minimal", current: nil, application: .unavailable("at launch")),
            item("gemini", .gemini, started: false, level: "low", current: "low", application: .atLaunch),
        ])
        // Placed the way the conversation places it: floating over the
        // composer's top edge, not in a row of its own.
        let typing = AgentChatModel(sessionID: UUID(), hub: AgentEventHub(), actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        typing.draft = draft
        try render(
            VStack {
                Spacer()
                ChatComposer(model: typing, placeholder: "")
                    .overlay(alignment: .topLeading) {
                        EffortSuggestionBar(conversation: conversation, draft: draft)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 0, alignment: .bottom)
                            .offset(y: -6)
                    }
            }.padding(16),
            size: NSSize(width: 820, height: 150), name: "effort-suggestions.png", to: directory)

        // The composer with Uncoil Auto's target button beside the field.
        let chat = AgentChatModel(sessionID: UUID(), hub: AgentEventHub(), actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        let target = UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: UUID(), title: "fix")
        func composer(_ resolved: UncoilAutoRoster.Entry?, placeholder: String) -> some View {
            ChatComposer(
                model: chat, placeholder: placeholder,
                leading: AnyView(UncoilAutoTargetPicker(conversation: conversation, roster: [target], resolved: resolved)))
                .environmentObject(SessionStore())
        }
        try render(
            VStack(spacing: 14) {
                composer(target, placeholder: "Message @claude — @ for another agent, / for commands")
                composer(nil, placeholder: "Message your agents — @ to choose one, / for commands")
            }.padding(16),
            size: NSSize(width: 820, height: 170), name: "composer-target.png", to: directory)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisor-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // Installed agents are what the page lists: seed them the way
        // detection records them, with the real CLIs where they exist so the
        // effort ladders are read from their own --help.
        SettingsStore(directory: root).save()
        let file = root.appendingPathComponent("settings.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["resolvedBinaries"] = [
            "claude": AgentAdapterSupport.locateBinary("claude") ?? "/usr/bin/true",
            "codex": AgentAdapterSupport.locateBinary("codex") ?? "/usr/bin/true",
            "gemini": "/usr/bin/true",
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let settings = SettingsStore(directory: root)
        settings.setUncoilAutoAllows(.gemini, false)
        settings.updateUncoilAuto {
            $0.advisor.engine = .laya
            $0.advisor.perAgent["claude"] = AgentEffortPolicy(minimum: "low", maximum: "xhigh")
        }
        let page = UncoilAutoSettingsPage(back: {}).environmentObject(settings)
        // The ladders are read from the CLIs asynchronously; give them a moment.
        let warm = NSHostingView(rootView: page)
        warm.frame = NSRect(x: 0, y: 0, width: 720, height: 1600)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        try render(
            page,
            size: NSSize(width: 720, height: 1600), name: "effort-settings.png", to: directory)
    }
}
