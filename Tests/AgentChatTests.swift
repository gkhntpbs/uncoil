import XCTest
@testable import Uncoil

/// The chat's contract with the AgentSession model: what the timeline records
/// for it, how the timeline becomes rows, and how the model keeps up with a
/// stream and routes the user's actions back into the session's control.
@MainActor
final class AgentChatTests: XCTestCase {
    private let sessionID = UUID()

    private static func item(_ id: String, _ kind: AgentItemKind, _ status: AgentItem.Status = .completed) -> AgentItem {
        AgentItem(id: id, kind: kind, status: status, native: nil)
    }

    private static let approval = AgentApproval(
        id: "a1", kind: .command, title: "rm -rf build", detail: nil,
        decisions: ["accept", "decline"], native: nil)

    // MARK: - Timeline markers

    func testMarkersArePlacedAfterTheItemTheyFollowed() {
        var timeline = AgentTimeline()
        timeline.apply(.notice(AgentNotice(level: .info, message: "ready")))
        timeline.apply(.itemCompleted(Self.item("u1", .userMessage(text: "hi", attachments: []))))
        timeline.apply(.turnStarted(turnID: "t1"))
        timeline.apply(.itemStarted(Self.item("m1", .agentMessage(text: "par"), .inProgress)))
        timeline.apply(.turnCompleted(turnID: "t1", outcome: .interrupted))

        XCTAssertEqual(timeline.markers.map(\.afterItemID), [nil, "m1"])
        XCTAssertEqual(timeline.markers.last?.kind, .turnEnded(.interrupted))
        // The marker ids only ever increase.
        XCTAssertLessThan(timeline.markers[0].id, timeline.markers[1].id)
    }

    func testAnAnsweredApprovalLeavesARecordOfTheAnswer() {
        var timeline = AgentTimeline()
        timeline.apply(.itemStarted(Self.item("c1", .command(command: "rm -rf build", output: "", exitCode: nil), .inProgress)))
        timeline.apply(.approvalRequested(Self.approval))
        timeline.apply(.approvalResolved(approvalID: "a1", decision: "decline"))

        XCTAssertTrue(timeline.pendingApprovals.isEmpty)
        XCTAssertEqual(timeline.markers.map(\.kind), [.approvalResolved(Self.approval, decision: "decline")])
        XCTAssertEqual(timeline.markers.first?.afterItemID, "c1")
    }

    func testAPlanGrowsByStreamedText() {
        var timeline = AgentTimeline()
        timeline.apply(.itemStarted(Self.item("p1", .plan(AgentPlan(text: "1. Read")), .inProgress)))
        timeline.apply(.itemDelta(itemID: "p1", channel: .text, text: "\n2. Change"))
        XCTAssertEqual(timeline.item(id: "p1")?.kind, .plan(AgentPlan(text: "1. Read\n2. Change")))
    }

    func testAResetTimelineKeepsCountingWhereItLeftOff() {
        let hub = AgentEventHub()
        hub.publish(.turnStarted(turnID: nil), sessionID: sessionID, provider: .claude)
        hub.publish(.itemCompleted(Self.item("u1", .userMessage(text: "hi", attachments: []))), sessionID: sessionID, provider: .claude)
        var seen: [Int] = []
        let observation = hub.observe(sessionID) { seen.append($0.sequence) }

        hub.reset(sessionID)
        XCTAssertEqual(hub.timeline(for: sessionID)?.items, [])
        hub.publish(.turnStarted(turnID: nil), sessionID: sessionID, provider: .claude)

        // A consumer reading "everything after 2" still gets the new event,
        // and the observer registered before the reset still hears it.
        XCTAssertEqual(seen, [3])
        XCTAssertEqual(hub.records(for: sessionID, after: 2, limit: 10).records.map(\.sequence), [3])
        observation.cancel()
    }

    // MARK: - Rows

