import Foundation

/// Translates Claude Code's `stream-json` output into `AgentEvent`s.
///
/// This is the only place that knows what a Claude stream line looks like.
/// Unlike Codex's notifications, Claude's lines are not self-contained: a
/// streamed reply arrives as `content_block_delta`s that name a block by its
/// index within the current message, and the finished block arrives as an
/// `assistant` message that names nothing at all. So the normalizer carries
/// just enough state to tie the two together — the current message and its
/// open blocks — and is otherwise a function: the same lines always give the
/// same events, which is what lets it be tested from recorded output.
///
/// Control messages (`control_request`, `control_response`) are not here:
/// answering them is the session's job.
///
/// Shapes are read from Claude Code 2.1 as it actually wrote them, with
/// `--output-format stream-json --verbose --include-partial-messages`.
struct ClaudeEventNormalizer {
    private enum BlockKind: Equatable {
        case text
        case thinking
        case toolUse
    }

    private struct Block {
        let itemID: String
        let kind: BlockKind
        var completed = false
    }

    private(set) var providerSessionID: String?
    private var messageID: String?
    private var blocks: [Int: Block] = [:]
    /// Blocks of the current message completed without a stream to name them,
    /// so each gets its own id.
    private var anonymousBlocks = 0
    /// What each tool call is, by `tool_use` id, so its result can finish the
    /// item it started.
    private var tools: [String: AgentItem] = [:]
    /// Set when Claude reports an interrupt, so the `result` that follows is
    /// read as one rather than as a failure.
    private var interrupted = false

    init(providerSessionID: String? = nil) {
        self.providerSessionID = providerSessionID
    }

    mutating func events(for line: JSONValue) -> [AgentEvent] {
        guard let object = line.objectValue, let type = object["type"]?.stringValue else { return [] }
        // A subagent's own conversation streams too, tagged with the tool call
        // that started it. The main timeline shows the delegation, not its
        // insides.
        if case .string = object["parent_tool_use_id"] ?? .null { return [] }
        switch type {
        case "system": return system(object)
        case "stream_event": return stream(object["event"]?.objectValue ?? [:])
        case "assistant": return assistant(object)
        case "user": return user(object)
        case "result": return result(object)
        default: return []
        }
    }

    // MARK: - system

    private mutating func system(_ object: [String: JSONValue]) -> [AgentEvent] {
        switch object["subtype"]?.stringValue {
        case "init":
            guard let id = object["session_id"]?.stringValue, id != providerSessionID else { return [] }
            providerSessionID = id
            return [.sessionBound(providerSessionID: id)]
        case "status":
            return object["status"]?.stringValue == "requesting" ? [.runState(.active)] : []
        case "permission_denied":
            let message = object["message"]?.stringValue
                ?? "\(object["tool_name"]?.stringValue ?? "A tool") was not allowed."
            return [.notice(AgentNotice(level: .warning, message: message))]
        default:
            return []
        }
    }

    // MARK: - stream_event

