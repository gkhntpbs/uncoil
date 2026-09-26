import Foundation

/// The control plane's wire form of the AgentSession model.
///
/// Normalisation happens once, in the provider integration; this only writes
/// the result down. Field names are part of the MCP contract — add, never
/// rename — and each carries the provider's `native` payload only when asked,
/// because it is large and most callers never need it.
enum AgentWire {
    struct Options {
        /// Command output and message text beyond this many bytes is cut
        /// from the front, and the item says so.
        var textLimit = 16 * 1024
        var includeNative = false
    }

    static func item(_ item: AgentItem, options: Options = Options()) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id),
            "kind": .string(item.kind.name),
            "status": .string(item.status.rawValue),
        ]
        func text(_ key: String, _ value: String) {
            let (kept, truncated) = clip(value, options.textLimit)
            object[key] = .string(kept)
            if truncated { object["\(key)_truncated"] = .bool(true) }
        }
        switch item.kind {
        case .userMessage(let body, let attachments):
            text("text", body)
            if !attachments.isEmpty {
                object["attachments"] = .array(attachments.map(attachment))
            }
        case .agentMessage(let body):
            text("text", body)
        case .reasoning(let summary):
            text("summary", summary)
        case .command(let command, let output, let exitCode):
            object["command"] = .string(command)
            text("output", output)
            object["exit_code"] = exitCode.map(JSONValue.int) ?? .null
        case .fileChange(let paths):
            object["paths"] = .array(paths.map(JSONValue.string))
        case .toolCall(let call):
            object["tool"] = .string(call.name)
            switch call.origin {
            case .mcp(let server):
                object["origin"] = .string("mcp")
                object["server"] = .string(server)
            case .agent:
                object["origin"] = .string("agent")
            case .delegation:
                object["origin"] = .string("delegation")
            }
        case .other:
            break
        }
        if options.includeNative, let native = item.native { object["native"] = native }
        return .object(object)
    }

    static func attachment(_ attachment: AgentAttachment) -> JSONValue {
        .object([
            "kind": .string(attachment.kind.rawValue),
            "path": .string(attachment.promptPath),
        ])
    }

    static func approval(_ approval: AgentApproval, options: Options = Options()) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(approval.id),
            "kind": .string(approval.kind.rawValue),
            "title": .string(approval.title),
            "detail": .string(optional: approval.detail),
            "decisions": .array(approval.decisions.map(JSONValue.string)),
        ]
        if options.includeNative, let native = approval.native { object["native"] = native }
        return .object(object)
    }

    static func outcome(_ outcome: AgentTurnOutcome?) -> JSONValue {
        switch outcome {
        case nil: .null
        case .completed: .object(["status": .string("completed")])
        case .interrupted: .object(["status": .string("interrupted")])
        case .failed(let message):
            .object(["status": .string("failed"), "message": .string(optional: message)])
        }
    }

    static func account(_ state: AgentAccountState?) -> JSONValue {
        switch state {
        case nil: .null
        case .authenticated(let name):
            .object(["status": .string("authenticated"), "name": .string(optional: name)])
        case .loginRequired: .object(["status": .string("login_required")])
        case .unavailable(let reason):
            .object(["status": .string("unavailable"), "reason": .string(reason)])
        }
    }

    static func notice(_ notice: AgentNotice) -> JSONValue {
        .object(["level": .string(notice.level.rawValue), "message": .string(notice.message)])
    }

    /// The event itself, tagged by `type`. The names are the cases', in
    /// snake case, and are stable.
    static func event(_ event: AgentEvent, options: Options = Options()) -> JSONValue {
        switch event {
        case .sessionBound(let id):
            return .object(["type": .string("session_bound"), "provider_session_id": .string(id)])
        case .historyLoaded(let items):
            return .object([
                "type": .string("history_loaded"),
                "items": .array(items.map { item($0, options: options) }),
            ])
        case .turnStarted(let turnID):
            return .object(["type": .string("turn_started"), "turn_id": .string(optional: turnID)])
        case .turnCompleted(let turnID, let result):
            return .object([
                "type": .string("turn_completed"),
                "turn_id": .string(optional: turnID),
                "outcome": outcome(result),
            ])
        case .itemStarted(let started):
            return .object(["type": .string("item_started"), "item": item(started, options: options)])
        case .itemDelta(let itemID, let channel, let text):
            return .object([
                "type": .string("item_delta"),
                "item_id": .string(itemID),
                "channel": .string(channel.rawValue),
                "text": .string(text),
            ])
        case .itemCompleted(let completed):
            return .object(["type": .string("item_completed"), "item": item(completed, options: options)])
        case .runState(let state):
            return .object(["type": .string("run_state"), "state": .string(state.rawValue)])
        case .approvalRequested(let request):
            return .object([
                "type": .string("approval_requested"),
                "approval": approval(request, options: options),
            ])
        case .approvalResolved(let approvalID, let decision):
            return .object([
                "type": .string("approval_resolved"),
                "approval_id": .string(approvalID),
                "decision": .string(decision),
            ])
        case .account(let state):
            return .object(["type": .string("account"), "account": account(state)])
        case .notice(let message):
            return .object(["type": .string("notice"), "notice": notice(message)])
        }
    }

    static func record(_ record: AgentEventRecord, options: Options = Options()) -> JSONValue {
        .object([
            "sequence": .int(record.sequence),
            "date": .string(ISO8601DateFormatter().string(from: record.date)),
            "event": event(record.event, options: options),
        ])
    }

    /// The timeline's state without its items; `items` are paged separately.
    static func timelineState(_ timeline: AgentTimeline) -> [String: JSONValue] {
        [
            "sequence": .int(timeline.sequence),
            "provider_session_id": .string(optional: timeline.providerSessionID),
            "turn_in_progress": .bool(timeline.turnInProgress),
            "active_turn_id": .string(optional: timeline.activeTurnID),
            "last_turn_outcome": outcome(timeline.lastTurnOutcome),
            "run_state": .string(optional: timeline.runState?.rawValue),
            "pending_approvals": .array(timeline.pendingApprovals.map { approval($0) }),
            "account": account(timeline.account),
            "notices": .array(timeline.notices.suffix(10).map(notice)),
            "item_count": .int(timeline.items.count),
        ]
    }

    /// Keeps the end of a long text, which is where a command's result is.
    private static func clip(_ text: String, _ limit: Int) -> (String, Bool) {
        guard limit > 0, text.utf8.count > limit else { return (text, false) }
        var kept = Substring(text.suffix(limit))
        while kept.utf8.count > limit { kept = kept.dropFirst() }
        return (String(kept), true)
    }
}
