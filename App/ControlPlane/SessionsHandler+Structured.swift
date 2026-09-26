import Foundation

/// The semantic session actions: what a session supports, its structured
/// timeline and events, and the effects — submit, interrupt, answer an
/// approval, resume, create.
///
/// None of this knows which provider is behind a session. It asks
/// `sessionControl` for the session's `AgentSessionControl` and the event hub
/// for its timeline; Codex, a terminal, or whatever joins them next answer
/// the same calls, and what differs is in the capability report.
extension CapabilityRouter {
    func handleSessionsStructured(
        _ request: ControlRequest, context: ControlCallContext
    ) async -> ControlEnvelope? {
        switch request.action {
        case "capabilities": return capabilities(request, context: context)
        case "timeline": return timeline(request, context: context)
        case "events": return await events(request, context: context)
        case "submit": return await submit(request, context: context)
        case "interrupt": return interrupt(request, context: context)
        case "respond_approval": return respondApproval(request, context: context)
        case "resume": return resume(request, context: context)
        case "create_session", "create_child": return await createSessionAction(request, context: context)
        default: return nil
        }
    }

    // MARK: - Policy

    /// The single gate every effect goes through: identity first, then the
    /// policy engine, then — where policy defers to the user — their
    /// directional permission. Nil means go ahead.
    func authorize(
        _ effect: PolicyEngine.Effect,
        _ request: ControlRequest,
        context: ControlCallContext,
        target: SessionRecord?
    ) -> ControlEnvelope? {
        guard let caller = context.caller else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        if effect != .read, !context.mayAct {
            return .failure(
                request, code: .identityUnverified,
                message: "this action changes state and the caller session could not be verified",
                details: .object(["reason": .string(context.verification.rawValue)]))
        }
        switch PolicyEngine.authorize(
            effect, caller: caller, target: target, grants: context.grants, in: sessionMap()
        ) {
        case .allow:
            return nil
        case .deny(let code, let message):
            return .failure(request, code: code, message: message,
                            target_session_id: target?.id.uuidString)
        case .requiresPermission(let grantKey):
            guard let target else {
                return .failure(request, code: .permissionDenied, message: "not permitted")
            }
            return permissionOutcome(request, caller: caller, target: target, grantKey: grantKey)
        }
    }

    /// The target an effect names. Effects never default to the caller: acting
    /// on "whatever session I am" by omission is how an agent ends up
    /// interrupting itself.
    private func explicitTarget(_ request: ControlRequest) -> Result<SessionRecord, ControlEnvelopeError> {
        guard let raw = request.args["session_id"]?.stringValue else {
            return .failure(.init(.failure(request, code: .invalidArgument, message: "'session_id' is required")))
        }
        guard let target = session(id: raw) else {
            return .failure(.init(.failure(request, code: .unknownSession, message: "session not found")))
        }
        return .success(target)
    }

    private func readableTarget(
        _ request: ControlRequest, context: ControlCallContext
    ) -> Result<SessionRecord, ControlEnvelopeError> {
        guard let caller = context.caller else {
            return .failure(.init(.failure(request, code: .unknownSession, message: "caller session not found")))
        }
        guard let target = resolveSession(request, caller: caller) else {
            return .failure(.init(.failure(request, code: .unknownSession, message: "session not found")))
        }
        if let refused = authorize(.read, request, context: context, target: target) {
            return .failure(.init(refused))
        }
        return .success(target)
    }

    func capabilityReport(for record: SessionRecord) -> SessionCapabilityReport {
        SessionCapabilityReport.make(
            record: record,
            control: sessionControl(record),
            hasTimeline: eventHub.hasTimeline(for: record.id))
    }

    private func notRunning(_ request: ControlRequest, _ target: SessionRecord) -> ControlEnvelope {
        .failure(request, code: .sessionNotRunning, message: "session is not running",
                 details: .object(["next": .string(
                    capabilityReport(for: target).supports(.resume) ? "resume" : "create_session")]),
                 target_session_id: target.id.uuidString)
    }

