import Foundation

/// Milestone 5 orchestration: create_child, child coordination
/// (inspect_child / wait_for_children / summarize_children), and the
/// child→parent report inbox (report_to_parent / read_reports).
extension CapabilityRouter {

    // MARK: - Dispatch (called from handleSessions before its default case)

    /// Handles the orchestration actions; returns nil when `request.action`
    /// is not one of them, so the base handler can continue.
    func handleSessionsOrchestration(
        _ request: ControlRequest,
        caller: SessionRecord,
        all: [UUID: SessionRecord],
        grants: Set<String>
    ) async -> ControlEnvelope? {
        switch request.action {
        case "create_child":
            return await createChild(request, caller: caller, grants: grants)
        case "inspect_child":
            return inspectChild(request, caller: caller, all: all, grants: grants)
        case "wait_for_children":
            return await waitForChildren(request, caller: caller)
        case "summarize_children":
            return await summarizeChildren(request, caller: caller)
        case "report_to_parent":
            return reportToParent(request, caller: caller)
        case "read_reports":
            return readReports(request, caller: caller)
        default:
            return nil
        }
    }

    // MARK: - create_child

    private func createChild(
        _ request: ControlRequest, caller: SessionRecord, grants: Set<String>
    ) async -> ControlEnvelope {
        guard let settings else {
            return .failure(request, code: .controlPlaneUnavailable, message: "settings unavailable")
        }
        let create = PolicyEngine.canCreateChild(grants: grants)
        guard create.allowed else {
            return .failure(request, code: create.code ?? .permissionDenied,
                message: create.message ?? "create_child denied")
        }
        guard let presetID = request.args["preset_id"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'preset_id' is required")
        }
        guard let preset = settings.preset(id: presetID) else {
            return .failure(request, code: .invalidArgument,
                message: "unknown preset_id '\(presetID)'")
        }

        // Idempotency: an existing child for this (caller, key) is returned.
        var idempotencyMapKey: String?
        if let key = request.args["idempotency_key"]?.stringValue {
            let mapKey = "\(caller.id.uuidString):\(key)"
            idempotencyMapKey = mapKey
            if let existingID = childIdempotency[mapKey],
               let existing = projectStore.sessions.first(where: { $0.id == existingID }) {
                return .success(request, data: childData(existing, idempotent: true),
                                project_id: existing.projectID.uuidString,
                                target_session_id: existing.id.uuidString)
            }
        }

        // Project resolution + cross-project gating.
        var projectID = caller.projectID
        if let raw = request.args["project_id"]?.stringValue {
            guard let pid = UUID(uuidString: raw), project(id: pid) != nil else {
                return .failure(request, code: .unknownProject, message: "project not found")
            }
            if pid != caller.projectID {
                guard grants.contains("sessions.cross_project") else {
                    return .failure(request, code: .permissionDenied,
                        message: "cross-project child requires the sessions.cross_project grant")
                }
                projectID = pid
            }
        }
        guard let project = project(id: projectID) else {
            return .failure(request, code: .unknownProject, message: "project not found")
        }

        // Worktree validation against the project's real worktrees.
        var worktreePath: String?
        if let wp = request.args["worktree_path"]?.stringValue
            ?? request.args["worktree_id"]?.stringValue {
            let worktrees = GitService.worktrees(repoPath: project.rootPath)
            guard let match = worktrees.first(where: { $0.path == wp }) else {
                return .failure(request, code: .invalidArgument,
                    message: "worktree is not a known worktree of this project")
            }
            worktreePath = match.path
        }

        // Initial prompt: caller-supplied (sanitized) or the preset template.
        var initialPrompt: String? = preset.initialPromptTemplate
        if let raw = request.args["initial_prompt"]?.stringValue {
            guard raw.count <= 4000 else {
                return .failure(request, code: .invalidArgument,
                    message: "initial_prompt exceeds 4000 characters")
            }
            initialPrompt = Self.sanitizePrompt(raw)
        }

        // Capabilities: never escalate beyond preset ∩ caller.
        let requested = request.args["capabilities"]?.arrayValue?.compactMap { $0.stringValue }
        let caps = PolicyEngine.childCapabilities(
            requested: requested, preset: preset.grantedCapabilities, callerGrants: grants)

        let account = preset.provider == .terminal ? nil : settings.defaultAccount(for: preset.provider)
        let record = projectStore.createSession(
            projectID: projectID, provider: preset.provider, accountID: account?.id,
            title: "\(preset.provider.rawValue): \(preset.name)", worktreePath: worktreePath)
        projectStore.updateSession(record.id) {
            $0.parentSessionID = caller.id
            $0.capabilities = caps
            $0.extraArguments = preset.extraArguments.isEmpty ? nil : preset.extraArguments
        }
        let launched = projectStore.sessions.first(where: { $0.id == record.id }) ?? record
        _ = project  // captured by the launcher via projectStore
        childLauncher?(launched, initialPrompt)

        if let idempotencyMapKey { childIdempotency[idempotencyMapKey] = launched.id }

        return .success(request, data: childData(launched, idempotent: false),
                        project_id: launched.projectID.uuidString,
                        target_session_id: launched.id.uuidString,
                        next_actions: ["wait_for_children", "summarize_children", "inspect_child"])
    }

