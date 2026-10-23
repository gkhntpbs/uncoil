import CryptoKit
import Foundation

/// A session an Auto run is talking to: Main, or a specialist it started.
struct AutoSessionHandle: Equatable {
    var sessionID: UUID
    var provider: AgentProvider
    var handle: String
    /// Where the session works: the project root, or its worktree.
    var directory: String
    var worktreePath: String?
    var model: String?
    var effort: String?
}

/// What a specialist is started with, after the role's settings have been
/// resolved against Main and what is installed.
struct AutoSpecialistSpec: Equatable {
    var role: AutoRole
    var provider: AgentProvider
    var accountID: UUID?
    var model: String?
    var effort: String?
    var readOnly: Bool
    var worktree: Bool
}

/// How one turn ended, and what it left behind.
struct AutoTurnResult: Equatable {
    enum Outcome: Equatable {
        case completed
        case failed(String)
        case interrupted
        case timedOut
        /// The session's process went away mid-turn.
        case crashed
        case cancelled

        var description: String {
            switch self {
            case .completed: "completed"
            case .failed(let message): "failed: \(message)"
            case .interrupted: "interrupted"
            case .timedOut: "timed out"
            case .crashed: "the session's process ended"
            case .cancelled: "cancelled"
            }
        }
    }

    var outcome: Outcome
    /// The agent's last message of the turn.
    var text: String
    /// Commands it ran, as "command → exit N".
    var commands: [String] = []
    /// Files it reported changing.
    var files: [String] = []
}

/// A project test suite verification can run.
struct AutoSuiteSpec: Equatable {
    var name: String
    var command: String
    /// Absolute.
    var directory: String
}

/// What an Auto run needs from the app, and nothing more. Closures, so the
/// orchestration can be driven in tests without a provider, a PTY or a
/// window; `live` in `AutoHarnessEnvironment+Live.swift` wires the real app.
@MainActor
struct AutoHarnessEnvironment {
    var settings: () -> AutoHarnessSettings
    /// The conversation's target, started if it is not running. Nil when
    /// there is no agent to be Main.
    var resolveMain: () async -> AutoSessionHandle?
    var startSpecialist: (AutoSpecialistSpec, _ main: AutoSessionHandle) async -> Result<AutoSessionHandle, AutoHarnessFailure>
    /// Sends the prompt and waits until the turn ends, the session dies, the
    /// timeout passes or the calling task is cancelled.
    var runTurn: (AutoSessionHandle, _ prompt: String, _ timeout: TimeInterval) async -> AutoTurnResult
    /// The project's declared or detected default suite, in that directory.
    var verificationSuites: (_ directory: String) async -> [AutoSuiteSpec]
    var runSuite: (AutoSuiteSpec, _ timeout: TimeInterval) async -> AutoVerificationRecord.Suite
    var changedFiles: (_ directory: String) async -> [String]
    var decisionEngine: () async -> (any AutoDecisionEngine)?
    var installed: (AgentProvider) -> Bool
    var stopSession: (UUID) -> Void
    var removeWorktree: (_ path: String) async -> Void
    var now: () -> Date = Date.init
}

struct AutoHarnessFailure: Error, Equatable {
    var message: String
}

/// Runs one task through the harness: Main owns it, specialists do focused
/// work in their own sessions, the Advisor is asked at checkpoints, Laya
/// takes small control decisions, and verification — not anyone's word —
/// says whether the work holds.
///
/// Every deterministic policy sits above Laya: budgets, thresholds and
/// checkpoints decide regardless of what it says, and nothing it says is a
/// permission. Sessions keep their own approvals; the user stays the
/// authority on anything the agents ask.
@MainActor
final class AutoOrchestrator {
    enum Report {
        /// The run changed; redraw it.
        case run(AutoRun)
        case notice(AgentNotice.Level, String, open: AutoSessionHandle?)
        /// A specialist's result, for the conversation.
        case handoff(AutoRole, AutoSessionHandle, AutoHandoff)
    }

    private enum Stop: Error {
        case cancelled
        case failed(String)
    }

