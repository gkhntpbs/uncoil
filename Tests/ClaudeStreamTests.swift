import XCTest
@testable import Uncoil

private func decode(_ line: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) ?? .null
}

private func normalize(_ lines: [String]) -> [AgentEvent] {
    var normalizer = ClaudeEventNormalizer()
    return lines.flatMap { line -> [AgentEvent] in
        let value = decode(line)
        // Control traffic is the session's, not the normalizer's.
        if ["control_request", "control_response"].contains(value.objectValue?["type"]?.stringValue ?? "") {
            return []
        }
        return normalizer.events(for: value)
    }
}

private func timeline(_ events: [AgentEvent]) -> AgentTimeline {
    var timeline = AgentTimeline()
    events.forEach { timeline.apply($0) }
    return timeline
}

// MARK: - Normalizer, against recorded output

final class ClaudeEventNormalizerTests: XCTestCase {
    func testARecordedTurnBecomesACommandAndAReply() throws {
        let events = normalize(ClaudeStreamFixtures.turn1)
        guard case .sessionBound(let id)? = events.first else { return XCTFail("\(events.prefix(1))") }
        XCTAssertEqual(id, "bc45feb2-2272-4640-90df-2322fe4f64ce")

        let folded = timeline(events)
        let kinds = folded.items.map(\.kind.name)
        XCTAssertEqual(kinds, ["reasoning", "command", "reasoning", "agent_message"])
        let command = try XCTUnwrap(folded.items.first { $0.kind.name == "command" })
        XCTAssertEqual(command.kind, .command(command: "echo probe-ok", output: "probe-ok", exitCode: nil))
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(folded.items.last?.kind, .agentMessage(text: "done"))
        XCTAssertEqual(folded.lastTurnOutcome, .completed)
        XCTAssertFalse(folded.turnInProgress)
        XCTAssertEqual(folded.runState, .idle)
    }

    func testStreamedTextAndItsFinalFormAreOneItem() {
        let events = normalize(ClaudeStreamFixtures.turn1)
        let deltaIDs = Set(events.compactMap { event -> String? in
            if case .itemDelta(let id, .text, _) = event { return id }
            return nil
        })
        let replyIDs = Set(events.compactMap { event -> String? in
            if case .itemCompleted(let item) = event, case .agentMessage = item.kind { return item.id }
            return nil
        })
        XCTAssertFalse(deltaIDs.isEmpty)
        XCTAssertEqual(deltaIDs, replyIDs, "a delta must land on the item its final form completes")
    }

    func testADeniedToolAndAnInterruptedTurnAreSaidSo() {
        let events = normalize(ClaudeStreamFixtures.turn2)
        XCTAssertTrue(events.contains { event in
            if case .notice(let notice) = event { return notice.level == .warning && notice.message.contains("needs approval") }
            return false
        })
        let outcomes = events.compactMap { event -> AgentTurnOutcome? in
            if case .turnCompleted(_, let outcome) = event { return outcome }
            return nil
        }
        XCTAssertEqual(outcomes, [.completed, .interrupted])
        let failed = timeline(events).items.first { $0.kind.name == "command" }
        XCTAssertEqual(failed?.status, .failed)
    }

    func testThePermissionRequestBecomesAnApproval() throws {
        let line = try XCTUnwrap(ClaudeStreamFixtures.turn3.first { $0.contains("can_use_tool") })
        let object = try XCTUnwrap(decode(line).objectValue)
        let approval = ClaudeEventNormalizer.approval(
            requestID: object["request_id"]?.stringValue ?? "",
            request: object["request"]?.objectValue ?? [:])
        XCTAssertEqual(approval.kind, .command)
        XCTAssertEqual(approval.title, "touch probe-file.txt")
        XCTAssertEqual(approval.decisions, ["accept", "acceptForSession", "decline"])
    }

