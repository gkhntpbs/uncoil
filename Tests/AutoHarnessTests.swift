import XCTest
@testable import Uncoil

/// A decision engine that answers what the test says.
struct FakeDecisionEngine: AutoDecisionEngine {
    var answer: @Sendable (AutoDecisionSchema) async throws -> AutoDecisionAnswer

    static func choosing(_ choice: String, confidence: Double = 0.9) -> FakeDecisionEngine {
        FakeDecisionEngine { schema in
            var probabilities: [String: Double] = [:]
            for id in schema.optionIDs { probabilities[id] = id == choice ? confidence : (1 - confidence) / Double(schema.options.count - 1) }
            return AutoDecisionAnswer(choice: choice, probabilities: probabilities, confidence: confidence, model: "fake", latencyMilliseconds: 1)
        }
    }

    func decide(_ schema: AutoDecisionSchema, state: String, checkpoint: String) async throws -> AutoDecisionAnswer {
        try await answer(schema)
    }
}

/// The app, as an Auto run sees it, scripted.
@MainActor
final class FakeHarness {
    var settings = AutoHarnessSettings()
    var main = AutoSessionHandle(sessionID: UUID(), provider: .claude, handle: "claude", directory: "/repo", model: "opus", effort: "high")
    var installed: Set<AgentProvider> = [.claude, .codex]
    var failToStart: Set<AutoRole> = []
    /// Replies queued per role ("main" or a role's raw value); when a queue
    /// is empty the role's default reply is used.
    var replies: [String: [AutoTurnResult]] = [:]
    var suites = [AutoSuiteSpec(name: "unit", command: "make test", directory: "/repo")]
    /// Exit codes queued for successive suite runs; empty ⇒ 0.
    var suiteExits: [Int32] = []
    var suiteOutput = "1 test failed: testUpload"
    var changed = ["Sources/A.swift"]
    var engine: (any AutoDecisionEngine)?
    /// Runs inside every turn, before it answers.
    var duringTurn: ((String, AutoSessionHandle) async -> AutoTurnResult?)?
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private(set) var started: [AutoSpecialistSpec] = []
    private(set) var turns: [(role: String, prompt: String)] = []
    private(set) var stopped: [UUID] = []
    private(set) var removed: [String] = []
    private(set) var roles: [UUID: String] = [:]
    private(set) var reports: [AutoOrchestrator.Report] = []

    init() {
        // Tests decide when Laya is asked; deterministic unless they say so.
        settings.decisions.enabled = true
        settings.policy.research = .never
    }

    static func block(_ json: String) -> AutoTurnResult {
        AutoTurnResult(outcome: .completed, text: "Here it is.\n\n```uncoil-handoff\n\(json)\n```")
    }