    private func unsupported(
        _ request: ControlRequest, _ target: SessionRecord, _ operation: SessionCapabilityReport.Operation
    ) -> ControlEnvelope {
        let report = capabilityReport(for: target)
        return .failure(
            request, code: .unsupportedCapability,
            message: report.operations[operation]?.reason ?? "\(operation.rawValue) is not supported by this session",
            details: .object([
                "operation": .string(operation.rawValue),
                "supported": .array(report.supported.map(JSONValue.string)),
            ]),
            target_session_id: target.id.uuidString)
    }

    // MARK: - Reads

    private func capabilities(_ request: ControlRequest, context: ControlCallContext) -> ControlEnvelope {
        switch readableTarget(request, context: context) {
        case .failure(let error): return error.envelope
        case .success(let target):
            return .success(request, data: capabilityReport(for: target).asJSON,
                            project_id: target.projectID.uuidString,
                            target_session_id: target.id.uuidString)
        }
    }

    private func wireOptions(_ request: ControlRequest) -> AgentWire.Options {
        var options = AgentWire.Options()
        if let limit = request.args["text_limit"]?.intValue {
            options.textLimit = max(256, min(limit, 256 * 1024))
        }
        options.includeNative = request.args["include_native"]?.boolValue ?? false
        return options
    }

