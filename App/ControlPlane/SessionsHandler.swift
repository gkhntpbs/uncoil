import Foundation

extension CapabilityRouter {
    func handleSessions(_ request: ControlRequest) async -> ControlEnvelope {
        let context = callContext(request)
        guard let caller = context.caller else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let all = sessionMap()
        let grants = context.grants

        if let structured = await handleSessionsStructured(request, context: context) {
            return structured
        }

        if let grouped = handleSessionGroups(request, caller: caller, grants: grants) {
            return grouped
        }

        // Milestone 5 orchestration actions live in a separate file.
        if let orchestrated = await handleSessionsOrchestration(
            request, caller: caller, all: all, grants: grants) {
            return orchestrated
        }

        switch request.action {
        case "current":
            return .success(request, data: sessionData(caller, caller: caller, all: all, grants: grants),
                            project_id: caller.projectID.uuidString,
                            target_session_id: caller.id.uuidString)

        case "list":
            let wantAll = request.args["all"]?.boolValue ?? false
            if wantAll && !grants.contains("sessions.read_all") {
                return .failure(request, code: .permissionDenied,
                    message: "listing all projects requires sessions.read_all")
            }
            let records = wantAll
                ? projectStore.sessions
                : projectStore.sessions.filter { $0.projectID == caller.projectID }
            let summaries = records.map { sessionSummary($0, caller: caller, all: all) }
            return .success(request, data: .object(["sessions": .array(summaries)]),
                            project_id: caller.projectID.uuidString)

        case "inspect":
            guard let target = resolveSession(request, caller: caller) else {
                return .failure(request, code: .unknownSession, message: "session not found")
            }
            let relation = PolicyEngine.relation(of: target, to: caller, in: all)
            let read = PolicyEngine.canRead(target: target, caller: caller, relation: relation, grants: grants)
            guard read.allowed else {
                return .failure(request, code: read.code ?? .permissionDenied,
                    message: read.message ?? "read denied", target_session_id: target.id.uuidString)
            }
            return .success(request, data: sessionData(target, caller: caller, all: all, grants: grants),
                            project_id: target.projectID.uuidString,
                            target_session_id: target.id.uuidString)

        case "read_output":
            guard let target = resolveSession(request, caller: caller) else {
                return .failure(request, code: .unknownSession, message: "session not found")
            }
            let relation = PolicyEngine.relation(of: target, to: caller, in: all)
            let read = PolicyEngine.canRead(target: target, caller: caller, relation: relation, grants: grants)
            guard read.allowed else {
                return .failure(request, code: read.code ?? .permissionDenied,
                    message: read.message ?? "read denied", target_session_id: target.id.uuidString)
            }
            var bytes = request.args["bytes"]?.intValue ?? 8192
            bytes = max(1, min(bytes, 262_144))
            guard let buffer = await TerminalRegistry.shared.output(for: target.id) else {
                return .failure(request, code: .sessionNotRunning,
                    message: "no live PTY for this session", retryable: true,
                    target_session_id: target.id.uuidString)
            }
            let tail = buffer.count > bytes ? buffer.suffix(bytes) : buffer
            let text = String(decoding: tail, as: UTF8.self)
            return .success(request, data: .object([
                "bytes": .int(tail.count),
                "truncated": .bool(buffer.count > bytes),
                "output": .string(text),
            ]), project_id: target.projectID.uuidString, target_session_id: target.id.uuidString)

        case "send_text":
            // The oldest way to drive a session, kept for callers written
            // against it; `submit` is the same effect with a structured answer.
            guard let raw = request.args["session_id"]?.stringValue, let target = session(id: raw) else {
                return .failure(request, code: .unknownSession, message: "'session_id' is required and must exist")
            }
            if let refused = authorize(.control, request, context: context, target: target) {
                return refused
            }
            guard let text = request.args["text"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'text' is required",
                                target_session_id: target.id.uuidString)
            }
            guard let control = sessionControl(target) else {
                return .failure(request, code: .sessionNotRunning, message: "session is not running",
                                target_session_id: target.id.uuidString)
            }
            let sentBytes: Int
            if request.args["raw"]?.boolValue ?? false {
                let payload = Data(text.utf8)
                control.sendRaw(payload)
                sentBytes = payload.count
            } else {
                await control.submit(text)
                sentBytes = text.utf8.count
            }
            return .success(request, data: .object(["sent_bytes": .int(sentBytes)]),
                            project_id: target.projectID.uuidString,
                            target_session_id: target.id.uuidString)

        case "list_children":
            let target = resolveSession(request, caller: caller) ?? caller
            let children = projectStore.sessions.filter { $0.parentSessionID == target.id }
            let summaries = children.map { sessionSummary($0, caller: caller, all: all) }
            return .success(request, data: .object(["children": .array(summaries)]),
                            target_session_id: target.id.uuidString)

        case "wait_for_status":
            guard let target = resolveSession(request, caller: caller) else {
                return .failure(request, code: .unknownSession, message: "session not found")
            }
            let relation = PolicyEngine.relation(of: target, to: caller, in: all)
            let read = PolicyEngine.canRead(target: target, caller: caller, relation: relation, grants: grants)
            guard read.allowed else {
                return .failure(request, code: read.code ?? .permissionDenied,
                    message: read.message ?? "read denied", target_session_id: target.id.uuidString)
            }
            guard let wanted = request.args["status"]?.stringValue,
                  let wantedStatus = AgentSessionStatus(rawValue: wanted) else {
                return .failure(request, code: .invalidArgument,
                    message: "'status' must be a valid session status")
            }
            var timeout = Double(request.args["timeout_s"]?.intValue ?? 30)
            timeout = max(1, min(timeout, 120))
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if sessionStore.status(of: target.id) == wantedStatus {
                    return .success(request, data: .object(["status": .string(wantedStatus.rawValue)]),
                                    target_session_id: target.id.uuidString)
                }
                // A cancelled sleep returns at once, so without this a
                // cancelled wait would spin on the main actor until its deadline.
                if Task.isCancelled { return cancelled(request, target) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return .failure(request, code: .timeout,
                message: "session did not reach \(wanted) within \(Int(timeout))s",
                retryable: true, target_session_id: target.id.uuidString)

        case "stop":
            let target = resolveSession(request, caller: caller) ?? caller
            if let refused = authorize(.close, request, context: context, target: target) {
                return refused
            }
            RuntimeClient.shared.kill(sid: target.id)
            sessionStore.setStatus(.terminated, for: target.id)
            projectStore.markSessionEnded(target.id, exitCode: nil)
            return .success(request, data: .object(["stopped": .bool(true)]),
                            project_id: target.projectID.uuidString,
                            target_session_id: target.id.uuidString)

        default:
            return .failure(request, code: .invalidAction, message: "unsupported session action")
        }
    }

