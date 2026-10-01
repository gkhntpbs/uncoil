import XCTest
@testable import Uncoil

/// Reading native CLIs' transcripts.
final class NativeTranscriptReaderTests: XCTestCase {
    func testClaudeTranscriptLinesBecomeItems() {
        var reader = ClaudeTranscriptReader()
        let prompt = reader.events(forLine: #"{"type":"user","uuid":"u1","message":{"role":"user","content":"fix the build"}}"#)
        XCTAssertEqual(prompt.last, .itemCompleted(AgentItem(
            id: "u1", kind: .userMessage(text: "fix the build", attachments: []), status: .completed, native: nil)))

        let reply = reader.events(forLine: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it."}]}}"#)
        guard case .itemCompleted(let item)? = reply.first else { return XCTFail("\(reply)") }
        XCTAssertEqual(item.kind, .agentMessage(text: "On it."))

        let tool = reader.events(forLine: #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make"}}]}}"#)
        guard case .itemStarted(let started)? = tool.first else { return XCTFail("\(tool)") }
        XCTAssertEqual(started.kind, .command(command: "make", output: "", exitCode: nil))

        let result = reader.events(forLine: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#)
        guard case .itemCompleted(let finished)? = result.first else { return XCTFail("\(result)") }
        XCTAssertEqual(finished.kind, .command(command: "make", output: "ok", exitCode: nil))

        XCTAssertEqual(reader.events(forLine: #"{"type":"user","isSidechain":true,"message":{"content":"sub"}}"#), [])
        XCTAssertEqual(reader.events(forLine: "not json"), [])
    }

    func testCodexRolloutLinesBecomeItemsAndTurns() {
        var reader = CodexRolloutReader()
        XCTAssertEqual(
            reader.events(forLine: #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#),
            [.turnStarted(turnID: "t1")])
        let command = reader.events(forLine: #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","git status"],"aggregated_output":"clean\n","exit_code":0,"status":"completed"}}}"#)
        guard case .itemCompleted(let item)? = command.first else { return XCTFail("\(command)") }
        XCTAssertEqual(item.kind, .command(command: "git status", output: "clean\n", exitCode: 0))

        let change = reader.events(forLine: #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f1","changes":{"/p/a.ts":{"type":"update","unified_diff":"-a\n+b"}},"status":"completed"}}}"#)
        guard case .itemCompleted(let changed)? = change.first else { return XCTFail("\(change)") }
        XCTAssertEqual(changed.kind, .fileChange([AgentFileChange(path: "/p/a.ts", kind: .update, diff: "-a\n+b")]))

        let message = reader.events(forLine: #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"Done."}],"phase":"final"}}}"#)
        guard case .itemCompleted(let said)? = message.first else { return XCTFail("\(message)") }
        XCTAssertEqual(said.kind, .agentMessage(text: "Done."))

        XCTAssertEqual(
            reader.events(forLine: #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}"#),
            [.turnCompleted(turnID: "t1", outcome: .interrupted)])
        XCTAssertEqual(reader.events(forLine: #"{"type":"response_item","payload":{"type":"message"}}"#), [])
    }

    @MainActor
    func testTheWatcherReadsTheEndAsHistoryAndThenFollows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = { (id: String, text: String) in
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"\#(id)","content":[{"type":"Text","text":"\#(text)"}]}}}"# + "\n"
        }
        try Data(line("m1", "earlier").utf8).write(to: url)
        var events: [AgentEvent] = []
        let watcher = NativeTranscriptWatcher(
            locate: { NativeTranscriptLocation(url: url, provider: .codex) },
            emit: { events.append($0.event) },
            reset: {})
        watcher.poll()
        XCTAssertEqual(events.count, 1)
        guard case .historyLoaded(let history)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(history.map(\.id), ["m1"])

        // A line written in two pieces is read once it is whole.
        let handle = try FileHandle(forWritingTo: url)
        let next = line("m2", "now")
        handle.seekToEndOfFile()
        handle.write(Data(next.prefix(20).utf8))
        watcher.poll()
        XCTAssertEqual(events.count, 1)
        handle.write(Data(next.dropFirst(20).utf8))
        try handle.close()
        watcher.poll()
        guard case .itemCompleted(let item)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(item.kind, .agentMessage(text: "now"))
    }
}

/// What a line typed into Uncoil Auto means, and what the popup offers.
final class UncoilAutoInputTests: XCTestCase {
    private static let project = UUID()

    private static func record(_ provider: AgentProvider, _ minutesAgo: Double) -> SessionRecord {
        var record = SessionRecord(projectID: project, provider: provider, accountID: nil, title: "\(provider.rawValue): work")
        record.createdAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return record
    }

    func testHandlesFollowTheOrderSessionsWereMade() {
        let older = Self.record(.claude, 30), newer = Self.record(.claude, 5), codex = Self.record(.codex, 10)
        let roster = UncoilAutoRoster.entries(sessions: [newer, codex, older], installed: [.claude, .codex, .gemini])
        XCTAssertEqual(roster.map(\.handle), ["claude", "codex", "claude-2", "gemini"])
        XCTAssertEqual(roster[0].sessionID, older.id)
        XCTAssertNil(roster[3].sessionID, "an installed agent with no session is offered, to be started")
        XCTAssertFalse(roster.contains { $0.provider == .terminal || $0.provider == .uncoil })
    }

    func testMessagesCommandsAndAgentCommands() {
        XCTAssertEqual(UncoilAutoInput.parse("@claude fix the build"), .message(text: "fix the build", mentions: ["claude"]))
        XCTAssertEqual(UncoilAutoInput.parse("review this @codex @claude-2"), .message(text: "review this", mentions: ["codex", "claude-2"]))
        XCTAssertEqual(UncoilAutoInput.parse("@claude /compact"), .message(text: "/compact", mentions: ["claude"]))
        XCTAssertEqual(UncoilAutoInput.parse("/new codex add tests"), .command(.new, argument: "codex add tests", mentions: []))
        XCTAssertEqual(UncoilAutoInput.parse("/stop @codex"), .command(.stop, argument: "", mentions: ["codex"]))
        XCTAssertEqual(UncoilAutoInput.parse("/unknown thing"), .message(text: "/unknown thing", mentions: []))
        XCTAssertEqual(UncoilAutoInput.parse("mail me@example.com"), .message(text: "mail me@example.com", mentions: []))
    }

    func testTheWordUnderTheCursorDecidesWhatIsOffered() {
        XCTAssertEqual(ComposerToken.at("@cl", cursor: 3), ComposerToken(kind: .mention, query: "cl", range: NSRange(location: 0, length: 3)))
        XCTAssertEqual(ComposerToken.at("/ne", cursor: 3)?.kind, .command)
        XCTAssertEqual(ComposerToken.at("@claude /com", cursor: 12)?.kind, .agentCommand(handle: "claude"))
        XCTAssertNil(ComposerToken.at("please /com", cursor: 11), "a slash mid-sentence is a path, not a command")
        XCTAssertNil(ComposerToken.at("hello ", cursor: 6))
    }

    func testSuggestionsCompleteTheWord() {
        let roster = UncoilAutoRoster.entries(sessions: [Self.record(.claude, 1)], installed: [.claude, .codex])
        let token = ComposerToken.at("ask @c", cursor: 6)!
        let offered = UncoilAutoCompletions.suggestions(for: token, roster: roster)
        XCTAssertEqual(offered.map(\.insertion), ["@claude", "@codex"])
        let applied = UncoilAutoCompletions.apply(offered[1], to: token, in: "ask @c")
        XCTAssertEqual(applied.text, "ask @codex ")
        XCTAssertEqual(applied.cursor, 11)

        let commands = UncoilAutoCompletions.suggestions(for: ComposerToken.at("/st", cursor: 3)!, roster: roster)
        XCTAssertEqual(commands.map(\.insertion), ["/stop"])
        let native = UncoilAutoCompletions.suggestions(for: ComposerToken.at("@claude /comp", cursor: 13)!, roster: roster)
        XCTAssertEqual(native.map(\.insertion), ["/compact"])
    }

    @MainActor
    func testTheModelDrivesThePopup() {
        let model = AgentChatModel(sessionID: UUID(), hub: AgentEventHub(), actions: AgentChatActions(
            submit: { _ in }, interrupt: {}, respond: { _, _ in false }, isReady: { true }))
        let roster = UncoilAutoRoster.entries(sessions: [Self.record(.claude, 1)], installed: [.claude, .codex])
        model.suggestionProvider = { UncoilAutoCompletions.suggestions(for: $0, roster: roster) }
        model.draft = "@c"
        model.updateCompletion(cursor: 2)
        XCTAssertEqual(model.suggestions.count, 2)
        model.moveSuggestion(by: 1)
        XCTAssertTrue(model.acceptSuggestion())
        XCTAssertEqual(model.draft, "@codex ")
        XCTAssertEqual(model.cursorRequest, 7)
        XCTAssertTrue(model.suggestions.isEmpty)
        model.draft = "plain"
        model.updateCompletion(cursor: 5)
        XCTAssertTrue(model.suggestions.isEmpty)
    }
}

/// The conversation's rules, with the app replaced by a recording environment.
@MainActor
final class UncoilAutoSessionTests: XCTestCase {
    final class Recorder {
        var roster: [UncoilAutoRoster.Entry] = []
        var delivered: [(String, UUID)] = []
        var started: [AgentProvider] = []
        var startedEfforts: [String?] = []
        var commands: [(String, UUID)] = []
        var blocked: Set<AgentProvider> = []
        var log: EffortDecisionLog?
        var interrupted: [UUID] = []
        var working: Set<UUID> = []
        var followed: [UUID] = []
    }

    let claude = UUID()
    let codex = UUID()
    var hub = AgentEventHub()
    var transcripts = AgentEventHub()

    func makeSession(
        _ recorder: Recorder, store: UncoilAutoStore? = nil,
        conversation: UncoilAutoConversationState? = nil
    ) -> UncoilAutoSession {
        recorder.roster = [
            .init(handle: "claude", provider: .claude, sessionID: claude, title: "fix"),
            .init(handle: "codex", provider: .codex, sessionID: codex, title: "review"),
            .init(handle: "gemini", provider: .gemini, sessionID: nil, title: "new"),
        ]
        let environment = UncoilAutoEnvironment(
            roster: { recorder.roster },
            startSession: { provider, effort in
                recorder.started.append(provider)
                recorder.startedEfforts.append(effort)
                let entry = UncoilAutoRoster.Entry(handle: provider.rawValue, provider: provider, sessionID: UUID(), title: "new")
                recorder.roster.removeAll { $0.handle == entry.handle }
                recorder.roster.append(entry)
                return entry
            },
            ensureRunning: { _ in },
            deliver: { text, id, _ in recorder.delivered.append((text, id)) },
            deliverCommand: { text, id, _ in recorder.commands.append((text, id)) },
            allows: { !recorder.blocked.contains($0) },
            decisionLog: { recorder.log },
            interrupt: { recorder.interrupted.append($0) },
            isWorking: { recorder.working.contains($0) },
            follow: { recorder.followed.append($0) },
            unfollow: { _ in }
        )
        let record = SessionRecord(projectID: UUID(), provider: .uncoil, accountID: nil, title: "uncoil: new session")
        return UncoilAutoSession(
            record: record, terminal: nil, environment: environment, store: store, hub: hub, transcripts: transcripts,
            conversation: conversation ?? UncoilAutoConversationState(sessionID: record.id))
    }

    func items(_ session: UncoilAutoSession) -> [AgentItem] {
        hub.timeline(for: session.sessionID)?.items ?? []
    }

    func testAMentionTypesThePromptIntoThatAgentsTerminal() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@claude fix the flaky test")

        XCTAssertEqual(recorder.delivered.map(\.0), ["fix the flaky test"])
        XCTAssertEqual(recorder.delivered.map(\.1), [claude])
        XCTAssertEqual(recorder.followed, [claude])
        XCTAssertEqual(items(session).first?.recipients?.map(\.handle), ["claude"])
    }

    func testAPromptNamingNobodyStaysHereOnlyWhenThereIsNoAgent() async {
        let recorder = Recorder()
        recorder.blocked = [.claude, .codex, .gemini]
        let session = makeSession(recorder)
        await session.submit("what should we do next?")
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertEqual(hub.timeline(for: session.sessionID)?.notices.count, 1)
    }

    func testMentioningAnAgentWithNoSessionStartsOne() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@gemini summarise the README")
        XCTAssertEqual(recorder.started, [.gemini])
        XCTAssertEqual(recorder.delivered.map(\.0), ["summarise the README"])
    }

    func testWhatTheAgentWritesIsMirroredWithWhoSaidIt() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@claude fix the flaky test")

        // The agent's transcript echoes the prompt, then answers.
        transcripts.publish(.itemCompleted(AgentItem(id: "u", kind: .userMessage(text: "fix the flaky test", attachments: []), status: .completed, native: nil)), sessionID: claude, provider: .claude)
        transcripts.publish(.itemCompleted(AgentItem(id: "m", kind: .agentMessage(text: "Fixed."), status: .completed, native: nil)), sessionID: claude, provider: .claude)
        // What it did before joining is not pulled in.
        transcripts.publish(.historyLoaded([AgentItem(id: "old", kind: .agentMessage(text: "old"), status: .completed, native: nil)]), sessionID: claude, provider: .claude)

        let all = items(session)
        XCTAssertEqual(all.count, 2, "the echo of our own prompt is not shown twice")
        XCTAssertEqual(all.last?.kind, .agentMessage(text: "Fixed."))
        XCTAssertEqual(all.last?.source?.handle, "claude")

        let rows = AgentChatTranscript.rows(for: hub.timeline(for: session.sessionID)!)
        XCTAssertEqual(rows.map(\.id).dropFirst(), ["speaker:\(all[1].id)", "item:\(all[1].id)"])
    }

    func testAddressingAnotherAgentHandsItTheLastReply() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@claude fix it")
        transcripts.publish(.itemCompleted(AgentItem(id: "m", kind: .agentMessage(text: "I changed Foo.swift."), status: .completed, native: nil)), sessionID: claude, provider: .claude)

        await session.submit("@codex review this")
        let relayed = recorder.delivered.last
        XCTAssertEqual(relayed?.1, codex)
        XCTAssertTrue(relayed?.0.hasPrefix("review this\n\nFor context, @claude (Claude) replied:") == true)
        XCTAssertTrue(relayed?.0.hasSuffix("I changed Foo.swift.") == true)

        // An agent's own command goes as written, with nothing attached.
        await session.submit("@codex /compact")
        XCTAssertEqual(recorder.delivered.last?.0, "/compact")
    }

    func testStopInterruptsOnlyWorkingAgents() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@claude @codex go")
        recorder.working = [codex]
        session.interrupt()
        XCTAssertEqual(recorder.interrupted, [codex])
        await session.submit("/stop @claude")
        XCTAssertEqual(recorder.interrupted, [codex], "claude was not working")
    }

    func testNewStartsAnAgentAndClearEmptiesTheConversation() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("/new gemini write the changelog")
        XCTAssertEqual(recorder.started, [.gemini])
        XCTAssertEqual(recorder.delivered.map(\.0), ["write the changelog"])

        await session.submit("/clear")
        XCTAssertEqual(items(session), [])
    }

    func testTheConversationSurvivesARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let first = makeSession(recorder, store: UncoilAutoStore(url: url, delay: 0))
        await first.submit("@claude fix it")
        first.stop(terminateServer: true)

        hub = AgentEventHub()
        let second = makeSession(Recorder(), store: UncoilAutoStore(url: url, delay: 0))
        second.start()
        // Same file, a new session object: the record id differs, so compare contents.
        XCTAssertEqual(items(second).map(\.kind), [.userMessage(text: "@claude fix it", attachments: [])])
        XCTAssertEqual(second.participants.values.map(\.handle), ["claude"])
    }
}

/// Claude's tagged user lines, and what the conversation makes of them.
final class ClaudeTranscriptTextTests: XCTestCase {
    func testSlashCommandsAndTheirOutputReadAsThemselves() {
        XCTAssertEqual(
            ClaudeTranscriptText.read("<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>sonnet</command-args>"),
            .prompt("/model sonnet"))
        XCTAssertEqual(
            ClaudeTranscriptText.read("<command-message>doctor</command-message>\n<command-name>/doctor</command-name>"),
            .prompt("/doctor"))
        XCTAssertEqual(
            ClaudeTranscriptText.read("<local-command-stdout>Set model to \u{1B}[1mSonnet 5\u{1B}[22m</local-command-stdout>"),
            .commandOutput("Set model to Sonnet 5"))
        XCTAssertEqual(ClaudeTranscriptText.read("<local-command-caveat>Caveat: …</local-command-caveat>"), .ignored)
    }

    func testShellCommandsPastesAndTaskReports() {
        XCTAssertEqual(ClaudeTranscriptText.read("<bash-input> ls -la</bash-input>"), .shellInput("ls -la"))
        XCTAssertEqual(
            ClaudeTranscriptText.read("<bash-stdout>total 0</bash-stdout><bash-stderr></bash-stderr>"),
            .shellOutput("total 0", failed: false))
        XCTAssertEqual(
            ClaudeTranscriptText.read("<pasted_content id=\"2dd9\">\nAgree?\n\nFor context…\n</pasted_content id=\"2dd9\">"),
            .prompt("Agree?\n\nFor context…"))
        XCTAssertEqual(
            ClaudeTranscriptText.read("Fix it\n<system-reminder>internal</system-reminder>"),
            .prompt("Fix it"))
        XCTAssertEqual(
            ClaudeTranscriptText.read("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Build finished</summary>\n</task-notification>"),
            .notice("Build finished"))
    }

    func testTheReaderPairsACommandWithItsOutput() {
        var reader = ClaudeTranscriptReader()
        _ = reader.events(forLine: #"{"type":"user","uuid":"a","message":{"content":"<command-name>/model</command-name><command-args>sonnet</command-args>"}}"#)
        let output = reader.events(forLine: #"{"type":"user","uuid":"b","message":{"content":"<local-command-stdout>Set model to Sonnet 5</local-command-stdout>"}}"#)
        guard case .itemCompleted(let item)? = output.first else { return XCTFail("\(output)") }
        XCTAssertEqual(item.kind, .command(command: "/model sonnet", output: "Set model to Sonnet 5", exitCode: nil))
    }

    func testCommandsLoseTheirCdPrefix() {
        XCTAssertEqual(
            AgentChatTranscript.displayCommand(#"cd "/Users/me/Application Support/x" && find . -name '*.md' | head"#),
            "find . -name '*.md' | head")
        XCTAssertEqual(AgentChatTranscript.displayCommand("cd /tmp; ls"), "ls")
        XCTAssertEqual(AgentChatTranscript.displayCommand("git status"), "git status")
    }

    func testCommandsThatAnswerOnlyInTheTerminal() {
        XCTAssertTrue(NativeAgentCommands.answersInTerminal("/model", provider: .claude))
        XCTAssertFalse(NativeAgentCommands.answersInTerminal("/model sonnet", provider: .claude))
        XCTAssertFalse(NativeAgentCommands.answersInTerminal("/compact", provider: .claude))
        XCTAssertTrue(NativeAgentCommands.answersInTerminal("/model", provider: .codex))
        XCTAssertTrue(NativeAgentCommands.answersInTerminal("/status", provider: .codex))
        XCTAssertFalse(NativeAgentCommands.answersInTerminal("/compact", provider: .codex))
    }
}

@MainActor
extension UncoilAutoSessionTests {
    func testAPastedPromptIsStillRecognisedAsOurs() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@claude fix it")
        transcripts.publish(.itemCompleted(AgentItem(id: "m", kind: .agentMessage(text: "Done."), status: .completed, native: nil)), sessionID: claude, provider: .claude)
        await session.submit("@codex review\nthis please")
        // Codex's transcript got the prompt, context and all, pasted.
        let sent = recorder.delivered.last!.0
        var reader = ClaudeTranscriptReader()
        let echoed = reader.events(forLine: Substring(String(data: try! JSONEncoder().encode(JSONValue.object([
            "type": .string("user"), "uuid": .string("e"),
            "message": .object(["content": .string("<pasted_content id=\"1\">\n\(sent)\n</pasted_content id=\"1\">")]),
        ])), encoding: .utf8)!))
        for event in echoed { transcripts.publish(event, sessionID: codex, provider: .codex) }
        XCTAssertFalse(items(session).contains { $0.source?.handle == "codex" }, "the pasted echo is ours, not a new message")
    }

    func testAnAgentCommandAnsweredOnScreenOffersTheTerminal() async {
        let recorder = Recorder()
        let session = makeSession(recorder)
        await session.submit("@codex /model")
        XCTAssertEqual(recorder.delivered.last?.0, "/model")
        let notice = hub.timeline(for: session.sessionID)?.notices.last
        XCTAssertEqual(notice?.action, .openTerminal(sessionID: codex, handle: "codex"))

        let before = hub.timeline(for: session.sessionID)?.notices.count
        await session.submit("@claude /model sonnet")
        XCTAssertEqual(hub.timeline(for: session.sessionID)?.notices.count, before, "with an argument it just acts")
    }
}

/// Uncoil Auto carrying on across a relaunch.
@MainActor
final class UncoilAutoResumeTests: XCTestCase {
    func testTheDaemonsSilenceDoesNotEndUncoilAuto() {
        let sessions = SessionStore()
        let auto = SessionRecord(projectID: UUID(), provider: .uncoil, accountID: nil, title: "uncoil: new session")
        var ended: [UUID] = []
        for _ in 0..<3 {
            let missing = sessions.reconcile(aliveSessionIDs: [], records: [auto], markEnded: { ended.append($0) })
            XCTAssertFalse(missing.contains(auto.id))
        }
        XCTAssertTrue(ended.isEmpty, "it has no process in the daemon to be missing")
        XCTAssertEqual(sessions.status(of: auto.id), .idle)
    }

    func testTheWatcherKnowsHowFarItHasReadAndACatchUpStartsThere() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ id: String, _ text: String) -> String {
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"\#(id)","content":[{"type":"Text","text":"\#(text)"}]}}}"# + "\n"
        }
        try Data(line("m1", "seen").utf8).write(to: url)
        let location = NativeTranscriptLocation(url: url, provider: .codex)
        let watcher = NativeTranscriptWatcher(locate: { location }, emit: { _ in }, reset: {})
        watcher.poll()
        let seen = try XCTUnwrap(watcher.position)
        XCTAssertEqual(seen.offset, UInt64(line("m1", "seen").utf8.count))