    private let environment: AutoHarnessEnvironment
    private let onReport: (Report) -> Void
    private(set) var run: AutoRun
    private var task: Task<Void, Never>?
    private var settings: AutoHarnessSettings
    private var deadline: Date
    private var main: AutoSessionHandle?
    private var advisor: AutoSessionHandle?
    private var handles: [UUID: AutoSessionHandle] = [:]
    private var engine: (any AutoDecisionEngine)?
    private var engineLoaded = false

    var isRunning: Bool { !run.phase.isFinished }

    init(task: String, environment: AutoHarnessEnvironment, onReport: @escaping (Report) -> Void) {
        self.environment = environment
        self.onReport = onReport
        // A snapshot: changing Settings mid-run changes the next run, not
        // this one, so its history stays explainable.
        settings = environment.settings()
        let now = environment.now()
        run = AutoRun(task: task, startedAt: now)
        deadline = now.addingTimeInterval(TimeInterval(max(1, settings.policy.maxRunMinutes)) * 60)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.execute() }
    }

    /// Stops the run where it is. The turn in progress is interrupted.
    func cancel() {
        task?.cancel()
    }

    /// Until the run has finished. For tests and for shutdown.
    func finished() async {
        await task?.value
    }

    // MARK: - The run

    private func execute() async {
        do {
            try await body()
            finish(.completed, reason: nil)
        } catch Stop.cancelled {
            finish(.cancelled, reason: String(localized: "Cancelled."))
        } catch Stop.failed(let reason) {
            finish(.failed, reason: reason)
        } catch {
            finish(.failed, reason: error.localizedDescription)
        }
        await cleanUp()
    }

    private func body() async throws {
        log(.phase, "Run started", detail: "Task:\n\(run.task)")
        guard let main = await environment.resolveMain() else {
            throw Stop.failed(String(localized: "There is no agent to be Main. Choose one with the button beside the field."))
        }
        self.main = main
        run.participants.append(AutoParticipant(
            sessionID: main.sessionID, role: "main", provider: main.provider, handle: main.handle,
            model: main.model, effort: main.effort))
        handles[main.sessionID] = main
        log(.session, "Main: \(run.main?.label ?? main.handle)")
        try checkpoint()

        // Exploration and research.
        let findings = try await explore(main: main)

        // Planning.
        var plan: AutoHandoff
        if settings.policy.mainReviewsSpecialistResults || findings.isEmpty {
            setPhase(.planning)
            plan = try await mainTurn(AutoPrompts.plan(task: run.task, findings: findings, notes: []), purpose: "plan")
        } else {
            // Main does not review the reports: the Worker gets them as they are.
            let brief = ([run.task] + findings.map { "\($0.role.displayName) report:\n\($0.handoff.digest())" })
                .joined(separator: "\n\n")
            plan = AutoHandoff(summary: nil, status: nil)
            plan.workerTask = brief
            log(.policy, "Specialist results go straight to the Worker", detail: "Main review is off in Settings.")
        }

        // The Advisor before any work starts.
        if needsWork(plan), advisorEnabled, settings.advisorCheckpoints.beforePlan {
            if let review = await consultAdvisor(.prePlan, sections: [
                ("Specialist findings", findings.map { "\($0.role.displayName):\n\($0.handoff.digest())" }.joined(separator: "\n\n")),
                ("Main's plan", plan.digest()),
            ]), review.verdict == "revise" || review.verdict == "stop" {
                setPhase(.planning)
                plan = try await mainTurn(AutoPrompts.revisePlan(concerns: review), purpose: "revise the plan")
            }
        }

        guard needsWork(plan) else {
            log(.outcome, "Main found nothing to implement", detail: plan.digest())
            return
        }

        // Implementation, verification and what failures lead to.
        let (worker, report, evidence) = try await implement(plan: plan, main: main)

        // The Advisor before completion.
        var finalReview: AutoHandoff?
        if advisorEnabled {
            let forced: (String, String)? = settings.advisorCheckpoints.beforeCompletion
                ? ("advisor_recommended", "the before-completion checkpoint is on") : nil
            let decision = await decide(
                .completionReview,
                state: completionState(report: report, evidence: evidence),
                deterministic: "advisor_not_needed", forced: forced)
            if decision.action == "advisor_recommended" {
                finalReview = await consultAdvisor(.preCompletion, sections: [
                    ("Main's plan", plan.digest()),
                    ("Worker report", report.digest()),
                    ("Verification", evidence.summary),
                ])
            }
        }

        // Main has the last word.
        setPhase(.reviewing)
        let isolated = worker.worktreePath
        do {
            _ = try await mainTurn(
                AutoPrompts.finalReview(worker: report, verification: evidence.summary, advisor: finalReview, worktree: isolated),
                purpose: "review the result", parsesHandoff: false)
        } catch Stop.failed(let reason) {
            log(.warning, "Main could not review the result", detail: reason)
        }
        if evidence.verdict == .unverified {
            notice(.warning, String(localized: "Completed without verification: there was nothing Uncoil could run to check the work."))
        }
    }

    // MARK: - Exploration

    private func explore(main: AutoSessionHandle) async throws -> [(role: AutoRole, handoff: AutoHandoff)] {
        var roles: [AutoRole] = []
        if settings.role(.explorer).enabled { roles.append(.explorer) }
        if settings.role(.researcher).enabled, try await wantsResearch() { roles.append(.researcher) }
        guard !roles.isEmpty else { return [] }
        setPhase(.exploring)
        let parallel = settings.policy.parallelSpecialists && settings.policy.maxConcurrentSpecialists >= 2 && roles.count > 1
        var results: [AutoRole: AutoHandoff] = [:]
        if parallel {
            try await withThrowingTaskGroup(of: (AutoRole, AutoHandoff?).self) { group in
                for role in roles {
                    group.addTask { @MainActor in
                        (role, try await self.specialist(role, main: main, body: "Task:\n\(self.run.task)"))
                    }
                }
                for try await (role, handoff) in group {
                    if let handoff { results[role] = handoff }
                }
            }
        } else {
            for role in roles {
                if let handoff = try await specialist(role, main: main, body: "Task:\n\(run.task)") {
                    results[role] = handoff
                }
            }
        }
        return roles.compactMap { role in results[role].map { (role, $0) } }
    }

    private func wantsResearch() async throws -> Bool {
        switch settings.policy.research {
        case .never: return false
        case .always: return true
        case .whenNeeded:
            let decision = await decide(
                .research, state: "Task: \(run.task)",
                deterministic: Self.mentionsOutsideInformation(run.task) ? "research" : "no_research")
            return decision.action == "research"
        }
    }

    /// The deterministic research gate: words that point outside the repo.
    nonisolated static func mentionsOutsideInformation(_ task: String) -> Bool {
        let text = task.lowercased()
        return ["documentation", "docs", "api ", "sdk", "release notes", "changelog of", "latest", "upgrade",
                "migrate to", "deprecated", "version ", "dokümantasyon", "sürüm", "güncel"]
            .contains { text.contains($0) }
    }

    // MARK: - Specialists

    /// Starts the role, runs one turn and returns its handoff; nil when it
    /// failed and the policy says to carry on without it.
    private func specialist(_ role: AutoRole, main: AutoSessionHandle, body: String) async throws -> AutoHandoff? {
        let handle: AutoSessionHandle
        do {
            handle = try await startSpecialist(role, main: main)
        } catch Stop.failed(let reason) {
            try specialistFailed(role, reason)
            return nil
        }
        let prompt = AutoPrompts.specialist(role, instructions: settings.role(role).instructions, body: body)
        let result = try await turn(handle, prompt, role: role)
        guard result.outcome == .completed else {
            try specialistFailed(role, result.outcome.description)
            return nil
        }
        let handoff = AutoHandoff.parse(result.text)
        record(handoff, from: role, handle: handle)
        return handoff
    }

    private func startSpecialist(_ role: AutoRole, main: AutoSessionHandle) async throws -> AutoSessionHandle {
        guard run.childCount < settings.policy.maxChildSessions else {
            throw Stop.failed(String(localized: "The run reached its limit of \(settings.policy.maxChildSessions) child sessions."))
        }
        let spec = resolve(role, main: main)
        switch await environment.startSpecialist(spec, main) {
        case .failure(let failure):
            log(.error, "\(role.displayName) could not start", detail: failure.message)
            throw Stop.failed(failure.message)
        case .success(let handle):
            var participant = AutoParticipant(
                sessionID: handle.sessionID, role: role.rawValue, provider: handle.provider, handle: handle.handle,
                model: handle.model, effort: handle.effort, worktreePath: handle.worktreePath)
            participant.state = .idle
            run.participants.append(participant)
            handles[handle.sessionID] = handle
            log(.session, "\(participant.label) started",
                detail: handle.worktreePath.map { "Worktree: \($0)" } ?? "Directory: \(handle.directory)")
            notice(.info, String(localized: "\(participant.label) started."), open: handle)
            return handle
        }
    }

    /// The role's settings against Main and what is installed. A provider
    /// that is not installed falls back to Main's agent, without a model or
    /// effort, since those were chosen for another CLI.
    func resolve(_ role: AutoRole, main: AutoSessionHandle) -> AutoSpecialistSpec {
        let config = settings.role(role)
        var provider = config.provider ?? main.provider
        var model = config.provider == nil ? nil : config.model
        var effort = config.provider == nil ? nil : config.effort
        var accountID = config.provider == nil ? nil : config.accountID
        if !environment.installed(provider) {
            log(.warning, "\(role.displayName): \(provider.displayName) is not installed",
                detail: "Using Main's agent (\(main.provider.displayName)) with its defaults instead.")
            provider = main.provider
            model = nil
            effort = nil
            accountID = nil
        }
        return AutoSpecialistSpec(
            role: role, provider: provider, accountID: accountID, model: model, effort: effort,
            readOnly: role.readsOnly && config.readOnly,
            worktree: role == .worker && config.worktreeIsolation)
    }

    private func specialistFailed(_ role: AutoRole, _ reason: String) throws {
        log(.error, "\(role.displayName) failed", detail: reason)
        if case .stopRun = settings.policy.specialistFailure {
            throw Stop.failed(String(localized: "\(role.displayName) failed: \(reason)"))
        }
        notice(.warning, String(localized: "\(role.displayName) failed (\(reason)); carrying on without it."))
    }

    private func record(_ handoff: AutoHandoff, from role: AutoRole, handle: AutoSessionHandle) {
        run.update(handle.sessionID) { $0.state = .done }
        log(.handoff, "\(role.displayName) returned \(handoff.structured ? "a structured result" : "an unstructured result")",
            detail: handoff.digest(limit: 6_000))
        onReport(.handoff(role, handle, handoff))
    }

    // MARK: - Main

    private func mainTurn(_ prompt: String, purpose: String, parsesHandoff: Bool = true) async throws -> AutoHandoff {
        guard let main else { throw Stop.failed("no main session") }
        log(.prompt, "Asked Main to \(purpose)", detail: prompt)
        notice(.info, String(localized: "Asked @\(main.handle) to \(purpose)."))
        let result = try await turn(main, prompt, role: nil)
        guard result.outcome == .completed else {
            throw Stop.failed(String(localized: "Main's turn did not finish: \(result.outcome.description)."))
        }
        let handoff = parsesHandoff ? AutoHandoff.parse(result.text) : AutoHandoff(summary: result.text)
        if parsesHandoff {
            log(.handoff, "Main answered", detail: handoff.digest(limit: 6_000))
        }
        return handoff
    }

    private func needsWork(_ plan: AutoHandoff) -> Bool {
        if let task = plan.workerTask { return !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // A reply without a block: Main has not said there is nothing to do.
        return !plan.structured
    }

    // MARK: - Implementation

    private func implement(plan: AutoHandoff, main: AutoSessionHandle) async throws
        -> (AutoSessionHandle, AutoHandoff, AutoVerificationRecord) {
        setPhase(.implementing)
        var brief = plan.workerTask ?? plan.summary ?? run.task
        var worker: AutoSessionHandle
        var mainImplements = false
        if settings.role(.worker).enabled {
            do {
                worker = try await startSpecialist(.worker, main: main)
            } catch Stop.failed(let reason) {
                guard case .continueWithoutIt = settings.policy.specialistFailure else {
                    throw Stop.failed(String(localized: "The Worker could not start: \(reason)"))
                }
                log(.policy, "Main implements the plan itself", detail: "The Worker could not start: \(reason)")
                worker = main
                mainImplements = true
            }
        } else {
            log(.policy, "Main implements the plan itself", detail: "The Worker role is off in Settings.")
            worker = main
            mainImplements = true
        }

        let workerSettings = settings.role(.worker)
        var prompt = mainImplements
            ? AutoPrompts.implementYourself(task: brief)
            : AutoPrompts.specialist(.worker, instructions: workerSettings.instructions,
                                     body: AutoPrompts.workerBrief(task: run.task, brief: brief, worktree: worker.worktreePath))
        var retries = 0
        var revisions = 0
        var sameFailures = 0
        var lastSignature: String?
        var escalated: Set<String> = []
        var advice: AutoHandoff?
        var attempt = 0

        while true {
            try checkpoint()
            setPhase(.implementing)
            let result = try await turn(worker, prompt, role: mainImplements ? nil : .worker)
            let report = result.outcome == .completed ? AutoHandoff.parse(result.text) : AutoHandoff(summary: result.text, status: "failed")
            if !mainImplements { record(report, from: .worker, handle: worker) }
            attempt += 1
            let evidence = await verify(worker, result: result, report: report, attempt: attempt)
            guard evidence.verdict == .failed else {
                return (worker, report, evidence)
            }

            // What a failure leads to. Budgets and thresholds are policy and
            // sit above Laya; within them, the triage is Laya's when the user
            // made it active.
            if evidence.signature != nil, evidence.signature == lastSignature {
                sameFailures += 1
            } else {
                sameFailures = 1
            }
            lastSignature = evidence.signature
            let budget = mainImplements ? workerSettings.maxRetries + settings.policy.maxMainRevisions : workerSettings.maxRetries
            let repeated = sameFailures >= max(1, settings.policy.repeatedFailureThreshold)
            let canEscalate = advisorEnabled && settings.advisorCheckpoints.onRepeatedFailure
                && !(evidence.signature.map(escalated.contains) ?? false)
            var forced: (String, String)?
            if repeated, canEscalate {
                forced = ("escalate_to_advisor", "the same failure \(sameFailures) times; the repeated-failure checkpoint is on")
            } else if repeated, !mainImplements {
                forced = ("return_to_main", "the same failure \(sameFailures) times")
            } else if retries >= budget {
                forced = mainImplements ? ("stop", "retry budget spent") : ("return_to_main", "the Worker's retry budget (\(budget)) is spent")
            }
            if forced?.0 == "stop" {
                throw Stop.failed(String(localized: "Verification still fails after \(attempt) attempts."))
            }
            var decision = await decide(
                .failureTriage, state: triageState(evidence: evidence, report: report, sameFailures: sameFailures, retries: retries),
                deterministic: retries < budget ? "retry" : "return_to_main", forced: forced)
            if decision.action == "escalate_to_advisor", !canEscalate {
                decision = overrideAction(decision, to: retries < budget ? "retry" : "return_to_main",
                                          reason: advisorEnabled ? "this failure was already escalated" : "the Advisor is off")
            }
            if decision.action == "return_to_main", mainImplements {
                decision = overrideAction(decision, to: "retry", reason: "Main is implementing the plan itself")
            }

            switch decision.action {
            case "escalate_to_advisor":
                if let signature = evidence.signature { escalated.insert(signature) }
                advice = await consultAdvisor(.repeatedFailure, sections: [
                    ("Main's plan", plan.digest()),
                    ("Worker report", report.digest()),
                    ("Verification", evidence.summary),
                ])
                retries += 1
                sameFailures = 0
                notice(.info, String(localized: "Worker retrying with the Advisor's review."))
                prompt = AutoPrompts.workerRetry(failure: evidence.summary, advice: advice)
            case "return_to_main":
                guard revisions < settings.policy.maxMainRevisions else {
                    throw Stop.failed(String(localized: "Verification still fails after \(revisions + 1) briefs from Main. Over to you."))
                }
                revisions += 1
                retries = 0
                sameFailures = 0
                setPhase(.planning)
                let replan = try await mainTurn(AutoPrompts.rebrief(failure: evidence.summary, worker: report), purpose: "decide after the failure")
                guard needsWork(replan) else {
                    throw Stop.failed(String(localized: "Main stopped the work after verification failed."))
                }
                brief = replan.workerTask ?? replan.summary ?? brief
                notice(.info, String(localized: "Worker continuing with Main's new brief."))
                prompt = AutoPrompts.specialist(.worker, instructions: workerSettings.instructions,
                                                body: AutoPrompts.workerBrief(task: run.task, brief: brief, worktree: worker.worktreePath))
            default:
                retries += 1
                notice(.info, String(localized: "Tests failed — Worker retrying (\(retries)/\(budget))."))
                prompt = AutoPrompts.workerRetry(failure: evidence.summary, advice: nil)
            }
        }
    }

    private func overrideAction(_ record: AutoDecisionRecord, to action: String, reason: String) -> AutoDecisionRecord {
        var record = record
        record.action = action
        record.override = reason
        if let index = run.decisions.lastIndex(where: { $0.id == record.id }) {
            run.decisions[index] = record
        }
        log(.policy, "Decision overridden: \(action)", detail: reason)
        return record
    }

    // MARK: - Verification

    /// Observable evidence, not anyone's word. The Worker's claim is
    /// recorded beside it, so the difference stays visible.
    private func verify(
        _ worker: AutoSessionHandle, result: AutoTurnResult, report: AutoHandoff, attempt: Int
    ) async -> AutoVerificationRecord {
        setPhase(.verifying)
        var record = AutoVerificationRecord(
            attempt: attempt, date: environment.now(), verdict: .unverified,
            claimedStatus: report.status, turnOutcome: result.outcome.description,
            workerCommands: result.commands)
        record.changedFiles = await environment.changedFiles(worker.directory)
        if result.outcome != .completed {
            record.verdict = .failed
            record.reasons.append("The Worker's turn did not complete: \(result.outcome.description).")
        } else {
            if settings.policy.alwaysVerify || settings.policy.requireTestsWhenAvailable {
                for suite in await environment.verificationSuites(worker.directory) {
                    if Task.isCancelled { break }
                    log(.verification, "Running \(suite.name)", detail: "\(suite.command)\nin \(suite.directory)")
                    record.suites.append(await environment.runSuite(suite, verificationTimeout))
                }
            }
            if record.suites.contains(where: { $0.timedOut || $0.exitCode != 0 }) {
                record.verdict = .failed
            } else if let status = report.status, ["failed", "blocked"].contains(status) {
                record.verdict = .failed
                record.reasons.append("The Worker reported its work as \(status).")
            } else if worker.worktreePath != nil, record.changedFiles.isEmpty {
                record.verdict = .failed
                record.reasons.append("The Worker's worktree has no changes, whatever the Worker reported.")
            } else if !record.suites.isEmpty {
                record.verdict = .passed
            } else {
                record.verdict = .unverified
                record.reasons.append("No test suite is declared in .uncoil/tests.json or detected; only the Worker's report is there.")
            }
        }
        if record.verdict == .failed { record.signature = Self.signature(of: record, report: report) }
        run.verifications.append(record)
        let title = switch record.verdict {
        case .passed: "Verification passed"
        case .failed: "Verification failed"
        case .unverified: "Nothing to verify with"
        }
        log(.verification, title, detail: record.summary)
        notice(record.verdict == .failed ? .warning : .info, String(localized: "\(title)."))
        return record
    }

    private var verificationTimeout: TimeInterval {
        min(TimeInterval(max(1, settings.role(.worker).maxRuntimeMinutes)) * 60, remaining)
    }

    /// Same cause ⇒ same signature: the failing output with numbers, paths'
    /// variable parts and whitespace folded away.
    nonisolated static func signature(of record: AutoVerificationRecord, report: AutoHandoff) -> String {
        var basis = record.suites.filter { $0.timedOut || $0.exitCode != 0 }
            .map { "\($0.name):\($0.timedOut ? "timeout" : String(String($0.outputTail.suffix(600))))" }
            .joined(separator: "\n")
        if basis.isEmpty { basis = (report.errors ?? []).joined(separator: "\n") }
        if basis.isEmpty { basis = record.reasons.joined(separator: "\n") + record.turnOutcome }
        let folded = basis.lowercased()
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "0x[0-9a-f]+", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let digest = SHA256.hash(data: Data(folded.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Advisor

    private var advisorEnabled: Bool { settings.role(.advisor).enabled }

    /// One Advisor turn. The session is started once per run and reused, so
    /// a later checkpoint has the earlier ones in its context. Nil when the
    /// Advisor could not answer; the run goes on without it.
    private func consultAdvisor(_ checkpoint: AutoAdvisorCheckpoint, sections: [(String, String)]) async -> AutoHandoff? {
        let previous = run.phase
        setPhase(.advising)
        defer { if !run.phase.isFinished { setPhase(previous) } }
        log(.advisor, "Advisor checkpoint: \(checkpoint.rawValue)")
        guard let main else { return nil }
        do {
            let handle: AutoSessionHandle
            if let advisor {
                handle = advisor
            } else {
                handle = try await startSpecialist(.advisor, main: main)
                advisor = handle
            }
            let prompt = AutoPrompts.specialist(
                .advisor, instructions: settings.role(.advisor).instructions,
                body: AutoPrompts.advisorPacket(checkpoint: checkpoint, task: run.task, sections: sections))
            let result = try await turn(handle, prompt, role: .advisor)
            guard result.outcome == .completed else {
                log(.warning, "The Advisor did not answer", detail: result.outcome.description)
                return nil
            }
            let review = AutoHandoff.parse(result.text)
            record(review, from: .advisor, handle: handle)
            log(.advisor, "Advisor: \(review.verdict ?? "no verdict")", detail: review.digest(limit: 6_000))
            return review
        } catch {
            log(.warning, "The Advisor was skipped", detail: "\(error)")
            return nil
        }
    }

    // MARK: - Decisions

    private func decide(
        _ kind: AutoDecisionKind, state: String, deterministic: String, forced: (String, String)? = nil
    ) async -> AutoDecisionRecord {
        if !engineLoaded, settings.decisions.authority(for: kind) != .off {
            engineLoaded = true
            engine = await environment.decisionEngine()
        }
        let record = await AutoDecisionResolver.resolve(
            kind, state: state, deterministic: deterministic,
            forced: forced.map { (action: $0.0, reason: $0.1) },
            settings: settings.decisions, engine: engine, now: environment.now())
        run.record(record)
        var detail = "Deterministic: \(record.deterministic)\nAuthority: \(record.authority.rawValue)"
        if let answer = record.answer {
            let distribution = answer.probabilities.sorted { $0.value > $1.value }
                .map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
            detail += "\nLaya: \(answer.choice) (\(distribution))"
        } else if let error = record.engineError {
            detail += "\nLaya: \(error)"
        }
        if let override = record.override { detail += "\nPolicy: \(override)" }
        log(.decision, "\(kind.schema.title): \(record.action)", detail: detail)
        publish()
        return record
    }

    private func triageState(evidence: AutoVerificationRecord, report: AutoHandoff, sameFailures: Int, retries: Int) -> String {
        """
        Task: \(run.task)
        Worker attempts so far: \(evidence.attempt), retries used: \(retries), same failure in a row: \(sameFailures)
        Worker says: \(report.status ?? "nothing") — \(report.summary.map { String($0.prefix(300)) } ?? "")
        \(evidence.summary.prefix(1_400))
        """
    }

    private func completionState(report: AutoHandoff, evidence: AutoVerificationRecord) -> String {
        """
        Task: \(run.task)
        Changed files: \(evidence.changedFiles.count) (\(evidence.changedFiles.prefix(12).joined(separator: ", ")))
        Verification: \(evidence.verdict.rawValue), suites run: \(evidence.suites.count), attempts: \(evidence.attempt)
        Worker says: \(report.summary.map { String($0.prefix(500)) } ?? "")
        """
    }

    // MARK: - Turns

    private func turn(_ handle: AutoSessionHandle, _ prompt: String, role: AutoRole?) async throws -> AutoTurnResult {
        try checkpoint()
        let minutes = role.map { settings.role($0).maxRuntimeMinutes } ?? settings.policy.maxRunMinutes
        let timeout = min(TimeInterval(max(1, minutes)) * 60, remaining)
        run.update(handle.sessionID) { $0.state = .working }
        publish()
        let result = await environment.runTurn(handle, prompt, timeout)
        run.update(handle.sessionID) {
            $0.state = switch result.outcome {
            case .completed: role == nil ? .idle : .done
            case .timedOut: .timedOut
            case .crashed: .crashed
            case .interrupted, .cancelled: .stopped
            case .failed: .failed
            }
        }
        publish()
        if Task.isCancelled || result.outcome == .cancelled { throw Stop.cancelled }
        if result.outcome == .timedOut, remaining <= 0 {
            throw Stop.failed(String(localized: "The run reached its \(settings.policy.maxRunMinutes)-minute limit."))
        }
        return result
    }

    private var remaining: TimeInterval { deadline.timeIntervalSince(environment.now()) }

    private func checkpoint() throws {
        if Task.isCancelled { throw Stop.cancelled }
        if remaining <= 0 {
            throw Stop.failed(String(localized: "The run reached its \(settings.policy.maxRunMinutes)-minute limit."))
        }
    }

    // MARK: - Ending

    private func finish(_ phase: AutoPhase, reason: String?) {
        run.phase = phase
        run.reason = reason
        run.endedAt = environment.now()
        log(.outcome, phase.displayName, detail: reason)
        switch phase {
        case .completed: notice(.info, String(localized: "Auto run completed."))
        case .cancelled: notice(.info, String(localized: "Auto run cancelled."))
        default: notice(.error, String(localized: "Auto run stopped: \(reason ?? "")"))
        }
        publish()
    }

    private func cleanUp() async {
        for participant in run.participants where participant.role != "main" {
            let worker = participant.role == AutoRole.worker.rawValue
            if worker, let path = participant.worktreePath, settings.policy.removeEmptyWorktrees,
               await environment.changedFiles(path).isEmpty {
                environment.stopSession(participant.sessionID)
                await environment.removeWorktree(path)
                run.update(participant.sessionID) { $0.state = .stopped }
                log(.session, "Removed the Worker's empty worktree", detail: path)
            } else if settings.policy.stopSpecialistsWhenDone {
                environment.stopSession(participant.sessionID)
                run.update(participant.sessionID) { $0.state = .stopped }
            }
        }
        publish()
    }

    // MARK: - Reporting

    private func setPhase(_ phase: AutoPhase) {
        guard run.phase != phase, !run.phase.isFinished else { return }
        run.phase = phase
        log(.phase, phase.displayName)
        notice(.info, phase.displayName)
        publish()
    }

    private func log(_ kind: AutoRunEvent.Kind, _ title: String, detail: String? = nil) {
        run.log(kind, title, detail: detail, at: environment.now())
        publish()
    }

    private func notice(_ level: AgentNotice.Level, _ message: String, open: AutoSessionHandle? = nil) {
        onReport(.notice(level, message, open: open))
    }

    private func publish() {
        onReport(.run(run))
    }
}