    func testToolNamesMapToUncoilsKinds() {
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "Edit", input: ["file_path": .string("/a.swift")]),
            .fileChange(paths: ["/a.swift"]))
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "mcp__uncoil__uncoil_sessions", input: [:]),
            .toolCall(AgentToolCall(origin: .mcp(server: "uncoil"), name: "uncoil_sessions")))
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "mcp__claude_ai__Docs__query", input: [:]),
            .toolCall(AgentToolCall(origin: .mcp(server: "claude_ai__Docs"), name: "query")))
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "Task", input: ["subagent_type": .string("Explore")]),
            .toolCall(AgentToolCall(origin: .delegation, name: "Explore")))
        XCTAssertEqual(
            ClaudeEventNormalizer.toolKind(name: "Read", input: [:]),
            .toolCall(AgentToolCall(origin: .agent, name: "Read")))
    }

    func testASubagentsOwnStreamStaysOutOfTheMainTimeline() {
        var normalizer = ClaudeEventNormalizer()
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_x","message":{"id":"m","content":[{"type":"text","text":"inside"}]}}"#
        XCTAssertEqual(normalizer.events(for: decode(line)), [])
    }

    func testHistoryIsReadFromTheTranscriptWithTheUsersPrompts() {
        let transcript = [
            #"{"type":"queue-operation"}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"run it"}]}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt","is_error":false}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"id":"m9","content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"one file"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
        ].joined(separator: "\n")
        let items = ClaudeEventNormalizer.history(transcript: transcript)
        XCTAssertEqual(items.map(\.kind), [
            .userMessage(text: "run it", attachments: []),
            .command(command: "ls", output: "a.txt", exitCode: nil),
            .agentMessage(text: "one file"),
        ])
        XCTAssertTrue(items.allSatisfy { $0.status == .completed })
    }

    func testHistoryFromDiskReadsOnlyTheTailItNeeds() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "x", count: 2_000)
        var lines: [String] = []
        for index in 0..<400 {
            lines.append(#"{"type":"user","uuid":"u\#(index)","message":{"role":"user","content":[{"type":"text","text":"prompt \#(index) \#(filler)"}]}}"#)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        // A window far smaller than the file has to grow until it holds the
        // limit, and must never surface a line cut in half.
        let items = ClaudeEventNormalizer.history(contentsOf: url, limit: 50, chunkSize: 8_000)
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(items.map(\.id).last, "u399")
        XCTAssertEqual(items.map(\.id).first, "u350")
    }

    func testHistoryFromDiskOfASmallFileReadsItAll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"type":"user","uuid":"only","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeEventNormalizer.history(contentsOf: url).map(\.id), ["only"])
    }
}

// MARK: - Command line

final class ClaudeStreamArgumentsTests: XCTestCase {
    private func record(_ selection: AgentLaunchSelection? = nil) -> SessionRecord {
        var record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "t")
        record.launchSelection = selection
        return record
    }

    func testANewSessionIsNamedAndAskedForStructuredPermissions() {
        let arguments = ClaudeStreamProtocol.arguments(
            record: record(), resume: .fresh(nil), newSessionID: "new-id",
            mcpConfigPath: "/tmp/mcp.json", scope: .unrestricted, modeArguments: [])
        XCTAssertEqual(Array(arguments.prefix(1)), ["-p"])
        for pair in [["--input-format", "stream-json"], ["--output-format", "stream-json"],
                     ["--permission-prompt-tool", "stdio"], ["--session-id", "new-id"],
                     ["--mcp-config", "/tmp/mcp.json"]] {
            XCTAssertTrue(arguments.contains(pair: pair), "\(pair) missing from \(arguments)")
        }
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertFalse(arguments.contains("--resume"))
        XCTAssertFalse(arguments.contains("--strict-mcp-config"))
    }

    func testAResumableConversationIsResumed() {
        let arguments = ClaudeStreamProtocol.arguments(
            record: record(), resume: .resume("old-id"), newSessionID: "new-id",
            mcpConfigPath: nil, scope: .unrestricted, modeArguments: [])
        XCTAssertTrue(arguments.contains(pair: ["--resume", "old-id"]))
        XCTAssertFalse(arguments.contains("--session-id"))
    }

    func testTheLaunchSelectionIsCarriedAndItsModeWins() {
        let chosen = ClaudeStreamProtocol.arguments(
            record: record(AgentLaunchSelection(model: "opus", effort: "high", workingMode: .plan)),
            resume: .fresh(nil), newSessionID: "n", mcpConfigPath: nil,
            scope: .unrestricted, modeArguments: ["--permission-mode", "acceptEdits"])
        XCTAssertTrue(chosen.contains(pair: ["--model", "opus"]))
        XCTAssertTrue(chosen.contains(pair: ["--effort", "high"]))
        XCTAssertFalse(chosen.contains("acceptEdits"), "a chosen mode replaces the default one")

        let defaulted = ClaudeStreamProtocol.arguments(
            record: record(AgentLaunchSelection(model: "opus")),
            resume: .fresh(nil), newSessionID: "n", mcpConfigPath: nil,
            scope: .unrestricted, modeArguments: ["--permission-mode", "acceptEdits"])
        XCTAssertTrue(defaulted.contains(pair: ["--permission-mode", "acceptEdits"]))
    }

    func testAllowingForTheSessionNeverWritesTheProjectsSettings() throws {
        let line = try XCTUnwrap(ClaudeStreamFixtures.turn3.first { $0.contains("can_use_tool") })
        let request = try XCTUnwrap(decode(line).objectValue?["request"]?.objectValue)
        let response = ClaudeStreamProtocol.permissionResponse(
            requestID: "r1", request: request, decision: "acceptForSession")
        let answer = response.objectValue?["response"]?.objectValue?["response"]?.objectValue
        XCTAssertEqual(answer?["behavior"], .string("allow"))
        XCTAssertEqual(answer?["updatedInput"], request["input"])
        let updates = answer?["updatedPermissions"]?.arrayValue ?? []
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0.objectValue?["destination"] == .string("session") })
        XCTAssertFalse(updates.contains { $0.objectValue?["type"] == .string("setMode") },
                       "a single approval must not change the session's mode")

        let declined = ClaudeStreamProtocol.permissionResponse(requestID: "r1", request: request, decision: "decline")
        XCTAssertEqual(
            declined.objectValue?["response"]?.objectValue?["response"]?.objectValue?["behavior"],
            .string("deny"))
    }
}