    func testRowsInterleaveItemsAndMarkersAndEndWithWhatIsPending() {
        var timeline = AgentTimeline()
        timeline.apply(.notice(AgentNotice(level: .warning, message: "Could not resume")))
        timeline.apply(.itemCompleted(Self.item("u1", .userMessage(text: "go", attachments: []))))
        timeline.apply(.turnStarted(turnID: "t1"))
        timeline.apply(.itemCompleted(Self.item("m1", .agentMessage(text: "done"))))
        timeline.apply(.turnCompleted(turnID: "t1", outcome: .completed))
        timeline.apply(.turnStarted(turnID: "t2"))
        timeline.apply(.itemStarted(Self.item("c1", .command(command: "make", output: "", exitCode: nil), .inProgress)))
        timeline.apply(.approvalRequested(Self.approval))

        let rows = AgentChatTranscript.rows(for: timeline)
        XCTAssertEqual(rows.map(\.id), [
            "marker:1", "item:u1", "item:m1",
            // The completed turn t1 says nothing.
            "item:c1", "approval:a1",
        ])
    }

    func testARunningTurnShowsWorkOnlyWhenNothingElseDoes() {
        var timeline = AgentTimeline()
        timeline.apply(.itemCompleted(Self.item("u1", .userMessage(text: "go", attachments: []))))
        timeline.apply(.turnStarted(turnID: "t1"))
        XCTAssertEqual(AgentChatTranscript.rows(for: timeline).last, .working)

        // An announced reply with no words yet is not drawn, so the work line stays.
        timeline.apply(.itemStarted(Self.item("m1", .agentMessage(text: ""), .inProgress)))
        XCTAssertEqual(AgentChatTranscript.rows(for: timeline).map(\.id), ["item:u1", "working"])

        // Its first word replaces the work line: the streaming text is the sign of life.
        timeline.apply(.itemDelta(itemID: "m1", channel: .text, text: "Hel"))
        XCTAssertEqual(AgentChatTranscript.rows(for: timeline).map(\.id), ["item:u1", "item:m1"])

        timeline.apply(.turnCompleted(turnID: "t1", outcome: .completed))
        XCTAssertFalse(AgentChatTranscript.rows(for: timeline).contains(.working))
    }

    func testFailedAndInterruptedTurnsAreShownWhereTheyStopped() {
        var timeline = AgentTimeline()
        timeline.apply(.turnStarted(turnID: "t1"))
        timeline.apply(.itemStarted(Self.item("c1", .command(command: "sleep 9", output: "", exitCode: nil), .inProgress)))
        timeline.apply(.turnCompleted(turnID: "t1", outcome: .failed("overloaded")))

        let rows = AgentChatTranscript.rows(for: timeline)
        XCTAssertEqual(rows.count, 2)
        guard case .marker(let marker) = rows[1] else { return XCTFail("expected a marker, got \(rows[1])") }
        XCTAssertEqual(marker.kind, .turnEnded(.failed("overloaded")))
        // What the turn left running is settled, not left spinning.
        XCTAssertEqual(timeline.item(id: "c1")?.status, .failed)
    }

    func testAnUnknownItemIsARowNotASilence() {
        var timeline = AgentTimeline()
        timeline.apply(.itemCompleted(AgentItem(
            id: "x1", kind: .other(type: "imageGeneration"), status: .completed,
            native: .object(["type": .string("imageGeneration")]))))
        XCTAssertEqual(AgentChatTranscript.rows(for: timeline), [.item("x1")])
        XCTAssertEqual(AgentChatTranscript.details(timeline.item(id: "x1")?.native), "{\n  \"type\" : \"imageGeneration\"\n}")
    }

    func testAMarkerAfterADroppedItemMovesToTheTop() {
        var timeline = AgentTimeline()
        timeline.apply(.itemCompleted(Self.item("first", .agentMessage(text: "a"))))
        timeline.apply(.notice(AgentNotice(level: .error, message: "boom")))
        for index in 0..<AgentTimeline.itemLimit {
            timeline.apply(.itemCompleted(Self.item("i\(index)", .agentMessage(text: "x"))))
        }
        XCTAssertNil(timeline.item(id: "first"))
        XCTAssertEqual(AgentChatTranscript.rows(for: timeline).first?.id, "marker:1")
    }