        // Uncoil closes; the agent carries on, and is mid-line when it reopens.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((line("m2", "while closed") + #"{"type":"event_msg""#).utf8))
        try handle.close()

        let caught = NativeTranscriptWatcher.read(location, from: seen)
        guard case .itemCompleted(let item)? = caught.events.first else { return XCTFail("\(caught.events)") }
        XCTAssertEqual(item.kind, .agentMessage(text: "while closed"))
        XCTAssertEqual(caught.events.count, 1, "the unfinished line waits")
        XCTAssertEqual(caught.position.offset, seen.offset + UInt64(line("m2", "while closed").utf8.count))

        // A transcript that is not the one read before gives nothing.
        let elsewhere = NativeTranscriptPosition(path: "/elsewhere.jsonl", offset: 0)
        XCTAssertTrue(NativeTranscriptWatcher.read(location, from: elsewhere).events.isEmpty)
    }

    func testARelaunchPicksUpWhatTheAgentDidMeanwhile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let claude = UUID()
        let record = SessionRecord(projectID: UUID(), provider: .uncoil, accountID: nil, title: "uncoil: new session")
        let roster: [UncoilAutoRoster.Entry] = [.init(handle: "claude", provider: .claude, sessionID: claude, title: "fix")]
        var caughtUpFrom: NativeTranscriptPosition?
        func environment(position: NativeTranscriptPosition, missed: [AgentEvent]) -> UncoilAutoEnvironment {
            UncoilAutoEnvironment(
                roster: { roster }, startSession: { _, _ in nil }, ensureRunning: { _ in },
                deliver: { _, _, _ in }, interrupt: { _ in }, isWorking: { _ in false },
                follow: { _ in }, unfollow: { _ in },
                position: { _ in position },
                catchUp: { _, from in
                    caughtUpFrom = from
                    return (missed, NativeTranscriptPosition(path: from.path, offset: from.offset + 100))
                })
        }

        let firstHub = AgentEventHub()
        let first = UncoilAutoSession(
            record: record, terminal: nil,
            environment: environment(position: .init(path: "/t.jsonl", offset: 42), missed: []),
            store: UncoilAutoStore(url: url, delay: 0), hub: firstHub, transcripts: AgentEventHub())
        await first.submit("@claude fix it")
        first.stop(terminateServer: true)

        let secondHub = AgentEventHub()
        let missed: [AgentEvent] = [
            .itemCompleted(AgentItem(id: "m9", kind: .agentMessage(text: "Fixed while you were away."), status: .completed, native: nil)),
        ]
        let second = UncoilAutoSession(
            record: record, terminal: nil,
            environment: environment(position: .init(path: "/t.jsonl", offset: 142), missed: missed),
            store: UncoilAutoStore(url: url, delay: 0), hub: secondHub, transcripts: AgentEventHub())
        second.start()

        XCTAssertEqual(caughtUpFrom, NativeTranscriptPosition(path: "/t.jsonl", offset: 42), "from where the first one stopped reading")
        let items = secondHub.timeline(for: record.id)?.items ?? []
        XCTAssertEqual(items.map(\.kind), [
            .userMessage(text: "@claude fix it", attachments: []),
            .agentMessage(text: "Fixed while you were away."),
        ])
        XCTAssertEqual(items.last?.source?.handle, "claude")
        XCTAssertEqual(secondHub.timeline(for: record.id)?.notices.last?.message,
                       "@claude carried on while Uncoil was closed: 1 update above.")
    }
}
