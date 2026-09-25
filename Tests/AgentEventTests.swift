import XCTest
@testable import Uncoil

final class AgentEventTests: XCTestCase {
    // MARK: Codex normalization

    func testNormalizesCodexTurnLifecycle() {
        XCTAssertEqual(
            CodexEventNormalizer.events(
                method: "turn/started",
                params: .object(["turn": .object(["id": .string("t1")])])
            ),
            [.turnStarted(turnID: "t1")]
        )
        XCTAssertEqual(
            CodexEventNormalizer.events(
                method: "turn/completed",
                params: .object(["turn": .object([
                    "id": .string("t1"),
                    "status": .string("failed"),
                    "error": .object(["message": .string("boom")]),
                ])])
            ),
            [.turnCompleted(turnID: "t1", outcome: .failed("boom"))]
        )
        XCTAssertEqual(
            CodexEventNormalizer.events(
                method: "thread/status/changed",
                params: .object(["status": .string("systemError")])
            ),
            [.runState(.systemError)]
        )
        XCTAssertEqual(CodexEventNormalizer.events(method: "unknown/method", params: .null), [])
    }

    func testNormalizedItemsKeepTheNativePayload() throws {
        let native: JSONValue = .object([
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
            "aggregatedOutput": .string("ok\n"),
            "exitCode": .int(0),
            "status": .string("completed"),
            "durationMs": .int(1200),
        ])
        let item = try XCTUnwrap(CodexEventNormalizer.item(native))
        XCTAssertEqual(item.kind, .command(command: "swift test", output: "ok\n", exitCode: 0))
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.native?.objectValue?["durationMs"], .int(1200))