    func testOutputIsReadFromItsEnd() {
        let output = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = AgentChatTranscript.tail(output, lines: 3)
        XCTAssertEqual(tail.text, "line 8\nline 9\nline 10")
        XCTAssertEqual(tail.hidden, 7)
        XCTAssertEqual(AgentChatTranscript.tail("short", lines: 3).hidden, 0)
    }

    // MARK: - Model

    private final class Recorder {
        var submitted: [String] = []
        var interrupts = 0
        var answers: [(String, String)] = []
        var ready = true
    }

    private func makeModel(hub: AgentEventHub, recorder: Recorder) -> AgentChatModel {
        AgentChatModel(sessionID: sessionID, hub: hub, actions: AgentChatActions(
            submit: { recorder.submitted.append($0) },
            interrupt: { recorder.interrupts += 1 },
            respond: { recorder.answers.append(($0, $1)); return true },
            isReady: { recorder.ready }
        ))
    }

    func testStreamingUpdatesOneItemWithoutRebuildingTheRows() {
        let hub = AgentEventHub()
        let model = makeModel(hub: hub, recorder: Recorder())
        hub.publish(.turnStarted(turnID: "t1"), sessionID: sessionID, provider: .codex)
        hub.publish(.itemStarted(Self.item("m1", .agentMessage(text: "The"), .inProgress)), sessionID: sessionID, provider: .codex)
        model.flush()
        let rows = model.rows
        let row = try? XCTUnwrap(model.itemModel(for: "m1"))

        for word in [" answer", " is", " 42."] {
            hub.publish(.itemDelta(itemID: "m1", channel: .text, text: word), sessionID: sessionID, provider: .codex)
        }
        // Nothing is drawn until the frame's flush, however many words arrived.
        XCTAssertEqual(row?.item.kind, .agentMessage(text: "The"))
        model.flush()

        XCTAssertEqual(row?.item.kind, .agentMessage(text: "The answer is 42."))
        XCTAssertTrue(model.itemModel(for: "m1") === row, "the row keeps its model while it streams")
        XCTAssertEqual(model.rows, rows)
    }

    func testTheFlushWaitsForTheFrameInterval() {
        let hub = AgentEventHub()
        let model = makeModel(hub: hub, recorder: Recorder())
        hub.publish(.itemCompleted(Self.item("u1", .userMessage(text: "hi", attachments: []))), sessionID: sessionID, provider: .claude)
        XCTAssertTrue(model.rows.isEmpty)
        let flushed = expectation(description: "flushed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentChatModel.flushInterval * 3) { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(model.rows, [.item("u1")])
    }

    func testTheModelSeesWhatHappenedBeforeItExisted() {
        let hub = AgentEventHub()
        hub.publish(.historyLoaded([Self.item("h1", .userMessage(text: "earlier", attachments: []))]), sessionID: sessionID, provider: .claude)
        let model = makeModel(hub: hub, recorder: Recorder())
        XCTAssertEqual(model.rows, [.item("h1")])
    }

    func testARelaunchResyncsTheTranscript() {
        let hub = AgentEventHub()
        let model = makeModel(hub: hub, recorder: Recorder())
        hub.publish(.itemCompleted(Self.item("prompt-1", .userMessage(text: "hi", attachments: []))), sessionID: sessionID, provider: .claude)
        model.flush()
        hub.reset(sessionID)
        hub.publish(.historyLoaded([Self.item("uuid-1", .userMessage(text: "hi", attachments: []))]), sessionID: sessionID, provider: .claude)
        model.flush()
        XCTAssertEqual(model.rows, [.item("uuid-1")], "the conversation is shown once, as the provider handed it back")
    }

    func testSendingGoesThroughTheSessionControlAndClearsTheComposer() async {
        let hub = AgentEventHub()
        let recorder = Recorder()
        let model = makeModel(hub: hub, recorder: recorder)
        model.draft = "  Fix the build  \n"
        XCTAssertTrue(model.send())
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.followRequest, 1)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(recorder.submitted, ["Fix the build"])
    }

