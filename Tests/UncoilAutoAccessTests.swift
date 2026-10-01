import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Uncoil

/// Which agents a conversation may reach, and what applying an effort does,
/// with the app replaced by the same recording environment as the
/// conversation's other rules.
@MainActor
extension UncoilAutoSessionTests {
    func notices(_ session: UncoilAutoSession) -> [String] {
        hub.timeline(for: session.sessionID)?.notices.map(\.message) ?? []
    }

    func testAnAgentClosedToTheConversationIsNotSentAnything() async {
        let recorder = Recorder()
        recorder.blocked = [.claude]
        let session = makeSession(recorder)
        await session.submit("@claude @codex fix the flaky test")

        XCTAssertEqual(recorder.delivered.map(\.1), [codex], "only the open agent gets the prompt")
        XCTAssertTrue(notices(session).contains { $0.contains("@claude is not open to Uncoil Auto") })
    }

    func testAClosedAgentIsNotStartedEither() async {
        let recorder = Recorder()
        recorder.blocked = [.gemini]
        let session = makeSession(recorder)
        await session.submit("@gemini hello")
        await session.submit("/new gemini")

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(recorder.delivered.isEmpty)
    }

    func testAgentsListsOnlyTheOpenOnes() async {
        let recorder = Recorder()
        recorder.blocked = [.codex]
        let session = makeSession(recorder)
        await session.submit("/agents")
        let listing = notices(session).last ?? ""
        XCTAssertTrue(listing.contains("@claude"))
        XCTAssertFalse(listing.contains("@codex"))
    }

    func testApplyingAnEffortSendsTheAgentsOwnCommandQuietly() async throws {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        let entry = try XCTUnwrap(recorder.roster.first { $0.handle == "claude" })
        let item = EffortSuggestionItem(entry: entry, suggestion: suggestion("low", for: .claude), application: .command)
        conversation.publish([item])

        await conversation.apply(item)
        XCTAssertEqual(recorder.commands.map(\.0), ["/effort low"])
        XCTAssertEqual(recorder.commands.map(\.1), [claude])
        XCTAssertTrue(recorder.delivered.isEmpty, "the command does not go the way a prompt goes, so it names nothing")
        XCTAssertEqual(conversation.appliedEffort[claude], "low")
        XCTAssertEqual(conversation.suggestions.first?.suggestion.isChange, false)

        // Claude's transcript echoes the command; it is ours, not the user's.
        let before = items(session).count
        transcripts.publish(.itemCompleted(AgentItem(id: "e", kind: .userMessage(text: "/effort low", attachments: []), status: .completed, native: nil)), sessionID: claude, provider: .claude)
        XCTAssertEqual(items(session).count, before)
    }

    func testAnEffortChosenBeforeTheAgentStartsIsItsLaunchEffort() async throws {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        let entry = try XCTUnwrap(recorder.roster.first { $0.handle == "gemini" })
        await conversation.apply(EffortSuggestionItem(entry: entry, suggestion: suggestion("high", for: .gemini), application: .atLaunch))

        await session.submit("@gemini plan the migration")
        XCTAssertEqual(recorder.started, [.gemini])
        XCTAssertEqual(recorder.startedEfforts, ["high"])
        XCTAssertNil(conversation.takeLaunchEffort(for: .gemini), "taken once")
    }

    func testASentPromptAndHowItsTurnWentAreLogged() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decisions-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        recorder.log = EffortDecisionLog(url: url)
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        let entry = try XCTUnwrap(recorder.roster.first { $0.handle == "claude" })
        conversation.publish(
            [EffortSuggestionItem(entry: entry, suggestion: suggestion("low", for: .claude), application: .command)])