    private mutating func stream(_ event: [String: JSONValue]) -> [AgentEvent] {
        switch event["type"]?.stringValue {
        case "message_start":
            messageID = event["message"]?.objectValue?["id"]?.stringValue
            blocks = [:]
            anonymousBlocks = 0
            return []
        case "content_block_start":
            guard let index = event["index"]?.intValue,
                  let block = event["content_block"]?.objectValue else { return [] }
            switch block["type"]?.stringValue {
            case "text":
                let id = blockID(index)
                blocks[index] = Block(itemID: id, kind: .text)
                return [.itemStarted(AgentItem(id: id, kind: .agentMessage(text: ""), status: .inProgress, native: nil))]
            case "thinking":
                let id = blockID(index)
                blocks[index] = Block(itemID: id, kind: .thinking)
                return [.itemStarted(AgentItem(id: id, kind: .reasoning(summary: ""), status: .inProgress, native: nil))]
            case "tool_use":
                // Announced once its input is whole, in the `assistant` message:
                // a command line shown before it is complete is a wrong one.
                blocks[index] = Block(itemID: block["id"]?.stringValue ?? blockID(index), kind: .toolUse)
                return []
            default:
                return []
            }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let block = blocks[index],
                  let delta = event["delta"]?.objectValue,
                  delta["type"]?.stringValue == "text_delta",
                  let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.itemDelta(itemID: block.itemID, channel: .text, text: text)]
        default:
            return []
        }
    }

    private func blockID(_ index: Int) -> String {
        "\(messageID ?? "message"):\(index)"
    }

    // MARK: - assistant

    private mutating func assistant(_ object: [String: JSONValue]) -> [AgentEvent] {
        let message = object["message"]?.objectValue ?? [:]
        if messageID == nil { messageID = message["id"]?.stringValue }
        var events: [AgentEvent] = []
        for value in message["content"]?.arrayValue ?? [] {
            guard let block = value.objectValue else { continue }
            switch block["type"]?.stringValue {
            case "text":
                let id = claim(.text)
                events.append(.itemCompleted(AgentItem(
                    id: id, kind: .agentMessage(text: block["text"]?.stringValue ?? ""),
                    status: .completed, native: value)))
            case "thinking":
                let id = claim(.thinking)
                events.append(.itemCompleted(AgentItem(
                    id: id, kind: .reasoning(summary: block["thinking"]?.stringValue ?? ""),
                    status: .completed, native: value)))
            case "tool_use":
                guard let id = block["id"]?.stringValue else { continue }
                _ = claim(.toolUse, id: id)
                let item = AgentItem(
                    id: id,
                    kind: Self.toolKind(
                        name: block["name"]?.stringValue ?? "tool",
                        input: block["input"]?.objectValue ?? [:]),
                    status: .inProgress,
                    native: value)
                tools[id] = item
                events.append(.itemStarted(item))
            default:
                continue
            }
        }
        return events
    }

    /// The id of the open block this finished one belongs to. Claude sends a
    /// block's final form before closing it, so it is the earliest open,
    /// uncompleted block of its kind.
    private mutating func claim(_ kind: BlockKind, id explicit: String? = nil) -> String {
        if let index = blocks.keys.sorted().first(where: {
            blocks[$0]?.kind == kind && blocks[$0]?.completed == false
                && (explicit == nil || blocks[$0]?.itemID == explicit)
        }) {
            blocks[index]?.completed = true
            return blocks[index]!.itemID
        }
        if let explicit { return explicit }
        anonymousBlocks += 1
        return "\(messageID ?? "message"):final-\(anonymousBlocks)"
    }

    // MARK: - user

    private mutating func user(_ object: [String: JSONValue]) -> [AgentEvent] {
        let content = object["message"]?.objectValue?["content"]
        if let text = content?.stringValue {
            if Self.isInterruptMarker(text) { interrupted = true }
            return []
        }
        var events: [AgentEvent] = []
        for value in content?.arrayValue ?? [] {
            guard let block = value.objectValue else { continue }
            switch block["type"]?.stringValue {
            case "text":
                if Self.isInterruptMarker(block["text"]?.stringValue ?? "") { interrupted = true }
            case "tool_result":
                guard let id = block["tool_use_id"]?.stringValue else { continue }
                let failed = block["is_error"]?.boolValue == true
                let output = Self.resultText(block["content"])
                var item = tools.removeValue(forKey: id)
                    ?? AgentItem(id: id, kind: .toolCall(AgentToolCall(origin: .agent, name: "tool")),
                                 status: .inProgress, native: nil)
                if case .command(let command, _, _) = item.kind {
                    item.kind = .command(command: command, output: output, exitCode: nil)
                }
                item.status = failed ? .failed : .completed
                events.append(.itemCompleted(item))
            default:
                continue
            }
        }
        return events
    }

    private static func isInterruptMarker(_ text: String) -> Bool {
        text.hasPrefix("[Request interrupted by user")
    }

    private static func resultText(_ content: JSONValue?) -> String {
        if let text = content?.stringValue { return text }
        return (content?.arrayValue ?? [])
            .compactMap { $0.objectValue?["text"]?.stringValue }
            .joined(separator: "\n")
    }

    // MARK: - result

    private mutating func result(_ object: [String: JSONValue]) -> [AgentEvent] {
        let outcome: AgentTurnOutcome
        if interrupted || object["terminal_reason"]?.stringValue?.hasPrefix("aborted") == true {
            outcome = .interrupted
        } else if object["subtype"]?.stringValue == "success", object["is_error"]?.boolValue != true {
            outcome = .completed
        } else {
            let errors = object["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
            outcome = .failed(errors.isEmpty
                ? object["result"]?.stringValue ?? object["subtype"]?.stringValue
                : errors.joined(separator: "\n"))
        }
        interrupted = false
        // Whatever a turn left running is not coming back.
        tools.removeAll()
        return [.turnCompleted(turnID: nil, outcome: outcome), .runState(.idle)]
    }

    // MARK: - Tools

    /// What a Claude tool call is, in Uncoil's terms.
    static func toolKind(name: String, input: [String: JSONValue]) -> AgentItemKind {
        switch name {
        case "Bash":
            return .command(command: input["command"]?.stringValue ?? "", output: "", exitCode: nil)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue
            return .fileChange(paths: path.map { [$0] } ?? [])
        case "Task", "Agent":
            return .toolCall(AgentToolCall(
                origin: .delegation, name: input["subagent_type"]?.stringValue ?? name))
        default:
            // `mcp__<server>__<tool>`; a server name may itself hold `__`, the
            // tool name does not.
            if name.hasPrefix("mcp__") {
                let rest = String(name.dropFirst(5))
                if let range = rest.range(of: "__", options: .backwards) {
                    return .toolCall(AgentToolCall(
                        origin: .mcp(server: String(rest[..<range.lowerBound])),
                        name: String(rest[range.upperBound...])))
                }
            }
            return .toolCall(AgentToolCall(origin: .agent, name: name))
        }
    }

    // MARK: - Approvals

    /// The approval a `can_use_tool` control request asks for.
    static func approval(requestID: String, request: [String: JSONValue]) -> AgentApproval {
        let tool = request["tool_name"]?.stringValue ?? "tool"
        let input = request["input"]?.objectValue ?? [:]
        let kind: AgentApproval.Kind
        let title: String
        switch toolKind(name: tool, input: input) {
        case .command(let command, _, _):
            kind = .command
            title = command.isEmpty ? tool : command
        case .fileChange(let paths):
            kind = .fileChange
            title = paths.isEmpty ? tool : "\(tool) \(paths.joined(separator: ", "))"
        default:
            kind = .permissions
            title = request["display_name"]?.stringValue ?? tool
        }
        return AgentApproval(
            id: requestID,
            kind: kind,
            title: title,
            detail: request["description"]?.stringValue ?? request["blocked_path"]?.stringValue,
            decisions: ["accept", "acceptForSession", "decline"],
            native: .object(request))
    }

    // MARK: - History

    /// Earlier turns of a conversation, from the transcript Claude keeps on
    /// disk. The transcript holds the same `user` and `assistant` messages the
    /// stream carries, so it is read by the same rules — with the user's own
    /// prompts added, which the stream never echoes back.
    static func history(transcript: String, limit: Int = 200) -> [AgentItem] {
        var normalizer = ClaudeEventNormalizer()
        var items: [String: AgentItem] = [:]
        var order: [String] = []
        func keep(_ item: AgentItem) {
            if items[item.id] == nil { order.append(item.id) }
            var item = item
            if item.status == .inProgress { item.status = .completed }
            items[item.id] = item
        }
        for line in transcript.split(separator: "\n") {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let object = value.objectValue else { continue }
            if object["isSidechain"]?.boolValue == true || object["isMeta"]?.boolValue == true { continue }
            if object["type"]?.stringValue == "user", let prompt = promptText(object) {
                keep(AgentItem(
                    id: object["uuid"]?.stringValue ?? UUID().uuidString,
                    kind: .userMessage(text: prompt, attachments: []),
                    status: .completed, native: nil))
                continue
            }
            for event in normalizer.events(for: value) {
                switch event {
                case .itemStarted(let item), .itemCompleted(let item): keep(item)
                default: break
                }
            }
        }
        return order.suffix(limit).compactMap { items[$0] }
    }

    /// The text of a message the user typed, or nil for a tool result or an
    /// interrupt marker.
    private static func promptText(_ object: [String: JSONValue]) -> String? {
        let content = object["message"]?.objectValue?["content"]
        let text: String
        if let string = content?.stringValue {
            text = string
        } else {
            let blocks = content?.arrayValue?.compactMap(\.objectValue) ?? []
            guard !blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n")
        }
        guard !text.isEmpty, !isInterruptMarker(text) else { return nil }
        return text
    }
}
