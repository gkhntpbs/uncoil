import Foundation

/// Milestone 5 orchestration: child coordination
/// (inspect_child / wait_for_children / summarize_children), and the
/// child→parent report inbox (report_to_parent / read_reports). Creating a
/// child is `create_session`, in SessionsHandler+Structured.
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

    // MARK: - Prompts

    /// Strips control characters (except tab/newline) and trims; length is
    /// bounded by the caller. Defends the child PTY against injected escapes —
    /// C1 controls included, since a terminal reads 0x9B as the start of an
    /// escape sequence just as it reads ESC [.
    nonisolated static func sanitizePrompt(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value))
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
            if Task.isCancelled { return cancelled(request) }
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
            let buffer = await TerminalRegistry.shared.output(for: child.id)
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