    func testNothingIsSentWhileATurnRunsOrTheSessionIsNotReady() {
        let hub = AgentEventHub()
        let recorder = Recorder()
        let model = makeModel(hub: hub, recorder: recorder)
        model.draft = "next"

        recorder.ready = false
        model.flush()
        XCTAssertFalse(model.send())
        XCTAssertEqual(model.draft, "next", "the text stays where it was")

        recorder.ready = true
        hub.publish(.turnStarted(turnID: "t1"), sessionID: sessionID, provider: .codex)
        model.flush()
        XCTAssertTrue(model.turnInProgress)
        XCTAssertFalse(model.send())
        XCTAssertFalse(model.send(), "blank or not, a running turn is not interrupted by a send")
    }

    func testStopAndApprovalsAreTheSessionsOwnCalls() {
        let hub = AgentEventHub()
        let recorder = Recorder()
        let model = makeModel(hub: hub, recorder: recorder)
        hub.publish(.approvalRequested(Self.approval), sessionID: sessionID, provider: .claude)
        model.flush()
        XCTAssertEqual(model.rows, [.approval(Self.approval)])

        XCTAssertTrue(model.respond(to: "a1", decision: "accept"))
        model.interrupt()
        XCTAssertEqual(recorder.answers.map(\.0), ["a1"])
        XCTAssertEqual(recorder.answers.map(\.1), ["accept"])
        XCTAssertEqual(recorder.interrupts, 1)
    }

    func testADraftForTheSessionLandsInItsOpenChat() {
        let hub = AgentEventHub()
        let model = makeModel(hub: hub, recorder: Recorder())
        let drafts = AgentChatDrafts.shared
        XCTAssertFalse(drafts.deliver("nobody", to: sessionID))

        drafts.register(model)
        model.draft = "Look at"
        XCTAssertTrue(drafts.deliver("@src/main.swift", to: sessionID))
        XCTAssertEqual(model.draft, "Look at @src/main.swift")

        drafts.unregister(model)
        XCTAssertFalse(drafts.deliver("again", to: sessionID), "a closed chat hands drafts back to the terminal")
    }

    // MARK: - The fixture session

    func testTheFixtureSessionRunsAWholeTurnThroughTheControl() async throws {
        let hub = AgentEventHub()
        let record = SessionRecord(projectID: UUID(), provider: .codex, accountID: nil, title: "fixture")
        let session = FixtureAgentSession(record: record, terminal: nil, sessionStore: nil, hub: hub, wordDelay: 0)
        session.start()
        try await waitUntil { session.isReady }

        await session.submit("Add a prompt")
        try await waitUntil { !(hub.timeline(for: record.id)?.pendingApprovals.isEmpty ?? true) }
        let approval = try XCTUnwrap(hub.timeline(for: record.id)?.pendingApprovals.first)
        XCTAssertTrue(session.respond(toApproval: approval.id, decision: "accept"))
        try await waitUntil { hub.timeline(for: record.id)?.turnInProgress == false }

        let timeline = try XCTUnwrap(hub.timeline(for: record.id))
        XCTAssertEqual(timeline.lastTurnOutcome, .completed)
        XCTAssertTrue(timeline.items.contains { if case .fileChange = $0.kind { $0.status == .completed } else { false } })
        XCTAssertTrue(timeline.markers.contains { $0.kind == .approvalResolved(approval, decision: "accept") })
    }

    func testInterruptingTheFixtureWithdrawsItsQuestion() async throws {
        let hub = AgentEventHub()
        let record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "fixture")
        let session = FixtureAgentSession(record: record, terminal: nil, sessionStore: nil, hub: hub, wordDelay: 0)
        session.start()
        try await waitUntil { session.isReady }
        await session.submit("Add a prompt")
        try await waitUntil { !(hub.timeline(for: record.id)?.pendingApprovals.isEmpty ?? true) }