private extension Array where Element == String {
    func contains(pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        return indices.dropLast().contains { self[$0] == pair[0] && self[$0 + 1] == pair[1] }
    }
}

// MARK: - The session, driven line by line

@MainActor
final class FakeClaudeTransport: ClaudeStreamTransport {
    var onLine: ((Data) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private(set) var sent: [JSONValue] = []
    private(set) var started = false
    private(set) var terminated = false
    var failsToStart = false

    func start() throws {
        if failsToStart { throw ClaudeStreamError.notRunning }
        started = true
    }
    func send(_ line: Data) throws {
        sent.append((try? JSONDecoder().decode(JSONValue.self, from: line)) ?? .null)
    }
    func terminate() { terminated = true }

    func emit(_ line: String) { onLine?(Data(line.utf8)) }
    func emit(_ lines: [String]) { lines.forEach(emit) }
    func exit(_ code: Int32, _ detail: String = "") { onExit?(code, detail) }

    /// Messages of one type, in the order they were written.
    func written(_ type: String) -> [[String: JSONValue]] {
        sent.compactMap(\.objectValue).filter { $0["type"]?.stringValue == type }
    }
}

@MainActor
final class ClaudeStreamSessionTests: XCTestCase {
    private var transport: FakeClaudeTransport!
    private var hub: AgentEventHub!
    private var session: ClaudeStreamSession!
    private var record: SessionRecord!
    private var fellBack: [String] = []

