import XCTest
@testable import Uncoil

/// The MCP control plane's contract, stated as behaviour a client can rely
/// on — error codes, identity, capability discovery, pagination, cancellation
/// and idempotency — rather than as facts about one implementation.
///
/// Everything goes through `CapabilityRouter.handle`, the same entry the
/// socket server uses, with sessions played by `FakeAgentSessionControl`. A
/// refactor of the app, the runtime or the transport that changes what a
/// client sees fails here.
@MainActor
final class McpContractTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectStore!
    private var sessionStore: SessionStore!
    private var settings: SettingsStore!
    private var router: CapabilityRouter!
    private var hub: AgentEventHub!
    private var caller: SessionRecord!
    private var child: SessionRecord!
    private var controls: [UUID: FakeAgentSessionControl] = [:]
    private var launched: [(record: SessionRecord, prompt: String?)] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-contract-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(directory: tempDir)
        sessionStore = SessionStore()
        settings = SettingsStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/contract-demo"))
        let project = store.projects[0]
        caller = store.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "claude: root")
        child = store.createSession(projectID: project.id, provider: .codex, accountID: nil, title: "codex: child")
        store.updateSession(child.id) { $0.parentSessionID = self.caller.id }
        child = store.sessions.first { $0.id == child.id }
        hub = AgentEventHub()
        router = CapabilityRouter(
            projectStore: store, sessionStore: sessionStore, settings: settings,
            audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir)
        router.permissions = PermissionService(dataDirectory: tempDir)
        router.eventHub = hub
        controls = [:]
        router.sessionControl = { [unowned self] record in self.controls[record.id] }
        launched = []
        router.childLauncher = { [unowned self] record, prompt in self.launched.append((record, prompt)) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private enum Signature { case valid, none, forged, borrowed(SessionRecord) }

    private func call(
        _ capability: String, _ action: String, _ args: [String: JSONValue] = [:],
        as session: SessionRecord? = nil, signature: Signature = .valid, version: Int = ControlProtocol.version
    ) async -> ControlEnvelope {
        let who = session ?? caller!
        let token: String?
        switch signature {
        case .valid: token = router.credentials.token(for: who.id)
        case .none: token = nil
        case .forged: token = "forged-token"
        case .borrowed(let other): token = router.credentials.token(for: other.id)
        }
        return await router.handle(ControlRequest(
            version: version, capability: capability, action: action, args: args,
            caller_session_id: who.id.uuidString, session_token: token))
    }

    private func sessions(_ action: String, _ args: [String: JSONValue] = [:],
                          signature: Signature = .valid) async -> ControlEnvelope {
        await call("uncoil_sessions", action, args, signature: signature)
    }

    private func target(_ record: SessionRecord, _ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        extra.merging(["session_id": .string(record.id.uuidString)]) { current, _ in current }
    }

    private func data(_ envelope: ControlEnvelope, file: StaticString = #filePath, line: UInt = #line) -> [String: JSONValue] {
        XCTAssertTrue(envelope.ok, "\(String(describing: envelope.error))", file: file, line: line)
        return envelope.data?.objectValue ?? [:]
    }

    private func detail(_ envelope: ControlEnvelope, _ key: String) -> JSONValue? {
        envelope.error?.details?.objectValue?[key]
    }

    private func running(_ fake: FakeAgentSessionControl) -> FakeAgentSessionControl {
        controls[fake.sessionID] = fake
        return fake
    }

    private func publish(_ event: AgentEvent, to record: SessionRecord? = nil) {
        hub.publish(event, sessionID: (record ?? child).id, provider: .codex)
    }

    private func message(_ id: String, _ text: String) -> AgentItem {
        AgentItem(id: id, kind: .agentMessage(text: text), status: .completed, native: nil)
    }

    // MARK: - Invalid requests

    func testUnknownCapabilityAndActionAreInvalidAndSayWhatIsValid() async {
        let capability = await call("uncoil_nope", "list")
        XCTAssertEqual(capability.error?.code, "INVALID_ACTION")
        XCTAssertNotNil(detail(capability, "valid_capabilities"))

        let action = await sessions("teleport")
        XCTAssertEqual(action.error?.code, "INVALID_ACTION")
        XCTAssertTrue(detail(action, "valid_actions")?.arrayValue?.contains(.string("submit")) ?? false)
    }

    func testANewerRequestVersionIsRefusedNotMisread() async {
        let envelope = await call("uncoil_sessions", "list", version: ControlProtocol.version + 1)
        XCTAssertEqual(envelope.error?.code, "UNSUPPORTED_VERSION")
        XCTAssertEqual(detail(envelope, "server_version"), .int(ControlProtocol.version))
    }

    func testAMinimalOrOlderRequestIsStillRead() throws {
        let decoded = try JSONDecoder().decode(
            ControlRequest.self, from: Data(#"{"capability":"uncoil_system","action":"status"}"#.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.args, [:])
        XCTAssertNil(decoded.session_token)
        XCTAssertFalse(decoded.request_id.isEmpty)
    }

    func testUnknownSession() async {
        let envelope = await sessions("timeline", ["session_id": .string(UUID().uuidString)])
        XCTAssertEqual(envelope.error?.code, "UNKNOWN_SESSION")
    }

    // MARK: - Identity

    func testAForgedTokenGetsNothingNotEvenReads() async {
        let envelope = await sessions("list", signature: .forged)
        XCTAssertEqual(envelope.error?.code, "IDENTITY_UNVERIFIED")
        XCTAssertEqual(detail(envelope, "reason"), .string("mismatch"))
    }

    func testAnotherSessionsTokenDoesNotProveThisOne() async {
        _ = running(.structured(child.id))
        let envelope = await sessions("submit", target(child, ["input": .string("hi")]),
                                      signature: .borrowed(child))
        XCTAssertEqual(envelope.error?.code, "IDENTITY_UNVERIFIED")
        XCTAssertEqual(controls[child.id]?.submitted, [])
    }

    func testAnUnverifiedCallerMayReadButNotAct() async {
        let fake = running(.structured(child.id))
        let read = await sessions("list", signature: .none)
        XCTAssertTrue(read.ok)

        let act = await sessions("submit", target(child, ["input": .string("hi")]), signature: .none)
        XCTAssertEqual(act.error?.code, "IDENTITY_UNVERIFIED")
        XCTAssertEqual(detail(act, "reason"), .string("unverified"))
        XCTAssertEqual(fake.submitted, [], "an unverified call must not reach the session")
    }

    func testACallWithNoCallerCannotAct() async {
        _ = running(.structured(child.id))
        let envelope = await router.handle(ControlRequest(
            capability: "uncoil_sessions", action: "submit",
            args: target(child, ["input": .string("hi")])))
        XCTAssertEqual(envelope.error?.code, "UNKNOWN_SESSION")
        XCTAssertEqual(controls[child.id]?.submitted, [])
    }

    func testDescribeNeedsNoCallerAndReportsTheCallersStanding() async {
        let anonymous = await router.handle(ControlRequest(capability: "uncoil_system", action: "describe"))
        let body = data(anonymous)
        XCTAssertEqual(body["protocol"]?.objectValue?["version"], .int(ControlProtocol.version))
        XCTAssertEqual(body["caller"]?.objectValue?["verification"], .string("anonymous"))

        let verified = data(await call("uncoil_system", "describe"))
        XCTAssertEqual(verified["caller"]?.objectValue?["verification"], .string("verified"))
        XCTAssertEqual(verified["caller"]?.objectValue?["may_act"], .bool(true))
    }

    func testEveryActionIsClassifiedAsReadOrEffect() async {
        let body = data(await call("uncoil_system", "describe"))
        var kinds: [String: String] = [:]
        for capability in body["capabilities"]?.arrayValue ?? [] {
            let name = capability.objectValue?["name"]?.stringValue ?? ""
            for action in capability.objectValue?["actions"]?.arrayValue ?? [] {
                let object = action.objectValue ?? [:]
                kinds["\(name).\(object["name"]?.stringValue ?? "")"] = object["kind"]?.stringValue
            }
        }
        XCTAssertEqual(kinds["uncoil_sessions.timeline"], "read")
        XCTAssertEqual(kinds["uncoil_sessions.events"], "read")
        XCTAssertEqual(kinds["uncoil_sessions.submit"], "effect")
        XCTAssertEqual(kinds["uncoil_sessions.create_session"], "effect")
        XCTAssertEqual(kinds["uncoil_sessions.respond_approval"], "effect")
        XCTAssertEqual(kinds["uncoil_agents.list"], "read")
        // The read table may only name actions that exist.
        for (capability, reads) in HelpRegistry.readActions {
            let actions = Set(HelpRegistry.actions(for: capability))
            XCTAssertTrue(reads.isSubset(of: actions), "\(capability): \(reads.subtracting(actions))")
        }
    }

    func testTheMcpEnvironmentCarriesATokenOnlyThatSessionVerifies() {
        let credentials = SessionCredentials(directory: tempDir)
        let environment = ControlProtocol.mcpEnvironment(for: caller, socketPath: "/tmp/x.sock", credentials: credentials)
        let token = environment[ControlProtocol.Environment.sessionToken] ?? ""
        XCTAssertEqual(environment[ControlProtocol.Environment.sessionID], caller.id.uuidString)
        XCTAssertTrue(credentials.verify(token, for: caller.id))
        XCTAssertFalse(credentials.verify(token, for: child.id))
        // The secret persists: a session launched before a restart still proves itself.
        XCTAssertTrue(SessionCredentials(directory: tempDir).verify(token, for: caller.id))
    }

    // MARK: - Capability discovery

    func testAStructuredSessionAdvertisesStructuredOperations() async {
        _ = running(.structured(child.id))
        let body = data(await sessions("capabilities", target(child)))
        let supported = Set((body["supported"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(body["runtime"], .string("structured"))
        XCTAssertTrue(supported.isSuperset(of: ["timeline", "events", "submit", "interrupt", "respond_approval"]))
        XCTAssertFalse(supported.contains("send_raw"))
        XCTAssertEqual(body["operations"]?.objectValue?["submit"]?.objectValue?["via"], .string("structured"))
    }

    func testATerminalSessionAdvertisesTerminalOperations() async {
        _ = running(.terminal(child.id))
        let body = data(await sessions("capabilities", target(child)))
        let supported = Set((body["supported"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(body["runtime"], .string("terminal"))
        XCTAssertEqual(supported, ["read_output", "submit", "interrupt", "send_raw"])
        XCTAssertNotNil(body["operations"]?.objectValue?["timeline"]?.objectValue?["reason"]?.stringValue)
    }

    func testAStoppedSessionAdvertisesResumeOnlyWhenItHasAConversation() async {
        let before = data(await sessions("capabilities", target(child)))
        XCTAssertEqual(before["running"], .bool(false))
        XCTAssertEqual(before["supported"], .array([]))

        store.updateSession(child.id) { $0.providerSessionID = "thread-1" }
        let after = data(await sessions("capabilities", target(child)))
        XCTAssertEqual(after["supported"], .array([.string("resume")]))
    }

    func testAnOperationTheSessionLacksIsUnsupportedNotFailed() async {
        _ = running(.terminal(child.id))
        let approval = await sessions("respond_approval", target(child, [
            "approval_id": .string("a1"), "decision": .string("accept"),
        ]))
        // The approval grant is checked first; give it so the capability is what answers.
        XCTAssertEqual(approval.error?.code, "PERMISSION_REQUIRED")
        grantCaller("sessions.approve")
        let unsupported = await sessions("respond_approval", target(child, [
            "approval_id": .string("a1"), "decision": .string("accept"),
        ]))
        XCTAssertEqual(unsupported.error?.code, "UNSUPPORTED_CAPABILITY")
        XCTAssertNotNil(detail(unsupported, "supported"))

        let timeline = await sessions("timeline", target(child))
        XCTAssertEqual(timeline.error?.code, "UNSUPPORTED_CAPABILITY")
    }

    // MARK: - Effects

    func testAStaleSessionIsReportedAsNotRunning() async {
        let envelope = await sessions("submit", target(child, ["input": .string("hi")]))
        XCTAssertEqual(envelope.error?.code, "SESSION_NOT_RUNNING")
        XCTAssertEqual(detail(envelope, "next"), .string("create_session"))
    }

    func testAnAgentThatIsNotReadyIsRetryable() async {
        let fake = running(.structured(child.id))
        fake.isReady = false
        let envelope = await sessions("submit", target(child, ["input": .string("hi")]))
        XCTAssertEqual(envelope.error?.code, "PROVIDER_UNAVAILABLE")
        XCTAssertEqual(envelope.error?.retryable, true)
    }

    func testASuccessfulStructuredSubmitCanBeFollowedThroughEvents() async {
        let fake = running(.structured(child.id))
        publish(.sessionBound(providerSessionID: "thread-1"))
        fake.onSubmit = { [unowned self] prompt in
            self.publish(.turnStarted(turnID: "t1"))
            self.publish(.itemCompleted(self.message("m1", "echo: \(prompt)")))
            self.publish(.turnCompleted(turnID: "t1", outcome: .completed))
        }
        let submitted = data(await sessions("submit", target(child, ["input": .string("hello")])))
        XCTAssertEqual(submitted["accepted"], .bool(true))
        XCTAssertEqual(submitted["via"], .string("structured"))
        XCTAssertEqual(submitted["after_sequence"], .int(1))
        XCTAssertEqual(fake.submitted, ["hello"])

        let events = data(await sessions("events", target(child, ["after_sequence": .int(1)])))
        let types = (events["events"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["event"]?.objectValue?["type"]?.stringValue }
        XCTAssertEqual(types, ["turn_started", "item_completed", "turn_completed"])
        XCTAssertEqual(events["next_after_sequence"], .int(4))
        XCTAssertEqual(events["gap"], .bool(false))
    }

    func testASessionCannotSubmitToItself() async {
        _ = running(.structured(caller.id))
        let envelope = await sessions("submit", target(caller, ["input": .string("hi")]))
        XCTAssertEqual(envelope.error?.code, "INVALID_RELATIONSHIP")
    }

    func testSubmittedInputLosesTerminalControlCharacters() async {
        let fake = running(.terminal(child.id))
        _ = await sessions("submit", target(child, ["input": .string("\u{1B}[31mhi\u{9B}2J\u{7F}")]))
        XCTAssertEqual(fake.submitted, ["[31mhi2J"])
    }

    func testInterruptReachesTheSession() async {
        let fake = running(.structured(child.id))
        let body = data(await sessions("interrupt", target(child)))
        XCTAssertEqual(body["via"], .string("structured"))
        XCTAssertEqual(fake.interrupts, 1)
    }

    func testAnsweringApprovalsNeedsItsOwnGrantAndAnOfferedDecision() async {
        let fake = running(.structured(child.id))
        fake.pendingApprovalIDs = ["a1"]
        publish(.approvalRequested(AgentApproval(
            id: "a1", kind: .command, title: "rm -rf build", detail: nil,
            decisions: ["accept", "decline"], native: nil)))

        let required = await sessions("respond_approval", target(child, [
            "approval_id": .string("a1"), "decision": .string("accept"),
        ]))
        XCTAssertEqual(required.error?.code, "PERMISSION_REQUIRED")
        XCTAssertEqual(detail(required, "grant_key"), .string("sessions.approve"))

        let request = router.permissions!.request(
            grantKey: "sessions.approve", from: caller.id.uuidString, target: child.id.uuidString)
        router.permissions!.grant(id: request.id)
        let invalid = await sessions("respond_approval", target(child, [
            "approval_id": .string("a1"), "decision": .string("maybe"),
        ]))
        XCTAssertEqual(invalid.error?.code, "INVALID_ARGUMENT")
        XCTAssertEqual(detail(invalid, "valid_decisions"), .array([.string("accept"), .string("decline")]))

        let answered = data(await sessions("respond_approval", target(child, [
            "approval_id": .string("a1"), "decision": .string("accept"),
        ])))
        XCTAssertEqual(answered["answered"], .bool(true))
        XCTAssertEqual(fake.answers.map(\.decision), ["accept"])
    }

    func testPermissionDeniedForAnUnrelatedSessionWithoutControlAll() async {
        store.updateSession(caller.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants.subtracting(["sessions.control_all"]))
        }
        let stranger = store.createSession(projectID: store.projects[0].id, provider: .codex, accountID: nil, title: "x")
        _ = running(.structured(stranger.id))
        let envelope = await sessions("submit", target(stranger, ["input": .string("hi")]))
        XCTAssertEqual(envelope.error?.code, "PERMISSION_REQUIRED")
        XCTAssertEqual(detail(envelope, "grant_key"), .string("sessions.control"))
    }

    func testResumeStartsAStoppedSessionBackInItsConversation() async {
        store.updateSession(child.id) { $0.providerSessionID = "thread-1" }
        let body = data(await sessions("resume", target(child, ["input": .string("carry on")])))
        XCTAssertEqual(body["provider_session_id"], .string("thread-1"))
        XCTAssertEqual(launched.map(\.record.id), [child.id])
        XCTAssertEqual(launched.first?.prompt, "carry on")

        _ = running(.structured(child.id))
        let again = await sessions("resume", target(child))
        XCTAssertEqual(again.error?.code, "INVALID_STATE_TRANSITION")
    }

    // MARK: - Idempotency

    func testAnEffectWithAnIdempotencyKeyRunsOnce() async {
        let fake = running(.structured(child.id))
        let args = target(child, ["input": .string("once"), "idempotency_key": .string("k1")])
        let first = await sessions("submit", args)
        let retry = await sessions("submit", args)
        XCTAssertTrue(first.ok && retry.ok)
        XCTAssertEqual(fake.submitted, ["once"])
        XCTAssertTrue(retry.warnings.contains { $0.hasPrefix("idempotent_replay") })
        XCTAssertNotEqual(first.request_id, retry.request_id)

        let conflict = await sessions("submit", target(child, [
            "input": .string("twice"), "idempotency_key": .string("k1"),
        ]))
        XCTAssertEqual(conflict.error?.code, "IDEMPOTENCY_CONFLICT")
        XCTAssertEqual(fake.submitted, ["once"])
    }

    func testARetryableFailureIsNotRememberedUnderItsKey() async {
        let fake = running(.structured(child.id))
        fake.isReady = false
        let args = target(child, ["input": .string("x"), "idempotency_key": .string("k2")])
        let first = await sessions("submit", args)
        XCTAssertEqual(first.error?.code, "PROVIDER_UNAVAILABLE")
        fake.isReady = true
        let second = await sessions("submit", args)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(fake.submitted, ["x"])
    }

    // MARK: - Timeline and events

    func testTimelinePagesBackwardsFromTheNewestItem() async {
        _ = running(.structured(child.id))
        for index in 1...5 { publish(.itemCompleted(message("m\(index)", "text \(index)"))) }

        func ids(_ body: [String: JSONValue]) -> [String] {
            (body["items"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
        }
        let first = data(await sessions("timeline", target(child, ["limit": .int(2)])))
        XCTAssertEqual(ids(first), ["m4", "m5"])
        XCTAssertEqual(first["has_more"], .bool(true))
        XCTAssertEqual(first["state"]?.objectValue?["item_count"], .int(5))

        let second = data(await sessions("timeline", target(child, [
            "limit": .int(2), "before_item_id": first["next_before_item_id"] ?? .null,
        ])))
        XCTAssertEqual(ids(second), ["m2", "m3"])

        let last = data(await sessions("timeline", target(child, [
            "limit": .int(2), "before_item_id": second["next_before_item_id"] ?? .null,
        ])))
        XCTAssertEqual(ids(last), ["m1"])
        XCTAssertEqual(last["has_more"], .bool(false))
    }

    func testATimelineOutlivesItsProcess() async {
        publish(.itemCompleted(message("m1", "done")))
        let body = data(await sessions("timeline", target(child)))
        XCTAssertEqual((body["items"]?.arrayValue ?? []).count, 1)
    }

    func testEventsReportAGapWhenTheCallerFellBehind() async {
        _ = running(.structured(child.id))
        for index in 0..<(AgentEventHub.recordLimit + 5) {
            publish(.itemDelta(itemID: "m", channel: .text, text: "\(index)"))
        }
        let behind = data(await sessions("events", target(child, ["limit": .int(1)])))
        XCTAssertEqual(behind["gap"], .bool(true))
        XCTAssertEqual(behind["oldest_sequence"], .int(6))

        let ahead = data(await sessions("events", target(child, ["after_sequence": .int(999_999)])))
        XCTAssertEqual(ahead["gap"], .bool(true), "a sequence from a replaced timeline must not be trusted")
    }

    func testAnEventsWaitReturnsAsSoonAsAnEventArrives() async {
        _ = running(.structured(child.id))
        let started = Date()
        let waiting = Task { await self.sessions("events", self.target(self.child, ["wait_s": .int(10)])) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        publish(.turnStarted(turnID: "t1"))
        let body = data(await waiting.value)
        XCTAssertEqual((body["events"]?.arrayValue ?? []).count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAnEventsWaitEndsWhenTheSessionStops() async {
        _ = running(.structured(child.id))
        let waiting = Task { await self.sessions("events", self.target(self.child, ["wait_s": .int(10)])) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        controls[child.id] = nil
        let body = data(await waiting.value)
        XCTAssertEqual(body["running"], .bool(false))
    }

    func testACancelledRequestStopsWaitingAndSaysSo() async {
        _ = running(.structured(child.id))
        let started = Date()
        let waiting = Task { await self.sessions("events", self.target(self.child, ["wait_s": .int(30)])) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        waiting.cancel()
        let envelope = await waiting.value
        XCTAssertEqual(envelope.error?.code, "CANCELLED")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTheMcpServerWaitsForTheActionsOwnTimeout() {
        XCTAssertEqual(ControlProtocol.callTimeout(args: [:]), ControlProtocol.defaultTimeout)
        XCTAssertEqual(ControlProtocol.callTimeout(args: ["timeout_s": .int(120)]), 135)
        XCTAssertEqual(ControlProtocol.callTimeout(args: ["wait_s": .int(60)]), 75)
        XCTAssertEqual(ControlProtocol.callTimeout(args: ["timeout_s": .int(10_000)]), ControlProtocol.maximumTimeout)
    }

    // MARK: - Session creation

    private func grantCaller(_ grants: String...) {
        store.updateSession(caller.id) { $0.capabilities = Array(PolicyEngine.defaultGrants) + grants }
        caller = store.sessions.first { $0.id == caller.id }
    }

    func testCreateSessionCarriesEveryLaunchChoice() async {
        let account = settings.addAccount(provider: .codex, name: "Work")
        router.launchCapabilities = { provider in
            AgentLaunchCapabilities(
                efforts: [.init(id: "low", label: "low"), .init(id: "high", label: "high")],
                workingModes: AgentWorkingMode.options(for: provider))
        }
        let body = data(await sessions("create_session", [
            "provider": .string("codex"),
            "account_id": .string(account.id.uuidString),
            "model": .string("gpt-5.5"),
            "effort": .string("high"),
            "working_mode": .string("readOnly"),
            "initial_prompt": .string("Review the diff"),
            "title": .string("Reviewer"),
        ]))
        let id = UUID(uuidString: body["session_id"]?.stringValue ?? "")
        let record = store.sessions.first { $0.id == id }
        XCTAssertEqual(record?.provider, .codex)
        XCTAssertEqual(record?.accountID, account.id)
        XCTAssertEqual(record?.parentSessionID, caller.id)
        XCTAssertEqual(record?.launchSelection, AgentLaunchSelection(model: "gpt-5.5", effort: "high", workingMode: .readOnly))
        XCTAssertEqual(record?.title, "Reviewer")
        XCTAssertEqual(launched.first?.prompt, "Review the diff")
        XCTAssertEqual(body["launch"]?.objectValue?["effort"], .string("high"))
        XCTAssertEqual(body["child_session_id"], body["session_id"])
    }

    func testCreateSessionRefusesChoicesTheAgentDoesNotOffer() async {
        router.launchCapabilities = { _ in
            AgentLaunchCapabilities(efforts: [.init(id: "low", label: "low")])
        }
        let effort = await sessions("create_session", ["provider": .string("codex"), "effort": .string("ultra")])
        XCTAssertEqual(effort.error?.code, "INVALID_ARGUMENT")
        XCTAssertNotNil(detail(effort, "valid_efforts"))

        let mode = await sessions("create_session", ["provider": .string("codex"), "working_mode": .string("plan")])
        XCTAssertEqual(mode.error?.code, "INVALID_ARGUMENT")

        let claudeAccount = settings.addAccount(provider: .claude, name: "Personal")
        let account = await sessions("create_session", [
            "provider": .string("codex"), "account_id": .string(claudeAccount.id.uuidString),
        ])
        XCTAssertEqual(account.error?.code, "INVALID_ARGUMENT")

        let shell = await sessions("create_session", ["provider": .string("terminal")])
        XCTAssertEqual(shell.error?.code, "INVALID_ARGUMENT")
        XCTAssertTrue(launched.isEmpty)
    }

    func testCreateSessionReportsAnAgentThatIsNotInstalled() async {
        router.providerInstalled = { $0 != .gemini }
        let envelope = await sessions("create_session", ["provider": .string("gemini")])
        XCTAssertEqual(envelope.error?.code, "PROVIDER_UNAVAILABLE")
    }

    func testCreateSessionWithAKeyCreatesOneSession() async {
        let args: [String: JSONValue] = ["provider": .string("codex"), "idempotency_key": .string("job-1")]
        let first = data(await sessions("create_session", args))
        let retry = await sessions("create_session", args)
        XCTAssertEqual(retry.data?.objectValue?["session_id"], first["session_id"])
        XCTAssertEqual(retry.data?.objectValue?["idempotent_hit"], .bool(true))
        XCTAssertEqual(launched.count, 1)
    }

    func testCreateSessionNeverGrantsMoreThanTheCallerHolds() async {
        store.updateSession(caller.id) {
            $0.capabilities = ["projects.read", "sessions.read", "sessions.create_children"]
        }
        let body = data(await sessions("create_session", [
            "provider": .string("codex"),
            "capabilities": .array([.string("sessions.read"), .string("computer.foreground_control")]),
        ]))
        XCTAssertEqual(body["capabilities"], .array([.string("sessions.read")]))
    }

    // MARK: - Agents

    func testAgentsListAccountsAndInspectOffersLaunchOptions() async {
        let account = settings.addAccount(provider: .codex, name: "Work")
        router.launchCapabilities = { _ in
            AgentLaunchCapabilities(efforts: [.init(id: "high", label: "high")], defaultModelDetail: "gpt-5.5")
        }
        let list = data(await call("uncoil_agents", "list"))
        let codex = (list["agents"]?.arrayValue ?? [])
            .compactMap(\.objectValue).first { $0["provider"] == .string("codex") }
        XCTAssertTrue((codex?["accounts"]?.arrayValue ?? []).contains {
            $0.objectValue?["id"] == .string(account.id.uuidString)
        })
        XCTAssertFalse((list["agents"]?.arrayValue ?? []).contains {
            $0.objectValue?["provider"] == .string("terminal")
        })

        let inspect = data(await call("uncoil_agents", "inspect", ["provider": .string("codex")]))
        XCTAssertEqual(inspect["launch"]?.objectValue?["default_model"], .string("gpt-5.5"))

        let shell = await call("uncoil_agents", "inspect", ["provider": .string("terminal")])
        XCTAssertEqual(shell.error?.code, "INVALID_ARGUMENT")
    }
}

/// Cancellation across the real socket: an MCP client hanging up must end the
/// work it asked for, not leave it running until its own deadline.
@MainActor
final class ControlPlaneCancellationTests: XCTestCase {
    func testClosingTheConnectionCancelsTheRequest() async throws {
        // A short path: sockaddr_un has room for ~104 bytes.
        var projectRoot = URL(fileURLWithPath: #filePath)
        while projectRoot.path != "/" {
            projectRoot.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".git").path) { break }
        }
        let directory = projectRoot
            .appendingPathComponent(".build-cache/s", isDirectory: true)
            .appendingPathComponent(String(UUID().uuidString.prefix(4)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(directory: directory)
        store.addProject(at: URL(fileURLWithPath: "/tmp/cancel-demo"))
        let caller = store.createSession(projectID: store.projects[0].id, provider: .claude, accountID: nil, title: "c")
        let target = store.createSession(projectID: store.projects[0].id, provider: .codex, accountID: nil, title: "t")
        let router = CapabilityRouter(
            projectStore: store, sessionStore: SessionStore(),
            audit: AuditLog(dataDirectory: directory), dataDirectory: directory)
        let hub = AgentEventHub()
        router.eventHub = hub
        hub.publish(.turnStarted(turnID: nil), sessionID: target.id, provider: .codex)
        let fake = FakeAgentSessionControl.structured(target.id)
        var polls = 0
        router.sessionControl = { record in
            if record.id == target.id { polls += 1 }
            return record.id == target.id ? fake : nil
        }
        let path = directory.appendingPathComponent("control.sock").path
        let server = ControlPlaneServer(socketPath: path, router: router)
        try server.start()
        defer { server.stop() }

        let request = ControlRequest(
            capability: "uncoil_sessions", action: "events",
            args: ["session_id": .string(target.id.uuidString), "after_sequence": .int(1), "wait_s": .int(60)],
            caller_session_id: caller.id.uuidString,
            session_token: router.credentials.token(for: caller.id))
        let fd = try Self.connect(path)
        let line = try XCTUnwrap(Data.controlLine(request))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThan(polls, 0, "the wait should be running")
        close(fd)
        try await Task.sleep(nanoseconds: 600_000_000)
        let afterClose = polls
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(polls, afterClose, "the wait kept polling after its client hung up")
    }

    private static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        return fd
    }
}
