import Foundation

extension CapabilityRouter {
    func handleSessions(_ request: ControlRequest) async -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let all = sessionMap()
        let grants = PolicyEngine.grants(for: caller)

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
            guard let buffer = await RuntimeClient.shared.peek(sid: target.id) else {
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
            return await controlWrite(request, caller: caller, all: all, grants: grants) { target in
                guard let text = request.args["text"]?.stringValue else {
                    return .failure(request, code: .invalidArgument, message: "'text' is required",
                                    target_session_id: target.id.uuidString)
                }
                let raw = request.args["raw"]?.boolValue ?? false
                let payload = raw ? text : text + "\n"
                RuntimeClient.shared.sendText(Data(payload.utf8), sid: target.id)
                return .success(request, data: .object(["sent_bytes": .int(payload.utf8.count)]),
                                project_id: target.projectID.uuidString,
                                target_session_id: target.id.uuidString)
            }

        case "interrupt":
            return await controlWrite(request, caller: caller, all: all, grants: grants) { target in
                RuntimeClient.shared.interrupt(sid: target.id)
                return .success(request, data: .object(["interrupted": .bool(true)]),
                                project_id: target.projectID.uuidString,
                                target_session_id: target.id.uuidString)
            }

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
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return .failure(request, code: .timeout,
                message: "session did not reach \(wanted) within \(Int(timeout))s",
                retryable: true, target_session_id: target.id.uuidString)

        case "stop":
            let target = resolveSession(request, caller: caller) ?? caller
            let relation = PolicyEngine.relation(of: target, to: caller, in: all)
            let close = PolicyEngine.canClose(relation: relation, grants: grants)
            guard close.allowed else {
                return .failure(request, code: close.code ?? .permissionDenied,
                    message: close.message ?? "close denied", target_session_id: target.id.uuidString)
            }
            RuntimeClient.shared.kill(sid: target.id)
            sessionStore.setStatus(.terminated, for: target.id)
            return .success(request, data: .object(["stopped": .bool(true)]),
                            project_id: target.projectID.uuidString,
                            target_session_id: target.id.uuidString)

        default:
            return .failure(request, code: .invalidAction, message: "unsupported session action")
        }
    }

    // MARK: - Helpers

    /// Shared control-path guard for send_text/interrupt: requires an explicit
    /// target, control grant, and a direct-child relationship.
    private func controlWrite(
        _ request: ControlRequest,
        caller: SessionRecord,
        all: [UUID: SessionRecord],
        grants: Set<String>,
        _ body: (SessionRecord) -> ControlEnvelope
    ) async -> ControlEnvelope {
        guard let raw = request.args["session_id"]?.stringValue, let target = session(id: raw) else {
            return .failure(request, code: .unknownSession, message: "'session_id' is required and must exist")
        }
        let relation = PolicyEngine.relation(of: target, to: caller, in: all)
        let control = PolicyEngine.canControl(relation: relation, grants: grants)
        guard control.allowed else {
            return .failure(request, code: control.code ?? .permissionDenied,
                message: control.message ?? "control denied", target_session_id: target.id.uuidString)
        }
        return body(target)
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
        return .object([
            "id": .string(record.id.uuidString),
            "project_id": .string(record.projectID.uuidString),
            "title": .string(record.displayTitle),
            "provider": .string(record.provider.rawValue),
            "status": .string(sessionStore.status(of: record.id).rawValue),
            "worktree_path": .string(optional: record.worktreePath),
            "parent_session_id": .string(optional: record.parentSessionID?.uuidString),
            "created_at": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "relation_to_caller": .string(relation.rawValue),
            "can_read": .bool(canRead),
            "can_control": .bool(canControl),
            "can_close": .bool(canClose),
            "can_create_child": .bool(false),
        ])
    }
}