    // MARK: - Helpers

    /// Consults the PermissionService for a relationship that policy would
    /// otherwise deny. Returns:
    /// - `nil` when an active directional grant (caller→target) authorizes it —
    ///   the caller should proceed.
    /// - a `PERMISSION_REQUIRED` envelope (with `{grant_key, target}` details)
    ///   when a service exists but no grant is present yet.
    /// - a `PERMISSION_DENIED` envelope when no service is wired (tests).
    func permissionOutcome(
        _ request: ControlRequest, caller: SessionRecord,
        target: SessionRecord, grantKey: String
    ) -> ControlEnvelope? {
        let targetID = target.id.uuidString
        guard let permissions else {
            return .failure(request, code: .permissionDenied,
                message: "not permitted for this relationship",
                target_session_id: targetID)
        }
        if permissions.isGranted(from: caller.id.uuidString, to: targetID, key: grantKey) {
            return nil
        }
        return .failure(request, code: .permissionRequired,
            message: "user permission required: call uncoil_system request_permission",
            details: .object([
                "grant_key": .string(grantKey),
                "target": .string(targetID),
            ]),
            target_session_id: targetID)
    }

    func resolveSession(_ request: ControlRequest, caller: SessionRecord) -> SessionRecord? {
        if let raw = request.args["session_id"]?.stringValue {
            return session(id: raw)
        }
        return caller
    }

    func sessionSummary(_ record: SessionRecord, caller: SessionRecord, all: [UUID: SessionRecord]) -> JSONValue {
        let relation = PolicyEngine.relation(of: record, to: caller, in: all)
        return .object([
            "id": .string(record.id.uuidString),
            "title": .string(record.displayTitle),
            "provider": .string(record.provider.rawValue),
            "status": .string(sessionStore.status(of: record.id).rawValue),
            "relation_to_caller": .string(relation.rawValue),
            "group_id": .string(optional: record.groupID?.uuidString),
        ])
    }

    func sessionData(
        _ record: SessionRecord, caller: SessionRecord,
        all: [UUID: SessionRecord], grants: Set<String>
    ) -> JSONValue {
        let relation = PolicyEngine.relation(of: record, to: caller, in: all)
        let canRead = PolicyEngine.canRead(target: record, caller: caller, relation: relation, grants: grants).allowed
        let canControl = PolicyEngine.canControl(relation: relation, grants: grants).allowed
        let canClose = PolicyEngine.canClose(relation: relation, grants: grants).allowed
        let canCreateChild = PolicyEngine.canCreateChild(grants: grants).allowed
        return .object([
            "id": .string(record.id.uuidString),
            "project_id": .string(record.projectID.uuidString),
            "title": .string(record.displayTitle),
            "provider": .string(record.provider.rawValue),
            "status": .string(sessionStore.status(of: record.id).rawValue),
            "worktree_path": .string(optional: record.worktreePath),
            "parent_session_id": .string(optional: record.parentSessionID?.uuidString),
            "group_id": .string(optional: record.groupID?.uuidString),
            "created_at": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "relation_to_caller": .string(relation.rawValue),
            "can_read": .bool(canRead),
            "can_control": .bool(canControl),
            "can_close": .bool(canClose),
            "can_create_child": .bool(canCreateChild),
            "pending_reports": .int(pendingReportCount(for: record)),
        ])
    }
}