    func defaultReply(_ role: String) -> AutoTurnResult {
        switch role {
        case "main": Self.block(#"{"summary":"plan","plan":["change A"],"worker_task":"Change A and test it."}"#)
        case "explorer": Self.block(#"{"summary":"A is where uploads retry","files":["Sources/A.swift — the retry loop"]}"#)
        case "researcher": Self.block(#"{"summary":"The SDK caps retries at 3","sources":["https://example.com/docs"]}"#)
        case "worker": Self.block(#"{"status":"done","summary":"Changed A","files":["Sources/A.swift"],"tests":["make test — pass"]}"#)
        case "advisor": Self.block(#"{"verdict":"proceed","summary":"Looks right"}"#)
        default: AutoTurnResult(outcome: .completed, text: "")
        }
    }

    func environment() -> AutoHarnessEnvironment {
        roles[main.sessionID] = "main"
        return AutoHarnessEnvironment(
            settings: { [unowned self] in settings },
            resolveMain: { [unowned self] in main },
            startSpecialist: { [unowned self] spec, _ in
                if failToStart.contains(spec.role) { return .failure(AutoHarnessFailure(message: "no \(spec.role.rawValue)")) }
                started.append(spec)
                let id = UUID()
                roles[id] = spec.role.rawValue
                return .success(AutoSessionHandle(
                    sessionID: id, provider: spec.provider, handle: spec.role.rawValue,
                    directory: spec.worktree ? "/repo/.uncoil-worktrees/w" : "/repo",
                    worktreePath: spec.worktree ? "/repo/.uncoil-worktrees/w" : nil,
                    model: spec.model, effort: spec.effort))
            },
            runTurn: { [unowned self] handle, prompt, _ in
                let role = roles[handle.sessionID] ?? "?"
                turns.append((role, prompt))
                if let hook = duringTurn, let result = await hook(role, handle) { return result }
                if var queue = replies[role], !queue.isEmpty {
                    let next = queue.removeFirst()
                    replies[role] = queue
                    return next
                }
                return defaultReply(role)
            },
            verificationSuites: { [unowned self] _ in suites },
            runSuite: { [unowned self] suite, _ in
                let exit = suiteExits.isEmpty ? 0 : suiteExits.removeFirst()
                return .init(name: suite.name, command: suite.command, exitCode: exit, timedOut: false,
                             outputTail: exit == 0 ? "ok" : suiteOutput)
            },
            changedFiles: { [unowned self] _ in changed },
            decisionEngine: { [unowned self] in engine },
            installed: { [unowned self] in installed.contains($0) },
            stopSession: { [unowned self] in stopped.append($0) },
            removeWorktree: { [unowned self] in removed.append($0) },
            now: { [unowned self] in clock }
        )
    }

    func run(_ task: String = "Make uploads retry") async -> AutoRun {
        let orchestrator = AutoOrchestrator(task: task, environment: environment()) { [unowned self] in reports.append($0) }
        orchestrator.start()
        await orchestrator.finished()
        return orchestrator.run
    }

    func turns(of role: String) -> [String] { turns.filter { $0.role == role }.map(\.prompt) }

    /// Main as the conversation resolved it.
    func adopt(_ handle: AutoSessionHandle) {
        main = handle
        roles[handle.sessionID] = "main"
    }
    var startedRoles: [AutoRole] { started.map(\.role) }
}

@MainActor
final class AutoOrchestratorTests: XCTestCase {
    // MARK: - The vertical slice

    func testARunExploresPlansImplementsVerifiesAndCompletes() async {
        let harness = FakeHarness()
        let run = await harness.run()

        XCTAssertEqual(run.phase, .completed, run.reason ?? "")
        XCTAssertEqual(harness.startedRoles, [.explorer, .advisor, .worker])
        XCTAssertEqual(harness.turns.map(\.role), ["explorer", "main", "advisor", "worker", "main"])
        XCTAssertTrue(harness.turns(of: "main")[0].contains("A is where uploads retry"), "Main receives the Explorer's findings")
        XCTAssertTrue(harness.turns(of: "worker")[0].contains("Change A and test it."), "the Worker gets Main's brief")
        XCTAssertTrue(harness.turns(of: "worker")[0].contains("```uncoil-handoff"), "and the result contract")
        XCTAssertEqual(run.verifications.map(\.verdict), [.passed])
        XCTAssertEqual(run.participants.map(\.role), ["main", "explorer", "advisor", "worker"])
        XCTAssertTrue(harness.reports.contains { if case .handoff(.explorer, _, _) = $0 { true } else { false } })
        // The completion decision was asked of Laya (unavailable here) and the policy acted.
        let completion = run.decisions.first { $0.kind == .completionReview }
        XCTAssertEqual(completion?.action, "advisor_not_needed")
        XCTAssertNotNil(completion?.engineError)
    }

    func testSpecialistsAreStartedAsTheirSettingsSay() async {
        let harness = FakeHarness()
        harness.settings.roles[.worker]?.provider = .codex
        harness.settings.roles[.worker]?.model = "gpt-5-codex"
        _ = await harness.run()

        let explorer = harness.started.first { $0.role == .explorer }
        XCTAssertEqual(explorer?.provider, .claude)
        XCTAssertEqual(explorer?.model, "sonnet")
        XCTAssertEqual(explorer?.readOnly, true)
        XCTAssertEqual(explorer?.worktree, false)
        let worker = harness.started.first { $0.role == .worker }
        XCTAssertEqual(worker?.provider, .codex)
        XCTAssertEqual(worker?.model, "gpt-5-codex")
        XCTAssertEqual(worker?.readOnly, false)
        XCTAssertEqual(worker?.worktree, true)
    }

    func testARoleWhoseAgentIsNotInstalledRunsAsMainsAgentWithItsDefaults() async {
        let harness = FakeHarness()
        harness.settings.roles[.worker]?.provider = .gemini
        harness.settings.roles[.worker]?.model = "gemini-pro"
        _ = await harness.run()
        let worker = harness.started.first { $0.role == .worker }
        XCTAssertEqual(worker?.provider, .claude)
        XCTAssertNil(worker?.model, "a model chosen for another CLI is not passed on")
    }

    func testAPlanWithNothingToImplementEndsAfterMain() async {
        let harness = FakeHarness()
        harness.replies["main"] = [FakeHarness.block(#"{"summary":"It already retries.","worker_task":""}"#)]
        let run = await harness.run()
        XCTAssertEqual(run.phase, .completed)
        XCTAssertFalse(harness.startedRoles.contains(.worker))
        XCTAssertTrue(run.verifications.isEmpty)
    }

    func testWithoutAWorkerMainImplementsThePlanItself() async {
        let harness = FakeHarness()
        harness.settings.roles[.worker]?.enabled = false
        harness.settings.roles[.advisor]?.enabled = false
        harness.replies["main"] = [
            FakeHarness.block(#"{"worker_task":"Change A"}"#),
            FakeHarness.block(#"{"status":"done","files":["Sources/A.swift"]}"#),
        ]
        let run = await harness.run()
        XCTAssertEqual(run.phase, .completed)
        XCTAssertEqual(harness.turns(of: "main").count, 3, "plan, implement, final review")
        XCTAssertTrue(harness.turns(of: "main")[1].contains("implement the plan yourself"))
    }

    // MARK: - Specialists failing

    func testASpecialistThatCannotStartIsSkippedOrStopsTheRun() async {
        let carryOn = FakeHarness()
        carryOn.failToStart = [.explorer]
        let first = await carryOn.run()
        XCTAssertEqual(first.phase, .completed)
        XCTAssertTrue(first.events.contains { $0.kind == .error && $0.title.contains("Explorer") })

        let strict = FakeHarness()
        strict.failToStart = [.explorer]
        strict.settings.policy.specialistFailure = .stopRun
        let second = await strict.run()
        XCTAssertEqual(second.phase, .failed)
        XCTAssertTrue(second.reason?.contains("Explorer") == true)
    }

    func testACrashedOrTimedOutChildIsAFailedSpecialist() async {
        let harness = FakeHarness()
        harness.replies["explorer"] = [AutoTurnResult(outcome: .crashed, text: "")]
        let run = await harness.run()
        XCTAssertEqual(run.phase, .completed, "Main carries on without the Explorer")
        XCTAssertEqual(run.participant(.explorer)?.state, .crashed)
        XCTAssertFalse(harness.turns(of: "main")[0].contains("Explorer report"))

        let slow = FakeHarness()
        slow.replies["explorer"] = [AutoTurnResult(outcome: .timedOut, text: "")]
        let timedOut = await slow.run()
        XCTAssertEqual(timedOut.participant(.explorer)?.state, .timedOut)
        XCTAssertEqual(timedOut.phase, .completed)
    }

    func testMainFailingStopsTheRun() async {
        let harness = FakeHarness()
        harness.replies["main"] = [AutoTurnResult(outcome: .failed("rate limited"), text: "")]
        let run = await harness.run()
        XCTAssertEqual(run.phase, .failed)
        XCTAssertTrue(run.reason?.contains("rate limited") == true)
    }

    func testTheChildSessionLimitHolds() async {
        let harness = FakeHarness()
        harness.settings.policy.maxChildSessions = 1
        harness.settings.roles[.advisor]?.enabled = false
        let run = await harness.run()
        XCTAssertEqual(harness.startedRoles, [.explorer])
        XCTAssertEqual(run.phase, .completed, "the Worker could not start, so Main implemented it")
        XCTAssertTrue(run.events.contains { $0.title == "Main implements the plan itself" })
    }

    func testExplorerAndResearcherRunInParallel() async {
        let harness = FakeHarness()
        harness.settings.policy.research = .always
        var inFlight: Set<String> = []
        var overlapped = false
        harness.duringTurn = { role, _ in
            guard role == "explorer" || role == "researcher" else { return nil }
            inFlight.insert(role)
            for _ in 0..<50 where inFlight.count < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if inFlight.count == 2 { overlapped = true }
            return nil
        }
        let run = await harness.run()
        XCTAssertTrue(overlapped, "both were working at once")
        XCTAssertEqual(run.phase, .completed)
        let plan = harness.turns(of: "main")[0]
        XCTAssertTrue(plan.contains("Explorer report") && plan.contains("Researcher report"))
    }

    func testOneSpecialistAtATimeWhenParallelIsOff() async {
        let harness = FakeHarness()
        harness.settings.policy.research = .always
        harness.settings.policy.parallelSpecialists = false
        var inFlight = 0
        var most = 0
        harness.duringTurn = { role, _ in
            guard role == "explorer" || role == "researcher" else { return nil }
            inFlight += 1
            most = max(most, inFlight)
            try? await Task.sleep(for: .milliseconds(20))
            inFlight -= 1
            return nil
        }
        _ = await harness.run()
        XCTAssertEqual(most, 1)
    }

    // MARK: - Verification and what failures lead to

    func testTheWorkerRetriesWithinItsBudgetThenGoesBackToMain() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.settings.roles[.worker]?.maxRetries = 2
        harness.settings.policy.repeatedFailureThreshold = 6
        harness.settings.policy.maxMainRevisions = 0
        harness.suiteExits = [1, 1, 1, 1]
        var attempt = 0
        harness.duringTurn = { role, _ in
            guard role == "worker" else { return nil }
            attempt += 1
            harness.suiteOutput = "failure number \(String(repeating: "x", count: attempt))"
            return nil
        }
        let run = await harness.run()
        XCTAssertEqual(harness.turns(of: "worker").count, 3, "the first try and two retries")
        XCTAssertEqual(run.phase, .failed)
        XCTAssertTrue(run.reason?.contains("Over to you") == true)
        let triage = run.decisions.filter { $0.kind == .failureTriage }.map(\.action)
        XCTAssertEqual(triage, ["retry", "retry", "return_to_main"])
        XCTAssertNotNil(run.decisions.last?.override, "the budget decided, not Laya")
    }

    func testARepeatedFailureGoesToTheAdvisorByPolicyAndThenPasses() async {
        let harness = FakeHarness()
        harness.settings.advisorCheckpoints.beforePlan = false
        harness.settings.policy.repeatedFailureThreshold = 2
        harness.suiteExits = [1, 1, 0]
        harness.engine = FakeDecisionEngine.choosing("retry")
        let run = await harness.run()

        XCTAssertEqual(run.phase, .completed, run.reason ?? "")
        XCTAssertEqual(harness.startedRoles, [.explorer, .worker, .advisor])
        let escalation = run.decisions.first { $0.action == "escalate_to_advisor" }
        XCTAssertNotNil(escalation?.override, "a threshold, not Laya, sent it to the Advisor")
        XCTAssertEqual(escalation?.answer?.choice, "retry", "what Laya would have done is kept")
        XCTAssertTrue(harness.turns(of: "advisor")[0].contains("Checkpoint: repeated_failure"))
        XCTAssertTrue(harness.turns(of: "worker")[2].contains("An Advisor reviewed the repeated failure"))
    }

    func testARepeatedFailureWithoutAnAdvisorGoesBackToMain() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.settings.policy.repeatedFailureThreshold = 2
        harness.suiteExits = [1, 1, 0]
        harness.replies["main"] = [
            FakeHarness.block(#"{"worker_task":"Change A"}"#),
            FakeHarness.block(#"{"worker_task":"Change B instead"}"#),
        ]
        let run = await harness.run()
        XCTAssertEqual(run.phase, .completed)
        XCTAssertTrue(harness.turns(of: "main")[1].contains("did not pass verification"))
        XCTAssertTrue(harness.turns(of: "worker").last?.contains("Change B instead") == true)
    }

    func testTheWorkersClaimIsNotEvidence() async {
        // Says done; the suite says otherwise.
        let claims = FakeHarness()
        claims.settings.roles[.advisor]?.enabled = false
        claims.settings.roles[.worker]?.maxRetries = 0
        claims.settings.policy.maxMainRevisions = 0
        claims.suiteExits = [1]
        let failed = await claims.run()
        XCTAssertEqual(failed.verifications.first?.verdict, .failed)
        XCTAssertEqual(failed.verifications.first?.claimedStatus, "done")

        // Says done; its worktree has nothing in it.
        let empty = FakeHarness()
        empty.settings.roles[.advisor]?.enabled = false
        empty.settings.roles[.worker]?.maxRetries = 0
        empty.settings.policy.maxMainRevisions = 0
        empty.changed = []
        let nothing = await empty.run()
        XCTAssertEqual(nothing.verifications.first?.verdict, .failed)
        XCTAssertEqual(empty.removed, ["/repo/.uncoil-worktrees/w"], "the empty worktree is cleaned up")

        // Nothing to run: complete, but said to be unverified.
        let bare = FakeHarness()
        bare.suites = []
        let unverified = await bare.run()
        XCTAssertEqual(unverified.phase, .completed)
        XCTAssertEqual(unverified.verifications.first?.verdict, .unverified)
        XCTAssertTrue(bare.reports.contains { if case .notice(.warning, let text, _) = $0 { text.contains("without verification") } else { false } })
    }

    func testAWorkerReportingFailureFailsVerificationEvenWithGreenTests() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.replies["worker"] = [FakeHarness.block(#"{"status":"blocked","errors":["needs an API key"]}"#)]
        let run = await harness.run()
        XCTAssertEqual(run.verifications.first?.verdict, .failed)
        XCTAssertEqual(run.verifications.last?.verdict, .passed, "the retry then passed")
    }

    // MARK: - Laya

    func testShadowModeRecordsLayaWhileThePolicyActs() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.suiteExits = [1, 0]
        harness.engine = FakeDecisionEngine.choosing("return_to_main", confidence: 0.92)
        let run = await harness.run()
        let triage = run.decisions.first { $0.kind == .failureTriage }
        XCTAssertEqual(triage?.authority, .shadow)
        XCTAssertEqual(triage?.answer?.choice, "return_to_main")
        XCTAssertEqual(triage?.action, "retry")
        XCTAssertEqual(harness.turns(of: "main").count, 2, "Main was not asked again: Laya only watched")
    }

    func testActiveModeLetsLayaDecideWithinThePolicies() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.settings.decisions.authority[AutoDecisionKind.failureTriage.rawValue] = .active
        harness.suiteExits = [1, 0]
        harness.engine = FakeDecisionEngine.choosing("return_to_main", confidence: 0.92)
        let run = await harness.run()
        let triage = run.decisions.first { $0.kind == .failureTriage }
        XCTAssertEqual(triage?.action, "return_to_main")
        XCTAssertTrue(triage?.layaDecided == true)
        XCTAssertEqual(harness.turns(of: "main").count, 3, "Main wrote a new brief")
    }

    func testLayaCannotEscalateToAnAdvisorThatIsOff() async {
        let harness = FakeHarness()
        harness.settings.roles[.advisor]?.enabled = false
        harness.settings.decisions.authority[AutoDecisionKind.failureTriage.rawValue] = .active
        harness.suiteExits = [1, 0]
        harness.engine = FakeDecisionEngine.choosing("escalate_to_advisor")
        let run = await harness.run()
        let triage = run.decisions.first { $0.kind == .failureTriage }
        XCTAssertEqual(triage?.action, "retry")
        XCTAssertEqual(triage?.override, "the Advisor is off")
        XCTAssertFalse(harness.startedRoles.contains(.advisor))
    }

    func testAnUnsureOrSlowOrBrokenLayaFallsBackToThePolicy() async {
        var settings = AutoDecisionSettings()
        settings.authority[AutoDecisionKind.failureTriage.rawValue] = .active
        settings.minimumConfidence = 0.7

        let unsure = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry", settings: settings,
            engine: FakeDecisionEngine.choosing("return_to_main", confidence: 0.4))
        XCTAssertEqual(unsure.action, "retry")
        XCTAssertTrue(unsure.override?.contains("confidence") == true)

        settings.timeoutMilliseconds = 30
        let slow = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry", settings: settings,
            engine: FakeDecisionEngine { _ in
                try await Task.sleep(for: .seconds(5))
                return AutoDecisionAnswer(choice: "return_to_main", probabilities: [:], confidence: 1)
            })
        XCTAssertEqual(slow.action, "retry")
        XCTAssertEqual(slow.engineError, AutoDecisionError.timedOut.description)

        let broken = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry", settings: settings,
            engine: FakeDecisionEngine { _ in throw AutoDecisionError.status(500) })
        XCTAssertEqual(broken.action, "retry")
        XCTAssertNotNil(broken.engineError)

        let missing = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry", settings: settings, engine: nil)
        XCTAssertEqual(missing.engineError, AutoDecisionError.unavailable.description)

        settings.authority[AutoDecisionKind.failureTriage.rawValue] = .off
        let off = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry", settings: settings,
            engine: FakeDecisionEngine.choosing("return_to_main"))
        XCTAssertNil(off.answer, "an off decision is not asked")
    }

    func testAForcedPolicyStillRecordsWhatLayaWouldHaveDone() async {
        var settings = AutoDecisionSettings()
        settings.authority[AutoDecisionKind.failureTriage.rawValue] = .active
        let record = await AutoDecisionResolver.resolve(
            .failureTriage, state: "s", deterministic: "retry",
            forced: (action: "return_to_main", reason: "budget"),
            settings: settings, engine: FakeDecisionEngine.choosing("retry"))
        XCTAssertEqual(record.action, "return_to_main")
        XCTAssertEqual(record.override, "budget")
        XCTAssertEqual(record.answer?.choice, "retry")
        XCTAssertFalse(record.layaDecided)
    }

    func testTheResearchGateIsLayasWhenActive() async {
        let harness = FakeHarness()
        harness.settings.policy.research = .whenNeeded
        harness.settings.decisions.authority[AutoDecisionKind.research.rawValue] = .active
        harness.engine = FakeDecisionEngine.choosing("research")
        _ = await harness.run("Rename a variable")
        XCTAssertTrue(harness.startedRoles.contains(.researcher))

        let shadow = FakeHarness()
        shadow.settings.policy.research = .whenNeeded
        shadow.engine = FakeDecisionEngine.choosing("research")
        _ = await shadow.run("Rename a variable")
        XCTAssertFalse(shadow.startedRoles.contains(.researcher), "in shadow the keyword gate decides")
        _ = await shadow.run("Upgrade to the latest SDK and follow its documentation")
        XCTAssertTrue(shadow.startedRoles.contains(.researcher))
    }

    // MARK: - Cancellation, time, settings, cleanup

    func testCancellingARunInterruptsItWhereItIs() async {
        let harness = FakeHarness()
        harness.duringTurn = { role, _ in
            guard role == "worker" else { return nil }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return AutoTurnResult(outcome: .cancelled, text: "")
        }
        let orchestrator = AutoOrchestrator(task: "t", environment: harness.environment()) { _ in }
        orchestrator.start()
        while !harness.turns.contains(where: { $0.role == "worker" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        orchestrator.cancel()
        await orchestrator.finished()
        XCTAssertEqual(orchestrator.run.phase, .cancelled)
        XCTAssertTrue(orchestrator.run.verifications.isEmpty)
    }

    func testTheRunStopsAtItsTimeLimit() async {
        let harness = FakeHarness()
        harness.settings.policy.maxRunMinutes = 30
        harness.duringTurn = { role, _ in
            if role == "explorer" { harness.clock = harness.clock.addingTimeInterval(31 * 60) }
            return nil
        }
        let run = await harness.run()
        XCTAssertEqual(run.phase, .failed)
        XCTAssertTrue(run.reason?.contains("30-minute") == true)
    }

    func testChangingSettingsMidRunChangesTheNextRunNotThisOne() async {
        let harness = FakeHarness()
        harness.duringTurn = { role, _ in
            if role == "explorer" { harness.settings.roles[.worker]?.enabled = false }
            return nil
        }
        _ = await harness.run()
        XCTAssertTrue(harness.startedRoles.contains(.worker))

        harness.duringTurn = nil
        let before = harness.started.count
        _ = await harness.run()
        XCTAssertFalse(harness.started.dropFirst(before).contains { $0.role == .worker })
    }

    func testSpecialistsAreStoppedWhenTheRunEndsIfSettingsSaySo() async {
        let harness = FakeHarness()
        harness.settings.policy.stopSpecialistsWhenDone = true
        let run = await harness.run()
        let children = run.participants.filter { $0.role != "main" }.map(\.sessionID)
        XCTAssertEqual(Set(harness.stopped), Set(children))
        XCTAssertFalse(harness.stopped.contains(harness.main.sessionID), "Main is the user's session")
        XCTAssertTrue(harness.removed.isEmpty, "a worktree with changes stays")
    }
}

/// The result contract and Laya's wire format.
final class AutoHandoffTests: XCTestCase {
    func testTheLastBlockIsTheResultAndListsMayBeStrings() {
        let text = """
        First attempt:
        ```uncoil-handoff
        {"status":"failed"}
        ```
        Fixed it.
        ```uncoil-handoff
        {"status":"Done","files":"Sources/A.swift","tests":["make test — pass"],"worker_task":["step one","step two"]}
        ```
        """
        let handoff = AutoHandoff.parse(text)
        XCTAssertTrue(handoff.structured)
        XCTAssertEqual(handoff.status, "done")
        XCTAssertEqual(handoff.files, ["Sources/A.swift"])
        XCTAssertEqual(handoff.workerTask, "step one\nstep two")
    }

    func testAReplyWithoutABlockIsAnUnstructuredSummary() {
        let handoff = AutoHandoff.parse("I looked around; the retry loop is in A.")
        XCTAssertFalse(handoff.structured)
        XCTAssertEqual(handoff.summary, "I looked around; the retry loop is in A.")
        XCTAssertFalse(AutoHandoff.parse("```uncoil-handoff\n{not json\n```").structured)
    }

    func testTheConversationShowsTheProseWithoutTheBlock() {
        XCTAssertEqual(
            UncoilAutoSession.withoutHandoff("Plan below.\n\n```uncoil-handoff\n{\"plan\":[]}\n```\n"),
            "Plan below.")
    }

    func testLayaIsAskedOneChoiceQuestion() throws {
        let schema = AutoDecisionKind.failureTriage.schema
        let body = try LayaDecisionClient.requestBody(schema, state: "state", checkpoint: "laya")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "laya")
        let question = try XCTUnwrap((json["questions"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertEqual(Set((question["criteria"] as? [String: String])?.keys.map { $0 } ?? []), Set(schema.optionIDs))
        let automatic = try JSONSerialization.jsonObject(with: LayaDecisionClient.requestBody(schema, state: "s", checkpoint: "auto")) as? [String: Any]
        XCTAssertNil(automatic?["model"], "auto lets the server route by language")
    }

    func testLayasAnswerIsReadAndAnInventedChoiceRejected() throws {
        let schema = AutoDecisionKind.failureTriage.schema
        let answer = try LayaDecisionClient.parse(Data(#"""
        {"answers":{"decision":{"type":"choice","choice":"retry","probabilities":{"retry":0.74,"return_to_main":0.09,"escalate_to_advisor":0.17},"confidence":0.41}},
         "laya_apple":{"model":"laya","latency_ms":38.5}}
        """#.utf8), schema: schema)
        XCTAssertEqual(answer.choice, "retry")
        XCTAssertEqual(answer.probabilities["escalate_to_advisor"], 0.17)
        XCTAssertEqual(answer.latencyMilliseconds, 38.5)

        XCTAssertThrowsError(try LayaDecisionClient.parse(Data(#"{"answers":{"decision":{"choice":"delete_everything"}}}"#.utf8), schema: schema)) {
            XCTAssertEqual($0 as? AutoDecisionError, .invalidChoice("delete_everything"))
        }
        XCTAssertThrowsError(try LayaDecisionClient.parse(Data("[]".utf8), schema: schema))
    }

    func testEveryDecisionsFallbackIsOneOfItsOptions() {
        for kind in AutoDecisionKind.allCases {
            XCTAssertTrue(kind.schema.optionIDs.contains(kind.schema.fallback), kind.rawValue)
        }
    }

    func testReadOnlyIsMappedPerProvider() {
        XCTAssertTrue(AutoReadOnly.launch(for: .claude, readOnly: true).extraArguments.contains("--disallowedTools"))
        XCTAssertNil(AutoReadOnly.launch(for: .claude, readOnly: true).workingMode, "never plan mode: nobody answers its exit prompt")
        XCTAssertEqual(AutoReadOnly.launch(for: .claude, readOnly: false), AutoReadOnly.Launch())
    }

    func testTheSameFailureHasTheSameSignature() {
        func record(_ output: String) -> AutoVerificationRecord {
            AutoVerificationRecord(
                attempt: 1, date: Date(), verdict: .failed, claimedStatus: nil, turnOutcome: "completed",
                suites: [.init(name: "unit", command: "t", exitCode: 1, timedOut: false, outputTail: output)])
        }
        let a = AutoOrchestrator.signature(of: record("Test failed at line 12 after 0.31s"), report: AutoHandoff())
        let b = AutoOrchestrator.signature(of: record("Test failed at line 12 after 0.47s"), report: AutoHandoff())
        let c = AutoOrchestrator.signature(of: record("Build failed: missing symbol"), report: AutoHandoff())
        XCTAssertEqual(a, b, "timings do not make a different failure")
        XCTAssertNotEqual(a, c)
    }
}

/// Settings, each role set by hand, and what an older file holds.
@MainActor
final class AutoHarnessSettingsTests: XCTestCase {
    func testTheHarnessRoundTripsAndToleratesWhatItDoesNotKnow() throws {
        var harness = AutoHarnessSettings()
        harness.roles[.worker]?.provider = .codex
        harness.decisions.authority["failureTriage"] = .active
        let data = try JSONEncoder().encode(harness)
        XCTAssertEqual(try JSONDecoder().decode(AutoHarnessSettings.self, from: data), harness)

        let odd = try JSONDecoder().decode(AutoHarnessSettings.self, from: Data(#"""
        {"mode":"somethingNew","roles":{"worker":{"enabled":false},"designer":{"enabled":true}},"policy":{"maxRunMinutes":30}}
        """#.utf8))
        XCTAssertEqual(odd.mode, .onCommand)
        XCTAssertEqual(odd.role(.worker).enabled, false)
        XCTAssertEqual(odd.role(.worker).maxRetries, 2, "a missing field takes its default")
        XCTAssertEqual(odd.role(.explorer), AutoHarnessSettings.defaultRoles[.explorer], "a missing role takes its default")
        XCTAssertEqual(odd.policy.maxRunMinutes, 30)
        XCTAssertEqual(odd.policy.maxChildSessions, AutoExecutionPolicy().maxChildSessions)
    }

    func testEachRolesAgentModelAndEffortAreSetByHand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(directory: root)
        for role in AutoRole.allCases {
            XCTAssertNotNil(settings.uncoilAuto.harness.role(role).provider, "every role names its agent")
        }
        settings.updateAutoHarness {
            $0.roles[.worker]?.provider = .codex
            $0.roles[.worker]?.model = "gpt-5-codex"
            $0.roles[.worker]?.effort = "high"
            $0.roles[.explorer]?.model = "haiku"
            $0.roles[.explorer]?.effort = "low"
        }
        let reloaded = SettingsStore(directory: root)
        XCTAssertEqual(reloaded.uncoilAuto.harness.role(.worker).provider, .codex)
        XCTAssertEqual(reloaded.uncoilAuto.harness.role(.worker).model, "gpt-5-codex")
        XCTAssertEqual(reloaded.uncoilAuto.harness.role(.worker).effort, "high")
        XCTAssertEqual(reloaded.uncoilAuto.harness.role(.explorer).model, "haiku")
        XCTAssertEqual(reloaded.uncoilAuto.harness.role(.explorer).effort, "low")
    }

    func testARoleSavedAsTheSameAgentAsMainNamesItsAgentNow() throws {
        let old = try JSONDecoder().decode(AutoHarnessSettings.self, from: Data(#"""
        {"profile":"balanced","roles":{"worker":{"enabled":true,"maxRetries":3}}}
        """#.utf8))
        XCTAssertEqual(old.role(.worker).provider, AutoHarnessSettings.defaultRoles[.worker]?.provider)
        XCTAssertEqual(old.role(.worker).model, AutoHarnessSettings.defaultRoles[.worker]?.model)
        XCTAssertEqual(old.role(.worker).maxRetries, 3, "and keeps everything else")
    }

    func testTheRunStartsEachSpecialistWithItsOwnModelAndEffort() async {
        let harness = FakeHarness()
        harness.settings.roles[.explorer]?.model = "haiku"
        harness.settings.roles[.explorer]?.effort = "low"
        harness.settings.roles[.worker]?.provider = .codex
        harness.settings.roles[.worker]?.model = "gpt-5-codex"
        harness.settings.roles[.worker]?.effort = "high"
        harness.settings.roles[.advisor]?.model = "opus"
        harness.settings.roles[.advisor]?.effort = "max"
        _ = await harness.run()
        func spec(_ role: AutoRole) -> AutoSpecialistSpec? { harness.started.first { $0.role == role } }
        XCTAssertEqual(spec(.explorer).map { [$0.model, $0.effort] }, ["haiku", "low"])
        XCTAssertEqual(spec(.worker)?.provider, .codex)
        XCTAssertEqual(spec(.worker).map { [$0.model, $0.effort] }, ["gpt-5-codex", "high"])
        XCTAssertEqual(spec(.advisor).map { [$0.model, $0.effort] }, ["opus", "max"])
    }

    func testEveryDecisionStartsInShadow() {
        let settings = AutoDecisionSettings()
        for kind in AutoDecisionKind.allCases {
            XCTAssertEqual(settings.authority(for: kind), .shadow)
        }
        var off = settings
        off.enabled = false
        XCTAssertEqual(off.authority(for: .failureTriage), .off)
    }
}

/// Waiting for one turn of a real session, from its events and status.
@MainActor
final class AutoTurnWatcherTests: XCTestCase {
    let id = UUID()

    func watcher(_ hub: AgentEventHub, status: @escaping () -> AgentSessionStatus, interrupted: @escaping () -> Void = {}) -> AutoTurnWatcher {
        let watcher = AutoTurnWatcher(sessionID: id, hubs: [hub], status: { _ in status() }, interrupt: { _ in interrupted() })
        watcher.pollInterval = .milliseconds(10)
        watcher.quietPeriod = 0.05
        return watcher
    }

    func testATurnEndsWhenTheSessionSaysSoAndNotBefore() async {
        let hub = AgentEventHub()
        let result = await watcher(hub, status: { .running }).run(prompt: "go", timeout: 5) { _ in
            // A turn that ended before this one started is not this one's end.
            hub.publish(.turnCompleted(turnID: "old", outcome: .completed), sessionID: self.id, provider: .codex)
            hub.publish(.turnStarted(turnID: "t"), sessionID: self.id, provider: .codex)
            hub.publish(.itemCompleted(AgentItem(id: "c", kind: .command(command: "make", output: "", exitCode: 0), status: .completed, native: nil)), sessionID: self.id, provider: .codex)
            hub.publish(.itemCompleted(AgentItem(id: "m", kind: .agentMessage(text: "Done."), status: .completed, native: nil)), sessionID: self.id, provider: .codex)
            hub.publish(.turnCompleted(turnID: "t", outcome: .completed), sessionID: self.id, provider: .codex)
        }
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.text, "Done.")
        XCTAssertEqual(result.commands, ["make → exit 0"])
    }

    func testATerminalAgentsTurnEndsWhenItSettlesAndGoesQuiet() async {
        let hub = AgentEventHub()
        var state = AgentSessionStatus.idle
        let result = await watcher(hub, status: { state }).run(prompt: "go", timeout: 5) { _ in
            state = .running
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                hub.publish(.itemCompleted(AgentItem(id: "m", kind: .agentMessage(text: "Here."), status: .completed, native: nil)), sessionID: self.id, provider: .claude)
                state = .idle
            }
        }
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.text, "Here.")
    }

    func testASessionThatDiesOrRunsOverIsReported() async {
        let hub = AgentEventHub()
        var state = AgentSessionStatus.idle
        let crashed = await watcher(hub, status: { state }).run(prompt: "go", timeout: 5) { _ in
            state = .running
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                state = .terminated
            }
        }
        XCTAssertEqual(crashed.outcome, .crashed)

        var interrupted = false
        let slow = await watcher(hub, status: { .running }, interrupted: { interrupted = true })
            .run(prompt: "go", timeout: 0.1) { _ in }
        XCTAssertEqual(slow.outcome, .timedOut)
        XCTAssertTrue(interrupted, "a turn that runs over is stopped")
    }
}

/// `/auto` in the conversation: the target is Main, specialists report into
/// the conversation, and a message naming an agent still goes to it.
@MainActor
extension UncoilAutoSessionTests {
    private func wire(_ recorder: Recorder, _ harness: FakeHarness) {
        recorder.makeHarness = { main, deliver in
            var environment = harness.environment()
            environment.resolveMain = {
                guard let source = await main() else { return nil }
                harness.adopt(AutoSessionHandle(sessionID: source.sessionID, provider: source.provider, handle: source.handle, directory: "/repo"))
                return harness.main
            }
            let scripted = environment.runTurn
            environment.runTurn = { handle, prompt, timeout in
                if handle.sessionID == harness.main.sessionID { await deliver(handle, prompt) }
                return await scripted(handle, prompt, timeout)
            }
            return environment
        }
    }

    func testAutoRunsATaskWithTheTargetAsMain() async throws {
        let recorder = Recorder()
        let harness = FakeHarness()
        wire(recorder, harness)
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        conversation.target = "claude"
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("/auto make uploads retry")
        await session.orchestrator?.finished()

        XCTAssertEqual(conversation.runs.count, 1)
        XCTAssertEqual(conversation.currentRun?.phase, .completed)
        XCTAssertEqual(conversation.currentRun?.main?.sessionID, claude)
        XCTAssertFalse(conversation.isRunning)
        XCTAssertEqual(recorder.quiet.map(\.1), [claude, claude], "Main's prompts go quietly, without renaming it")
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertTrue(items(session).contains { $0.source?.handle == "explorer" }, "the Explorer's result is shown, not its session")
        XCTAssertTrue(session.participants.keys.contains(claude))
        XCTAssertFalse(session.participants.count > 1, "specialists are not mirrored into the conversation")
    }

    func testEveryMessageModeMakesAPlainMessageATask() async {
        let recorder = Recorder()
        recorder.harness.mode = .everyMessage
        let harness = FakeHarness()
        wire(recorder, harness)
        let conversation = UncoilAutoConversationState(sessionID: UUID())
        let session = makeSession(recorder, conversation: conversation)
        await session.submit("@codex just answer this")
        XCTAssertEqual(recorder.delivered.map(\.1), [codex], "a mention still goes straight to the agent")
        XCTAssertNil(session.orchestrator)

        await session.submit("make uploads retry")
        await session.orchestrator?.finished()
        XCTAssertEqual(conversation.runs.count, 1)
    }

    func testOneRunAtATimeAndAutoCanBeTurnedOff() async {
        let recorder = Recorder()
        recorder.harness.enabled = false
        let session = makeSession(recorder)
        await session.submit("/auto anything")
        XCTAssertNil(session.orchestrator)
        XCTAssertTrue(notices(session).last?.contains("turned off") == true)

        recorder.harness.enabled = true
        let harness = FakeHarness()
        harness.duringTurn = { _, _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return AutoTurnResult(outcome: .cancelled, text: "")
        }
        wire(recorder, harness)
        await session.submit("/auto first")
        await session.submit("/auto second")
        XCTAssertTrue(notices(session).last?.contains("already going") == true)
        await session.submit("/cancel")
        await session.orchestrator?.finished()
        XCTAssertEqual(session.conversation.currentRun?.phase, .cancelled)
    }

    func testARunInterruptedByQuittingIsRestoredAsCancelled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var running = AutoRun(task: "t", startedAt: Date())
        running.phase = .implementing
        let store = UncoilAutoStore(url: url, delay: 0)
        store.save(events: [], participants: [], runs: [running])
        store.saveNow()

        let conversation = UncoilAutoConversationState(sessionID: UUID())
        makeSession(Recorder(), store: UncoilAutoStore(url: url, delay: 0), conversation: conversation).start()
        XCTAssertEqual(conversation.currentRun?.phase, .cancelled)
        XCTAssertFalse(conversation.isRunning)
    }
}