    private func timeline(_ request: ControlRequest, context: ControlCallContext) -> ControlEnvelope {
        let target: SessionRecord
        switch readableTarget(request, context: context) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        guard let timeline = eventHub.timeline(for: target.id) else {
            return sessionControl(target) == nil
                ? notRunning(request, target)
                : unsupported(request, target, .timeline)
        }
        let limit = max(1, min(request.args["limit"]?.intValue ?? 50, 500))
        var end = timeline.items.count
        if let before = request.args["before_item_id"]?.stringValue {
            guard let index = timeline.items.firstIndex(where: { $0.id == before }) else {
                return .failure(request, code: .invalidArgument,
                                message: "before_item_id is not in this timeline (it may have aged out)",
                                target_session_id: target.id.uuidString)
            }
            end = index
        }
        let start = max(0, end - limit)
        let page = timeline.items[start..<end]
        let options = wireOptions(request)
        return .success(request, data: .object([
            "state": .object(AgentWire.timelineState(timeline)),
            "items": .array(page.map { AgentWire.item($0, options: options) }),
            "has_more": .bool(start > 0),
            "next_before_item_id": .string(optional: start > 0 ? page.first?.id : nil),
        ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString,
            next_actions: ["events"])
    }

    private func events(_ request: ControlRequest, context: ControlCallContext) async -> ControlEnvelope {
        let target: SessionRecord
        switch readableTarget(request, context: context) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        let publishes = eventHub.hasTimeline(for: target.id)
            || sessionControl(target)?.capabilities.contains(.events) == true
        guard publishes else {
            return sessionControl(target) == nil
                ? notRunning(request, target)
                : unsupported(request, target, .events)
        }
        let after = max(0, request.args["after_sequence"]?.intValue ?? 0)
        let limit = max(1, min(request.args["limit"]?.intValue ?? 100, 1_000))
        let wait = max(0, min(request.args["wait_s"]?.doubleValue ?? 0, 120))
        let deadline = Date().addingTimeInterval(wait)
        let options = wireOptions(request)

        while true {
            let page = eventHub.records(for: target.id, after: after, limit: limit)
            let current = eventHub.timeline(for: target.id)?.sequence ?? 0
            let running = sessionControl(target) != nil
            // A client ahead of the timeline is holding a sequence from a
            // timeline that has since been replaced — say so, like a gap.
            let reset = after > current
            if !page.records.isEmpty || reset || !running || Date() >= deadline {
                return .success(request, data: .object([
                    "events": .array(page.records.map { AgentWire.record($0, options: options) }),
                    "next_after_sequence": .int(page.records.last?.sequence ?? min(after, current)),
                    "gap": .bool(page.gap || reset),
                    "oldest_sequence": page.oldest.map(JSONValue.int) ?? .null,
                    "sequence": .int(current),
                    "running": .bool(running),
                ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString)
            }
            if Task.isCancelled { return cancelled(request, target) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func cancelled(_ request: ControlRequest, _ target: SessionRecord? = nil) -> ControlEnvelope {
        .failure(request, code: .cancelled, message: "the request was cancelled",
                 target_session_id: target?.id.uuidString)
    }

    // MARK: - Effects

    private func submit(_ request: ControlRequest, context: ControlCallContext) async -> ControlEnvelope {
        let target: SessionRecord
        switch explicitTarget(request) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        if let refused = authorize(.control, request, context: context, target: target) { return refused }
        guard let raw = request.args["input"]?.stringValue ?? request.args["text"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'input' is required",
                            target_session_id: target.id.uuidString)
        }
        guard raw.count <= Self.initialPromptLimit else {
            return .failure(request, code: .invalidArgument,
                            message: "input exceeds \(Self.initialPromptLimit) characters",
                            target_session_id: target.id.uuidString)
        }
        let input = Self.sanitizePrompt(raw)
        guard !input.isEmpty else {
            return .failure(request, code: .invalidArgument, message: "'input' is empty",
                            target_session_id: target.id.uuidString)
        }
        guard let control = sessionControl(target) else { return notRunning(request, target) }
        guard control.isReady else {
            return .failure(request, code: .providerUnavailable,
                            message: "the session's agent is not ready to take a prompt yet",
                            retryable: true, target_session_id: target.id.uuidString)
        }
        let before = eventHub.timeline(for: target.id)?.sequence ?? 0
        await control.submit(input)
        return .success(request, data: .object([
            "accepted": .bool(true),
            "via": .string(control.capabilities.contains(.structuredTurns) ? "structured" : "terminal"),
            "after_sequence": .int(before),
        ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString,
            next_actions: control.capabilities.contains(.events) ? ["events", "timeline"] : ["read_output"])
    }

    private func interrupt(_ request: ControlRequest, context: ControlCallContext) -> ControlEnvelope {
        let target: SessionRecord
        switch explicitTarget(request) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        if let refused = authorize(.interrupt, request, context: context, target: target) { return refused }
        guard let control = sessionControl(target) else { return notRunning(request, target) }
        control.interrupt()
        return .success(request, data: .object([
            "interrupted": .bool(true),
            "via": .string(control.capabilities.contains(.structuredTurns) ? "structured" : "terminal"),
        ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString)
    }

    private func respondApproval(_ request: ControlRequest, context: ControlCallContext) -> ControlEnvelope {
        let target: SessionRecord
        switch explicitTarget(request) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        if let refused = authorize(.respondToApproval, request, context: context, target: target) {
            return refused
        }
        guard let approvalID = request.args["approval_id"]?.stringValue,
              let decision = request.args["decision"]?.stringValue else {
            return .failure(request, code: .invalidArgument,
                            message: "'approval_id' and 'decision' are required",
                            target_session_id: target.id.uuidString)
        }
        guard let control = sessionControl(target) else { return notRunning(request, target) }
        guard control.capabilities.contains(.approvals) else {
            return unsupported(request, target, .respondApproval)
        }
        if let pending = eventHub.timeline(for: target.id)?.pendingApprovals
            .first(where: { $0.id == approvalID }),
           !pending.decisions.isEmpty, !pending.decisions.contains(decision) {
            return .failure(request, code: .invalidArgument,
                            message: "'\(decision)' is not a decision this approval offers",
                            details: .object(["valid_decisions": .array(pending.decisions.map(JSONValue.string))]),
                            target_session_id: target.id.uuidString)
        }
        guard control.respond(toApproval: approvalID, decision: decision) else {
            return .failure(request, code: .invalidArgument,
                            message: "the session has no pending approval '\(approvalID)'",
                            target_session_id: target.id.uuidString)
        }
        return .success(request, data: .object([
            "answered": .bool(true),
            "approval_id": .string(approvalID),
            "decision": .string(decision),
        ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString)
    }

    private func resume(_ request: ControlRequest, context: ControlCallContext) -> ControlEnvelope {
        let target: SessionRecord
        switch explicitTarget(request) {
        case .failure(let error): return error.envelope
        case .success(let found): target = found
        }
        if let refused = authorize(.resume, request, context: context, target: target) { return refused }
        let report = capabilityReport(for: target)
        guard !report.running else {
            return .failure(request, code: .invalidStateTransition, message: "session is already running",
                            target_session_id: target.id.uuidString)
        }
        guard report.supports(.resume) else { return unsupported(request, target, .resume) }
        guard let childLauncher else {
            return .failure(request, code: .controlPlaneUnavailable, message: "sessions cannot be started here",
                            target_session_id: target.id.uuidString)
        }
        var input: String?
        if let raw = request.args["input"]?.stringValue {
            guard raw.count <= Self.initialPromptLimit else {
                return .failure(request, code: .invalidArgument,
                                message: "input exceeds \(Self.initialPromptLimit) characters",
                                target_session_id: target.id.uuidString)
            }
            input = Self.sanitizePrompt(raw)
        }
        childLauncher(target, input)
        return .success(request, data: .object([
            "resumed": .bool(true),
            "provider_session_id": .string(optional: target.providerSessionID),
        ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString,
            next_actions: ["capabilities", "events"])
    }

    private func createSessionAction(
        _ request: ControlRequest, context: ControlCallContext
    ) async -> ControlEnvelope {
        if let refused = authorize(.createSession, request, context: context, target: nil) { return refused }
        guard let caller = context.caller else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }

        // An existing session for this (caller, key) is the answer to a retry.
        var ledgerKey: String?
        if let key = request.args["idempotency_key"]?.stringValue, !key.isEmpty {
            let mapKey = "\(caller.id.uuidString):\(key)"
            ledgerKey = mapKey
            if let existingID = childIdempotency[mapKey],
               let existing = projectStore.sessions.first(where: { $0.id == existingID }) {
                return .success(request, data: createdData(existing, idempotent: true),
                                project_id: existing.projectID.uuidString,
                                target_session_id: existing.id.uuidString,
                                warnings: ["idempotent_replay: returned the session already created with this idempotency_key"])
            }
        }

        let spec: SessionCreationSpec
        switch await sessionCreationSpec(request, context: context, requirePreset: request.action == "create_child") {
        case .failure(let error): return error.envelope
        case .success(let parsed): spec = parsed
        }
        // The spec was awaited; a concurrent retry may have won the race.
        if let ledgerKey, let existingID = childIdempotency[ledgerKey],
           let existing = projectStore.sessions.first(where: { $0.id == existingID }) {
            return .success(request, data: createdData(existing, idempotent: true),
                            project_id: existing.projectID.uuidString,
                            target_session_id: existing.id.uuidString)
        }
        let created = createSession(spec, parent: caller)
        if let ledgerKey { childIdempotency[ledgerKey] = created.id }

        return .success(request, data: createdData(created, idempotent: false),
                        project_id: created.projectID.uuidString,
                        target_session_id: created.id.uuidString,
                        warnings: spec.warnings,
                        next_actions: ["capabilities", "events", "wait_for_children", "summarize_children"])
    }

    func createdData(_ record: SessionRecord, idempotent: Bool) -> JSONValue {
        let launch = record.launchSelection
        return .object([
            // Both names: `session_id` is the one every other action takes;
            // `child_session_id` is what create_child has always returned.
            "session_id": .string(record.id.uuidString),
            "child_session_id": .string(record.id.uuidString),
            "parent_session_id": .string(optional: record.parentSessionID?.uuidString),
            "project_id": .string(record.projectID.uuidString),
            "provider": .string(record.provider.rawValue),
            "account_id": .string(optional: record.accountID?.uuidString),
            "title": .string(record.displayTitle),
            "status": .string(sessionStore.status(of: record.id).rawValue),
            "launch": .object([
                "model": .string(optional: launch?.model),
                "effort": .string(optional: launch?.effort),
                "working_mode": .string(optional: launch?.workingMode?.rawValue),
            ]),
            "capabilities": .array((record.capabilities ?? []).map(JSONValue.string)),
            "worktree_path": .string(optional: record.worktreePath),
            "idempotent_hit": .bool(idempotent),
        ])
    }
}