    override func setUp() async throws {
        transport = FakeClaudeTransport()
        hub = AgentEventHub()
        fellBack = []
        record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "claude: t")
        session = ClaudeStreamSession(
            record: record, providerSessionID: "sid-1", transport: transport,
            terminal: nil, settings: nil, sessionStore: nil, projectStore: nil, hub: hub,
            fallback: { [unowned self] in self.fellBack.append($0) })
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Starts the session and answers its handshake as Claude does.
    private func startReady() async {
        session.start()
        await settle()
        let initialize = transport.written("control_request").first
        XCTAssertEqual(initialize?["request"]?.objectValue?["subtype"], .string("initialize"))
        let id = initialize?["request_id"]?.stringValue ?? ""
        transport.emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"commands":[]}}}"#)
        XCTAssertTrue(session.isReady)
    }

    func testTheSessionIsReadyOnlyOnceClaudeAnswersTheHandshake() async {
        session.start()
        await settle()
        XCTAssertTrue(transport.started)
        XCTAssertFalse(session.isReady)
        XCTAssertEqual(hub.timeline(for: record.id)?.providerSessionID, "sid-1")
        await startReadyAfterStart()
    }

    private func startReadyAfterStart() async {
        let id = transport.written("control_request").first?["request_id"]?.stringValue ?? ""
        transport.emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{}}}"#)
        XCTAssertTrue(session.isReady)
    }

    func testASubmittedPromptIsWrittenAndTheRecordedTurnFillsTheTimeline() async throws {
        await startReady()
        await session.submit("Use the Bash tool")
        let user = try XCTUnwrap(transport.written("user").first)
        XCTAssertEqual(user["session_id"], .string("sid-1"))
        let content = user["message"]?.objectValue?["content"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(content?["text"], .string("Use the Bash tool"))
        XCTAssertEqual(hub.timeline(for: record.id)?.turnInProgress, true)

        transport.emit(ClaudeStreamFixtures.turn1.filter { !$0.contains("control_response") })
        let folded = try XCTUnwrap(hub.timeline(for: record.id))
        XCTAssertFalse(folded.turnInProgress)
        XCTAssertEqual(folded.items.first?.kind, .userMessage(text: "Use the Bash tool", attachments: []))
        XCTAssertEqual(folded.items.last?.kind, .agentMessage(text: "done"))
    }

    func testAPermissionPromptIsAnsweredThroughTheApprovalItRaised() async throws {
        await startReady()
        await session.submit("touch it")
        let request = try XCTUnwrap(ClaudeStreamFixtures.turn3.first { $0.contains("can_use_tool") })
        transport.emit(request)
        let pending = try XCTUnwrap(hub.timeline(for: record.id)?.pendingApprovals.first)
        XCTAssertEqual(pending.title, "touch probe-file.txt")

        XCTAssertTrue(session.respond(toApproval: pending.id, decision: "accept"))
        let answer = try XCTUnwrap(transport.written("control_response").last?["response"]?.objectValue)
        XCTAssertEqual(answer["request_id"], .string(pending.id))
        XCTAssertEqual(answer["response"]?.objectValue?["behavior"], .string("allow"))
        XCTAssertEqual(hub.timeline(for: record.id)?.pendingApprovals, [])
        XCTAssertFalse(session.respond(toApproval: pending.id, decision: "accept"), "an approval is answered once")
    }

    func testARequestUncoilDoesNotServeIsStillAnswered() async {
        await startReady()
        transport.emit(#"{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback"}}"#)
        let answer = transport.written("control_response").last?["response"]?.objectValue
        XCTAssertEqual(answer?["request_id"], .string("h1"))
        XCTAssertEqual(answer?["subtype"], .string("error"))
    }

    func testInterruptIsSentOnlyWhileATurnRuns() async {
        await startReady()
        session.interrupt()
        XCTAssertEqual(transport.written("control_request").count, 1, "nothing to interrupt yet")
        await session.submit("count")
        session.interrupt()
        XCTAssertEqual(transport.written("control_request").last?["request"]?.objectValue?["subtype"],
                       .string("interrupt"))
    }

    func testAPromptBeforeTheHandshakeIsRefusedNotLost() async {
        session.start()
        await settle()
        await session.submit("too early")
        XCTAssertTrue(transport.written("user").isEmpty)
        XCTAssertEqual(hub.timeline(for: record.id)?.notices.last?.level, .error)
    }

    func testAClaudeThatExitsBeforeItIsReadyFallsBackToTheTerminal() async {
        session.start()
        await settle()
        transport.exit(1, "error: unknown option '--permission-prompt-tool'")
        XCTAssertEqual(fellBack.count, 1)
        XCTAssertTrue(fellBack[0].contains("--permission-prompt-tool"))
        XCTAssertFalse(session.isReady)
    }

    func testAClaudeThatExitsAfterwardsEndsTheSessionWithoutAFallback() async {
        await startReady()
        transport.exit(0)
        XCTAssertTrue(fellBack.isEmpty)
        XCTAssertFalse(session.isReady)
    }

    func testImagesGoWithTheNextPromptAsImages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        await startReady()
        await session.attach([AgentAttachment(kind: .image, url: image, promptPath: "shot.png")])
        await session.submit("what is this")
        let content = transport.written("user").first?["message"]?.objectValue?["content"]?.arrayValue ?? []
        let source = content.last?.objectValue?["source"]?.objectValue
        XCTAssertEqual(content.last?.objectValue?["type"], .string("image"))
        XCTAssertEqual(source?["media_type"], .string("image/png"))
        XCTAssertEqual(source?["data"], .string(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()))
    }

    /// The point of the whole thing: the control plane drives a structured
    /// Claude session with the same calls it uses for Codex, and cannot tell
    /// which it is talking to except by what the session reports.
    func testTheControlPlaneDrivesAClaudeSessionLikeAnyStructuredSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory)
        store.addProject(at: URL(fileURLWithPath: "/tmp/claude-mcp"))
        let caller = store.createSession(projectID: store.projects[0].id, provider: .codex, accountID: nil, title: "c")
        let target = store.createSession(projectID: store.projects[0].id, provider: .claude, accountID: nil, title: "t")
        let router = CapabilityRouter(
            projectStore: store, sessionStore: SessionStore(),
            audit: AuditLog(dataDirectory: directory), dataDirectory: directory)
        router.eventHub = hub
        session = ClaudeStreamSession(
            record: target, providerSessionID: "sid-2", transport: transport,
            terminal: nil, settings: nil, sessionStore: nil, projectStore: nil, hub: hub,
            fallback: { _ in })
        let claude = session!
        router.sessionControl = { $0.id == target.id ? claude : nil }
        await startReady()

        func call(_ action: String, _ args: [String: JSONValue]) async -> ControlEnvelope {
            await router.handle(ControlRequest(
                capability: "uncoil_sessions", action: action,
                args: args.merging(["session_id": .string(target.id.uuidString)]) { a, _ in a },
                caller_session_id: caller.id.uuidString,
                session_token: router.credentials.token(for: caller.id)))
        }
        let capabilities = await call("capabilities", [:])
        XCTAssertEqual(capabilities.data?.objectValue?["runtime"], .string("structured"))

        let submitted = await call("submit", ["input": .string("hello")])
        XCTAssertTrue(submitted.ok, "\(String(describing: submitted.error))")
        XCTAssertEqual(transport.written("user").count, 1)

        transport.emit(ClaudeStreamFixtures.turn1.filter { !$0.contains("control_response") })
        let events = await call("events", ["after_sequence": submitted.data?.objectValue?["after_sequence"] ?? .int(0)])
        let types = (events.data?.objectValue?["events"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["event"]?.objectValue?["type"]?.stringValue }
        XCTAssertEqual(types.first, "turn_started")
        XCTAssertEqual(types.last, "run_state")
        XCTAssertTrue(types.contains("turn_completed"))
    }
}