    private func childData(_ record: SessionRecord, idempotent: Bool) -> JSONValue {
        .object([
            "child_session_id": .string(record.id.uuidString),
            "project_id": .string(record.projectID.uuidString),
            "provider": .string(record.provider.rawValue),
            "title": .string(record.displayTitle),
            "status": .string(sessionStore.status(of: record.id).rawValue),
            "capabilities": .array((record.capabilities ?? []).map(JSONValue.string)),
            "worktree_path": .string(optional: record.worktreePath),
            "idempotent_hit": .bool(idempotent),
        ])
    }

    /// Strips control characters (except tab/newline) and trims; length is
    /// bounded by the caller. Defends the child PTY against injected escapes.
    nonisolated static func sanitizePrompt(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - inspect_child

    private func inspectChild(
        _ request: ControlRequest, caller: SessionRecord,
        all: [UUID: SessionRecord], grants: Set<String>
    ) -> ControlEnvelope {
        guard let raw = request.args["session_id"]?.stringValue, let target = session(id: raw) else {
            return .failure(request, code: .unknownSession, message: "'session_id' is required and must exist")
        }
        let relation = PolicyEngine.relation(of: target, to: caller, in: all)
        guard relation == .child else {
            return .failure(request, code: .invalidRelationship,
                message: "inspect_child only inspects direct children",
                target_session_id: target.id.uuidString)
        }
        return .success(request, data: sessionData(target, caller: caller, all: all, grants: grants),
                        project_id: target.projectID.uuidString,
                        target_session_id: target.id.uuidString)
    }

    // MARK: - wait_for_children

    /// Terminal statuses that satisfy "completed_or_waiting".
    private static let settledStatuses: Set<AgentSessionStatus> = [
        .idle, .waitingForInput, .waitingForPermission, .completed, .terminated,
    ]

    private func waitForChildren(_ request: ControlRequest, caller: SessionRecord) async -> ControlEnvelope {
        let directChildren = projectStore.sessions.filter { $0.parentSessionID == caller.id }
        let targetIDs: [UUID]
        if let requested = request.args["session_ids"]?.arrayValue {
            let ids = requested.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }
            // Only wait on actual direct children.
            targetIDs = ids.filter { id in directChildren.contains { $0.id == id } }
        } else {
            targetIDs = directChildren.map(\.id)
        }
        guard !targetIDs.isEmpty else {
            return .success(request, data: .object(["settled": .array([]), "pending": .array([])]))
        }
        var timeout = Double(request.args["timeout_s"]?.intValue ?? 120)
        timeout = max(1, min(timeout, 300))
        let deadline = Date().addingTimeInterval(timeout)

        func pending() -> [UUID] {
            targetIDs.filter { !Self.settledStatuses.contains(sessionStore.status(of: $0)) }
        }
        while Date() < deadline {
            if pending().isEmpty { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let stillPending = pending()
        if stillPending.isEmpty {
            let settled = targetIDs.map { id -> JSONValue in
                .object(["id": .string(id.uuidString), "status": .string(sessionStore.status(of: id).rawValue)])
            }
            return .success(request, data: .object(["settled": .array(settled), "pending": .array([])]))
        }
        return .failure(request, code: .timeout,
            message: "\(stillPending.count) child(ren) did not settle within \(Int(timeout))s",
            retryable: true,
            details: .object(["pending": .array(stillPending.map { JSONValue.string($0.uuidString) })]))
    }

    // MARK: - summarize_children

    private func summarizeChildren(_ request: ControlRequest, caller: SessionRecord) async -> ControlEnvelope {
        let children = projectStore.sessions.filter { $0.parentSessionID == caller.id }
        var summaries: [JSONValue] = []
        for child in children {
            let buffer = await RuntimeClient.shared.peek(sid: child.id)
            let tailText: String
            if let buffer {
                let tail = buffer.count > 2048 ? buffer.suffix(2048) : buffer
                tailText = String(decoding: tail, as: UTF8.self)
            } else {
                tailText = ""
            }
            summaries.append(.object([
                "id": .string(child.id.uuidString),
                "title": .string(child.displayTitle),
                "status": .string(sessionStore.status(of: child.id).rawValue),
                "output_tail": .string(tailText),
                "artifact_count": .int(artifactCount(for: child)),
            ]))
        }
        return .success(request, data: .object(["children": .array(summaries)]),
                        target_session_id: caller.id.uuidString)
    }

    private func artifactCount(for record: SessionRecord) -> Int {
        let root = record.artifactRoot(dataDirectory: dataDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { !$0.hasDirectoryPath }.count
    }

    // MARK: - report_to_parent / read_reports

    private func inboxURL(for record: SessionRecord) -> URL {
        record.artifactRoot(dataDirectory: dataDirectory)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    private func reportToParent(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        guard let parentID = caller.parentSessionID,
              let parent = projectStore.sessions.first(where: { $0.id == parentID }) else {
            return .failure(request, code: .invalidRelationship, message: "caller has no parent session")
        }
        guard let message = request.args["message"]?.stringValue else {
            return .failure(request, code: .invalidArgument, message: "'message' is required")
        }
        guard message.utf8.count <= 8192 else {
            return .failure(request, code: .invalidArgument, message: "message exceeds 8 KB")
        }
        var entry: [String: JSONValue] = [
            "ts": .string(ISO8601DateFormatter().string(from: Date())),
            "from_session": .string(caller.id.uuidString),
            "message": .string(message),
        ]
        if let data = request.args["data"] { entry["data"] = data }

        let url = inboxURL(for: parent)
        guard let lineData = try? JSONEncoder().encode(JSONValue.object(entry)) else {
            return .failure(request, code: .invalidArgument, message: "could not encode report")
        }
        appendLine(lineData, to: url)
        return .success(request, data: .object(["delivered": .bool(true)]),
                        target_session_id: parent.id.uuidString)
    }

    private func readReports(_ request: ControlRequest, caller: SessionRecord) -> ControlEnvelope {
        let url = inboxURL(for: caller)
        let reports = readInbox(url)
        if request.args["clear"]?.boolValue == true {
            try? FileManager.default.removeItem(at: url)
        }
        return .success(request, data: .object([
            "reports": .array(reports),
            "count": .int(reports.count),
        ]), target_session_id: caller.id.uuidString)
    }

    /// Count of pending reports in a session's inbox (surfaced in inspect).
    func pendingReportCount(for record: SessionRecord) -> Int {
        readInbox(inboxURL(for: record)).count
    }

    private func readInbox(_ url: URL) -> [JSONValue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            }
    }

    private func appendLine(_ line: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = line
        payload.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}