        let unknown = try XCTUnwrap(CodexEventNormalizer.item(.object([
            "id": .string("x"),
            "type": .string("imageGeneration"),
        ])))
        XCTAssertEqual(unknown.kind, .other(type: "imageGeneration"))
    }

    func testNormalizesToolCallOrigins() {
        func kind(_ type: String, _ extra: [String: JSONValue]) -> AgentItemKind? {
            var object = extra
            object["id"] = .string("i")
            object["type"] = .string(type)
            return CodexEventNormalizer.item(.object(object))?.kind
        }
        XCTAssertEqual(
            kind("mcpToolCall", ["server": .string("uncoil"), "tool": .string("uncoil_sessions")]),
            .toolCall(AgentToolCall(origin: .mcp(server: "uncoil"), name: "uncoil_sessions"))
        )
        XCTAssertEqual(
            kind("dynamicToolCall", ["tool": .string("search")]),
            .toolCall(AgentToolCall(origin: .agent, name: "search"))
        )
        XCTAssertEqual(
            kind("collabAgentToolCall", [:]),
            .toolCall(AgentToolCall(origin: .delegation, name: "agent"))
        )
    }

    func testThreadOpenedBindsSessionAndLoadsHistory() {
        let result: JSONValue = .object([
            "thread": .object(["id": .string("thread-9")]),
            "initialTurnsPage": .object(["data": .array([
                .object(["items": .array([
                    .object([
                        "id": .string("a1"),
                        "type": .string("agentMessage"),
                        "text": .string("Önceki yanıt"),
                    ]),
                ])]),
            ])]),
        ])
        let events = CodexEventNormalizer.threadOpened(result)
        XCTAssertEqual(events.first, .sessionBound(providerSessionID: "thread-9"))
        guard case .historyLoaded(let items)? = events.last else {
            return XCTFail("expected history")
        }
        XCTAssertEqual(items.map(\.kind), [.agentMessage(text: "Önceki yanıt")])
        XCTAssertEqual(items.first?.status, .completed)
        XCTAssertEqual(CodexEventNormalizer.threadOpened(.object([:])), [])
    }

    // MARK: Timeline

    func testTimelineFoldsStreamingIntoItems() {
        var timeline = AgentTimeline()
        timeline.apply(.sessionBound(providerSessionID: "p1"))
        timeline.apply(.turnStarted(turnID: "t1"))
        timeline.apply(.itemStarted(AgentItem(
            id: "m", kind: .agentMessage(text: ""), status: .inProgress, native: nil
        )))
        timeline.apply(.itemDelta(itemID: "m", channel: .text, text: "Hel"))
        timeline.apply(.itemDelta(itemID: "m", channel: .text, text: "lo"))
        XCTAssertEqual(timeline.item(id: "m")?.kind, .agentMessage(text: "Hello"))
        XCTAssertTrue(timeline.turnInProgress)

        timeline.apply(.itemStarted(AgentItem(
            id: "c", kind: .command(command: "ls", output: "", exitCode: nil),
            status: .inProgress, native: nil
        )))
        timeline.apply(.itemDelta(itemID: "c", channel: .output, text: "a.txt\n"))
        // The final item omits the output it already streamed; the timeline keeps it.
        timeline.apply(.itemCompleted(AgentItem(
            id: "c", kind: .command(command: "ls", output: "", exitCode: 0),
            status: .completed, native: nil
        )))
        XCTAssertEqual(
            timeline.item(id: "c")?.kind,
            .command(command: "ls", output: "a.txt\n", exitCode: 0)
        )

        timeline.apply(.turnCompleted(turnID: "t1", outcome: .interrupted))
        XCTAssertEqual(timeline.providerSessionID, "p1")
        XCTAssertFalse(timeline.turnInProgress)
        XCTAssertEqual(timeline.lastTurnOutcome, .interrupted)
        // The unfinished message was cut off with its turn.
        XCTAssertEqual(timeline.item(id: "m")?.status, .failed)
        XCTAssertEqual(timeline.items.map(\.id), ["m", "c"])
    }

    func testTimelineTracksApprovalsUntilResolved() {
        var timeline = AgentTimeline()
        let approval = AgentApproval(
            id: "ap", kind: .command, title: "rm -rf build", detail: nil,
            decisions: ["accept", "decline"], native: nil
        )
        timeline.apply(.approvalRequested(approval))
        XCTAssertEqual(timeline.pendingApprovals, [approval])
        timeline.apply(.approvalResolved(approvalID: "ap", decision: "decline"))
        XCTAssertTrue(timeline.pendingApprovals.isEmpty)
    }

    func testTimelineIsBounded() {
        var timeline = AgentTimeline()
        for index in 0..<(AgentTimeline.itemLimit + 5) {
            timeline.apply(.itemCompleted(AgentItem(
                id: "\(index)", kind: .agentMessage(text: "x"), status: .completed, native: nil
            )))
        }
        XCTAssertEqual(timeline.items.count, AgentTimeline.itemLimit)
        XCTAssertEqual(timeline.items.first?.id, "5")
    }

    // MARK: Hub

    @MainActor
    func testHubSequencesEventsAndNotifiesObservers() {
        let hub = AgentEventHub(now: { Date(timeIntervalSince1970: 0) })
        let session = UUID()
        var received: [AgentEventRecord] = []
        let observation = hub.observe(session) { received.append($0) }

        hub.publish(.turnStarted(turnID: nil), sessionID: session, provider: .codex)
        hub.publish(.runState(.active), sessionID: session, provider: .codex)
        XCTAssertEqual(received.map(\.sequence), [1, 2])
        XCTAssertEqual(received.first?.provider, .codex)
        XCTAssertEqual(hub.timeline(for: session)?.sequence, 2)

        observation.cancel()
        hub.publish(.runState(.idle), sessionID: session, provider: .codex)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(hub.timeline(for: session)?.runState, .idle)

        hub.end(session)
        XCTAssertFalse(hub.hasTimeline(for: session))
    }

    // MARK: Terminal rendering

    func testRendererDoesNotRepeatStreamedText() {
        var renderer = AgentTerminalRenderer()
        let message = AgentItem(id: "m", kind: .agentMessage(text: ""), status: .inProgress, native: nil)
        XCTAssertNil(renderer.render(.itemStarted(message)))
        XCTAssertEqual(renderer.render(.itemDelta(itemID: "m", channel: .text, text: "Hi")), "Hi")
        var done = message
        done.kind = .agentMessage(text: "Hi")
        XCTAssertEqual(renderer.render(.itemCompleted(done)), "\r\n")

        let command = AgentItem(
            id: "c", kind: .command(command: "ls", output: "", exitCode: nil),
            status: .inProgress, native: nil
        )
        XCTAssertTrue(renderer.render(.itemStarted(command))?.contains("$ ls") == true)
        _ = renderer.render(.itemDelta(itemID: "c", channel: .output, text: "a\n"))
        var finished = command
        finished.kind = .command(command: "ls", output: "a\n", exitCode: 0)
        XCTAssertNil(renderer.render(.itemCompleted(finished)))
    }

    func testRendererPrintsUnstreamedCommandOutputOnce() {
        var renderer = AgentTerminalRenderer()
        let command = AgentItem(
            id: "c", kind: .command(command: "ls", output: "", exitCode: nil),
            status: .inProgress, native: nil
        )
        _ = renderer.render(.itemStarted(command))
        var finished = command
        finished.kind = .command(command: "ls", output: "a", exitCode: 0)
        XCTAssertEqual(renderer.render(.itemCompleted(finished)), "a\r\n")
        XCTAssertEqual(
            renderer.render(.turnCompleted(turnID: nil, outcome: .failed(nil))),
            "\r\n\u{001B}[31mTurn failed.\u{001B}[0m\r\n"
        )
    }
}