        await session.submit("@claude fix the typo")
        transcripts.publish(.turnCompleted(turnID: nil, outcome: .completed), sessionID: claude, provider: .claude)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(#""kind":"decision""#))
        XCTAssertTrue(lines[0].contains(#""prompt":"fix the typo""#))
        XCTAssertTrue(lines[0].contains(#""suggested":"low""#))
        XCTAssertTrue(lines[1].contains(#""kind":"outcome""#))
        XCTAssertTrue(lines[1].contains(#""result":"completed""#))
    }

    func testNothingIsLoggedWhileTheLogIsOff() async throws {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        let entry = try XCTUnwrap(recorder.roster.first { $0.handle == "claude" })
        conversation.publish(
            [EffortSuggestionItem(entry: entry, suggestion: suggestion("low", for: .claude), application: .command)])
        await session.submit("@claude fix the typo")
        XCTAssertEqual(recorder.delivered.count, 1, "sending is unaffected")
    }

    func testTheConversationsNarrowingAndEffortsSurviveARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let first = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, store: UncoilAutoStore(url: url, delay: 0), conversation: first)
        let entry = try XCTUnwrap(recorder.roster.first { $0.handle == "claude" })
        await session.submit("@claude hi")
        first.setExcluded(.codex, true)
        await first.apply(EffortSuggestionItem(entry: entry, suggestion: suggestion("medium", for: .claude), application: .command))
        session.stop(terminateServer: false)

        let second = UncoilAutoConversationState(sessionID: UUID())
        let relaunched = makeSession(Recorder(), store: UncoilAutoStore(url: url, delay: 0), conversation: second)
        relaunched.start()
        XCTAssertEqual(second.excludedAgents, ["codex"])
        XCTAssertEqual(second.appliedEffort[claude], "medium")
    }

    func testAFileWrittenBeforeTheseFieldsStillLoads() throws {
        let old = #"{"version":1,"events":[],"participants":[]}"#
        let saved = try JSONDecoder().decode(UncoilAutoStore.Saved.self, from: Data(old.utf8))
        XCTAssertNil(saved.excludedAgents)
        XCTAssertNil(saved.appliedEffort)
    }

    func testSettingsSetTheCeilingAndAConversationOnlyNarrowsIt() {
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        var settings = UncoilAutoSettings.default
        settings.allowedAgents = ["claude"]
        XCTAssertTrue(conversation.allows(.claude, settings: settings))
        XCTAssertFalse(conversation.allows(.codex, settings: settings))
        conversation.setExcluded(.codex, false)
        XCTAssertFalse(conversation.allows(.codex, settings: settings), "a conversation cannot widen Settings")
        conversation.setExcluded(.claude, true)
        XCTAssertFalse(conversation.allows(.claude, settings: settings))
    }

    private func suggestion(_ level: String, for provider: AgentProvider) -> EffortSuggestion {
        EffortSuggestion(
            provider: provider, level: level, confidence: 0.8, reasons: [],
            features: HeuristicEffortAdvisor.read(EffortContext(prompt: "fix the typo", provider: provider)),
            current: nil)
    }
}

/// Where a message naming nobody goes, and the target that keeps it there.
@MainActor
extension UncoilAutoSessionTests {
    func testAMessageNamingNobodyGoesToTheNewestAgentAndStaysThere() async {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("what is in the README?")
        XCTAssertEqual(recorder.delivered.map(\.1), [codex], "the newest running agent")
        XCTAssertEqual(conversation.target, "codex", "and the first send pins it")

        // A newer session does not take the conversation over.
        recorder.roster.append(.init(handle: "claude-2", provider: .claude, sessionID: UUID(), title: "new"))
        await session.submit("and the CHANGELOG?")
        XCTAssertEqual(recorder.delivered.last?.1, codex)
    }

    func testAMentionSendsElsewhereWithoutMovingTheTarget() async {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        conversation.target = "claude"
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("@codex review this")
        await session.submit("now fix it")
        XCTAssertEqual(recorder.delivered.map(\.1), [codex, claude])
        XCTAssertEqual(conversation.target, "claude")
    }

    func testAnAgentCommandWithoutAMentionGoesToTheTarget() async {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        conversation.target = "claude"
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("/compact")
        XCTAssertEqual(recorder.delivered.map(\.0), ["/compact"])
        XCTAssertEqual(recorder.delivered.map(\.1), [claude])
    }

    func testRoutingFallsBackWhenTheChosenAgentIsGone() {
        let claude = UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: UUID(), title: "")
        let codex = UncoilAutoRoster.Entry(handle: "codex", provider: .codex, sessionID: UUID(), title: "")
        let gemini = UncoilAutoRoster.Entry(handle: "gemini", provider: .gemini, sessionID: nil, title: "")
        let all: (AgentProvider) -> Bool = { _ in true }
        XCTAssertEqual(UncoilAutoRouting.target(chosen: "claude", roster: [claude, codex], allows: all)?.handle, "claude")
        XCTAssertEqual(UncoilAutoRouting.target(chosen: "claude-9", roster: [claude, codex], allows: all)?.handle, "codex")
        XCTAssertEqual(UncoilAutoRouting.target(chosen: "claude", roster: [claude, codex], allows: { $0 != .claude })?.handle,
                       "codex", "a target closed to the conversation is not used")
        XCTAssertEqual(UncoilAutoRouting.target(chosen: nil, roster: [gemini], allows: all)?.handle, "gemini",
                       "the one agent there is, even before it has a session")
        XCTAssertNil(UncoilAutoRouting.target(chosen: nil, roster: [gemini, .init(handle: "codex", provider: .codex, sessionID: nil, title: "")], allows: all))
    }

    func testTheTargetSurvivesARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(Recorder(), store: UncoilAutoStore(url: url, delay: 0), conversation: first)
        first.target = "claude"
        session.stop(terminateServer: false)
        let second = UncoilAutoConversationState(sessionID: UUID())
        makeSession(Recorder(), store: UncoilAutoStore(url: url, delay: 0), conversation: second).start()
        XCTAssertEqual(second.target, "claude")
    }

    // MARK: - Notifications

    func testTheConversationKnowsWhichAgentsItDirectsUntilItStops() async {
        let recorder = Recorder()
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("@claude hi")
        XCTAssertEqual(conversation.participants, [claude])
        session.stop(terminateServer: false)
        XCTAssertTrue(conversation.participants.isEmpty, "a stopped conversation directs nobody")
    }

    func testOnlyDirectedAgentsAreEverMuted() {
        let conversation = UUID()
        func mutes(_ event: NotificationEvent, _ mode: DirectedAgentNotifications,
                   directed: Bool = true, visible: UUID? = nil, active: Bool = true) -> Bool {
            DirectedAgentNotifications.mutes(
                event, mode: mode, directors: directed ? [conversation] : [],
                visibleSessionID: visible, appIsActive: active)
        }
        for mode in DirectedAgentNotifications.allCases {
            XCTAssertFalse(mutes(.input, mode, directed: false, visible: conversation), "a native session is never touched")
        }
        XCTAssertFalse(mutes(.input, .asUsual, visible: conversation))

        XCTAssertTrue(mutes(.input, .whenConversationHidden, visible: conversation))
        XCTAssertTrue(mutes(.permission, .whenConversationHidden, visible: conversation))
        XCTAssertFalse(mutes(.input, .whenConversationHidden, visible: UUID()))
        XCTAssertFalse(mutes(.input, .whenConversationHidden, visible: conversation, active: false),
                       "on screen means Uncoil is in front, too")

        XCTAssertTrue(mutes(.input, .permissionsOnly))
        XCTAssertTrue(mutes(.turnCompleted, .permissionsOnly))
        XCTAssertFalse(mutes(.permission, .permissionsOnly), "the one thing the conversation cannot answer")
        XCTAssertTrue(mutes(.permission, .permissionsOnly, visible: conversation))
        XCTAssertFalse(mutes(.loginRequired, .permissionsOnly), "events the conversation does not show are left alone")
    }

    func testADirectedAgentsNotificationIsSkippedBeforeThePolicy() {
        let store = SessionStore()
        let directed = UUID()
        store.directedNotificationFilter = { id, _ in id == directed }
        let decision = store.notify(
            .input, title: "p", body: "b", projectID: UUID(), sessionID: directed, prefs: NotificationPrefs())
        XCTAssertEqual(decision, .skip(.directedByUncoilAuto))
    }

    func testSettingsWrittenBeforeAFieldExistedStillLoad() throws {
        let old = try JSONDecoder().decode(UncoilAutoSettings.self, from: Data(#"{"allowedAgents":["claude"]}"#.utf8))
        XCTAssertEqual(old.allowedAgents, ["claude"])
        XCTAssertEqual(old.notifications, .whenConversationHidden)
        XCTAssertEqual(old.advisor, EffortAdvisorSettings())

        let partial = try JSONDecoder().decode(
            UncoilAutoSettings.self,
            from: Data(#"{"advisor":{"enabled":false,"perAgent":{"claude":{"maximum":"high"}}},"notifications":"somethingNew"}"#.utf8))
        XCTAssertFalse(partial.advisor.enabled)
        XCTAssertEqual(partial.advisor.policy(for: .claude), AgentEffortPolicy(maximum: "high"))
        XCTAssertEqual(partial.notifications, .whenConversationHidden, "an unknown value falls back rather than failing the file")
    }

    // MARK: - Composer

    func testTheComposerOffersNoWritingTools() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Writing Tools needs macOS 15") }
        let model = AgentChatModel(sessionID: UUID(), hub: AgentEventHub(), actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in true }, isReady: { true }))
        let host = NSHostingView(rootView: ChatComposer(model: model, placeholder: "").frame(width: 600, height: 80))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
        host.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let field = try XCTUnwrap(textViews(in: host).first)
        XCTAssertEqual(field.writingToolsBehavior, .none)
        let scroller = field.enclosingScrollView?.verticalScroller
        XCTAssertTrue(scroller is UncoilScroller, "the composer uses Uncoil's scroller")
    }
}

/// Typing must stay smooth: readings that change nothing visible redraw
/// nothing, chips stay put while the next reading is made, and what a send
/// logs is not lost to the field clearing.
@MainActor
final class EffortSuggestionFlowTests: XCTestCase {
    let entry = UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: UUID(), title: "")

    func item(_ level: String, confidence: Double = 0.8) -> EffortSuggestionItem {
        EffortSuggestionItem(
            entry: entry,
            suggestion: EffortSuggestion(
                provider: .claude, level: level, confidence: confidence, reasons: [],
                features: HeuristicEffortAdvisor.read(EffortContext(prompt: "x", provider: .claude)), current: nil),
            application: .command)
    }

    func testAReadingThatLooksTheSameDoesNotRedraw() {
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        var redraws = 0
        let watch = conversation.$suggestions.dropFirst().sink { _ in redraws += 1 }
        defer { watch.cancel() }

        conversation.publish([item("low", confidence: 0.81)])
        conversation.publish([item("low", confidence: 0.83)])
        conversation.publish([item("low", confidence: 0.84)])
        XCTAssertEqual(redraws, 1, "confidence moving within 5% is not worth a redraw")
        XCTAssertEqual(conversation.standing.first?.suggestion.confidence, 0.84, "but the latest reading is kept for the log")

        conversation.publish([item("high")])
        XCTAssertEqual(redraws, 2, "a different level is")
    }

    func testClearingTheFieldHidesTheChipsButKeepsWhatASendLogs() {
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        conversation.publish([item("low")])
        conversation.hide()
        XCTAssertTrue(conversation.suggestions.isEmpty)
        XCTAssertEqual(conversation.takeStanding().map(\.suggestion.level), ["low"])
        XCTAssertTrue(conversation.takeStanding().isEmpty, "a reading is logged with one prompt only")
    }

    func testWhitespaceAloneIsNotANewPrompt() {
        XCTAssertEqual(EffortSuggestionModel.folded("fix  the\n typo "), EffortSuggestionModel.folded("fix the typo"))
        XCTAssertNotEqual(EffortSuggestionModel.folded("fix the typo"), EffortSuggestionModel.folded("fix the typos"))
    }
}