// MARK: - Against the installed CLI

/// The real `claude` on this machine, through the real pipes — the handshake
/// only, which Claude answers locally, so it costs no tokens and needs no
/// turn. Skipped unless asked for: run with
/// `TEST_RUNNER_UNCOIL_LIVE_CLAUDE=1` in the environment of `xcodebuild test`.
@MainActor
final class ClaudeStreamLiveTests: XCTestCase {
    func testTheInstalledClaudeAnswersTheStructuredHandshake() async throws {
        guard ProcessInfo.processInfo.environment["UNCOIL_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set UNCOIL_LIVE_CLAUDE=1 to run against the installed Claude Code")
        }
        let binary = try XCTUnwrap(AgentAdapterSupport.locateBinary("claude"), "claude is not installed")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "live")
        let transport = ClaudeProcessTransport(
            executable: binary,
            arguments: ClaudeStreamProtocol.arguments(
                record: record, resume: .fresh(nil), newSessionID: UUID().uuidString.lowercased(),
                mcpConfigPath: nil, scope: .unrestricted, modeArguments: []),
            directory: directory.path,
            environment: ProcessInfo.processInfo.environment)
        var lines: [JSONValue] = []
        var exit: Int32?
        transport.onLine = { lines.append((try? JSONDecoder().decode(JSONValue.self, from: $0)) ?? .null) }
        transport.onExit = { code, _ in exit = code }
        try transport.start()
        try transport.send(ClaudeStreamProtocol.line(ClaudeStreamProtocol.initialize(requestID: "live-1")))

        let deadline = Date().addingTimeInterval(30)
        func answered() -> Bool {
            lines.contains {
                $0.objectValue?["type"] == .string("control_response")
                    && $0.objectValue?["response"]?.objectValue?["request_id"] == .string("live-1")
            }
        }
        while Date() < deadline, !answered(), exit == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(exit, "claude exited during the handshake")
        XCTAssertTrue(answered(), "no answer to initialize within 30 s")
        XCTAssertEqual(
            lines.first { $0.objectValue?["type"] == .string("control_response") }?
                .objectValue?["response"]?.objectValue?["subtype"],
            .string("success"))

        transport.terminate()
        try await Task.sleep(nanoseconds: 500_000_000)
        // Writing to a Claude that is gone must fail, not take Uncoil with it.
        XCTAssertThrowsError(try transport.send(ClaudeStreamProtocol.line(.object([:]))))
    }
}