        session.interrupt()
        try await waitUntil { hub.timeline(for: record.id)?.turnInProgress == false }
        let timeline = try XCTUnwrap(hub.timeline(for: record.id))
        XCTAssertEqual(timeline.lastTurnOutcome, .interrupted)
        XCTAssertTrue(timeline.pendingApprovals.isEmpty)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Block markdown, as it arrives.
final class ChatMarkdownTests: XCTestCase {
    func testSplitsAReplyIntoItsBlocks() {
        let blocks = ChatMarkdown.blocks("""
        ## Result

        The build **passes** now.
        It took two changes:

        - moved `Foo`
          and renamed it
        1. ran the tests
        > quoted
        ---
        | a | b |
        |---|---|
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Result"),
            .paragraph("The build **passes** now.\nIt took two changes:"),
            .listItem(marker: "•", text: "moved `Foo`\nand renamed it", depth: 0),
            .listItem(marker: "1.", text: "ran the tests", depth: 0),
            .quote("quoted"),
            .rule,
            .table("| a | b |\n|---|---|"),
        ])
    }

    func testAFenceStillOpenIsAlreadyCode() {
        XCTAssertEqual(
            ChatMarkdown.blocks("Here:\n```swift\nlet x = 1\n"),
            [.paragraph("Here:"), .code(language: "swift", text: "let x = 1\n")]
        )
        XCTAssertEqual(
            ChatMarkdown.blocks("```\n# not a heading\n```\nafter"),
            [.code(language: nil, text: "# not a heading"), .paragraph("after")]
        )
    }

    func testInlineMarkupIsReadAndBadMarkupIsKept() {
        XCTAssertEqual(String(ChatMarkdown.inline("a **b** `c`").characters), "a b c")
        XCTAssertEqual(String(ChatMarkdown.inline("2 * 3 = 6").characters), "2 * 3 = 6")
    }
}

/// Diffs: how they are read, and how an edit becomes one.
final class ChatDiffTests: XCTestCase {
    func testReadsAUnifiedDiff() {
        let lines = UnifiedDiff.lines("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n")
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .hunk, .context, .removed, .added])
        XCTAssertEqual(lines.map(\.text).suffix(3), ["keep", "old", "new"])
        XCTAssertEqual(UnifiedDiff.stats("+a\n+b\n-c").added, 2)
        XCTAssertEqual(UnifiedDiff.stats("+a\n+b\n-c").removed, 1)
    }

    func testAnEditKeepsWhatDidNotChangeAsContext() {
        let old = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 5", with: "line five")
        XCTAssertEqual(AgentFileChange.replacementDiff(old: old, new: new), """
         line 2
         line 3
         line 4
        -line 5
        +line five
         line 6
         line 7
         line 8
        """)
        XCTAssertEqual(AgentFileChange.replacementDiff(old: "", new: "a\nb"), "+a\n+b")
    }
}

/// What the providers' own shapes become in the common model.
final class ChatNormalizationTests: XCTestCase {
    func testCodexFileChangesKeepTheirDiff() {
        let item = CodexEventNormalizer.item(.object([
            "id": .string("f1"), "type": .string("fileChange"), "status": .string("completed"),
            "changes": .array([
                .object(["path": .string("a.swift"), "kind": .object(["type": .string("add")]), "diff": .string("+x")]),
                .object(["path": .string("b.swift"), "kind": .string("update"), "diff": .string("")]),
            ]),
        ]))
        XCTAssertEqual(item?.kind, .fileChange([
            AgentFileChange(path: "a.swift", kind: .add, diff: "+x"),
            AgentFileChange(path: "b.swift", kind: .update, diff: nil),
        ]))
    }

    func testCodexPlanUpdatesBecomeOnePlanPerTurn() {
        let events = CodexEventNormalizer.events(method: "turn/plan/updated", params: .object([
            "threadId": .string("th"), "turnId": .string("t9"), "explanation": .string("Two steps"),
            "plan": .array([
                .object(["step": .string("Read"), "status": .string("completed")]),
                .object(["step": .string("Write"), "status": .string("inProgress")]),
            ]),
        ]))
        guard case .itemCompleted(let item)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(item.id, "plan-t9")
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.kind, .plan(AgentPlan(text: "Two steps", steps: [
            .init(text: "Read", status: .completed), .init(text: "Write", status: .inProgress),
        ])))
    }

    func testCodexReasoningSummariesStream() {
        XCTAssertEqual(
            CodexEventNormalizer.events(method: "item/reasoning/summaryTextDelta", params: .object([
                "itemId": .string("r1"), "delta": .string("Checking"), "summaryIndex": .int(0),
            ])),
            [.itemDelta(itemID: "r1", channel: .text, text: "Checking")]
        )
        XCTAssertEqual(
            CodexEventNormalizer.events(method: "item/reasoning/summaryPartAdded", params: .object([
                "itemId": .string("r1"), "summaryIndex": .int(1),
            ])),
            [.itemDelta(itemID: "r1", channel: .text, text: "\n\n")]
        )
        XCTAssertEqual(
            CodexEventNormalizer.events(method: "item/reasoning/summaryPartAdded", params: .object([
                "itemId": .string("r1"), "summaryIndex": .int(0),
            ])),
            []
        )
    }

    func testClaudeEditsCarryADiffAndTodosBecomeAPlan() {
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "Edit", input: [
                "file_path": .string("/a.swift"), "old_string": .string("let a = 1"), "new_string": .string("let a = 2"),
            ]),
            .fileChange([AgentFileChange(path: "/a.swift", kind: .update, diff: "-let a = 1\n+let a = 2")])
        )
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "TodoWrite", input: ["todos": .array([
                .object(["content": .string("Read"), "status": .string("completed"), "activeForm": .string("Reading")]),
                .object(["content": .string("Fix"), "status": .string("in_progress")]),
                .object(["content": .string("Test"), "status": .string("pending")]),
            ])]),
            .plan(AgentPlan(steps: [
                .init(text: "Read", status: .completed),
                .init(text: "Fix", status: .inProgress),
                .init(text: "Test", status: .pending),
            ]))
        )
    }

    func testTheWireCarriesPlansAndChangesAlongsideThePaths() {
        let plan = AgentWire.item(AgentItem(
            id: "p", kind: .plan(AgentPlan(steps: [.init(text: "Read", status: .pending)])),
            status: .inProgress, native: nil))
        XCTAssertEqual(plan.objectValue?["kind"], .string("plan"))
        XCTAssertEqual(plan.objectValue?["steps"], .array([.object(["text": .string("Read"), "status": .string("pending")])]))

        let change = AgentWire.item(AgentItem(
            id: "f", kind: .fileChange([AgentFileChange(path: "a", kind: .add, diff: "+x")]),
            status: .completed, native: nil))
        XCTAssertEqual(change.objectValue?["paths"], .array([.string("a")]))
        XCTAssertEqual(change.objectValue?["changes"], .array([.object(["path": .string("a"), "change": .string("add")])]))
    }

    func testTheTerminalDrawsAPlanAndDimsStreamedReasoning() {
        var renderer = AgentTerminalRenderer()
        let plan = renderer.render(.itemCompleted(AgentItem(
            id: "p", kind: .plan(AgentPlan(steps: [.init(text: "Read", status: .completed)])),
            status: .completed, native: nil)))
        XCTAssertEqual(plan?.contains("[x] Read"), true)

        _ = renderer.render(.itemStarted(AgentItem(id: "r", kind: .reasoning(summary: ""), status: .inProgress, native: nil)))
        XCTAssertEqual(renderer.render(.itemDelta(itemID: "r", channel: .text, text: "hm")), "\u{001B}[2mhm\u{001B}[0m")
        XCTAssertEqual(
            renderer.render(.itemCompleted(AgentItem(id: "r", kind: .reasoning(summary: "hm"), status: .completed, native: nil))),
            "\r\n"
        )
    }
}
