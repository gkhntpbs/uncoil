import Foundation

/// Translates Codex app-server messages into `AgentEvent`s.
///
/// This is the only place that knows what a Codex notification looks like.
/// It is pure and stateless: the same message always yields the same events,
/// which is what lets it be tested without a server. Server *requests* —
/// approvals — are not here, because answering them is the session's job; the
/// session publishes their normalized form itself.
enum CodexEventNormalizer {
    static func events(method: String, params: JSONValue) -> [AgentEvent] {
        let object = params.objectValue ?? [:]
        switch method {
        case "thread/started":
            guard let id = object["thread"]?.objectValue?["id"]?.stringValue else { return [] }
            return [.sessionBound(providerSessionID: id)]
        case "thread/status/changed":
            let status = object["status"]?.stringValue
                ?? object["thread"]?.objectValue?["status"]?.stringValue
            return status.flatMap(AgentRunState.init(rawValue:)).map { [.runState($0)] } ?? []
        case "turn/started":
            return [.turnStarted(turnID: object["turn"]?.objectValue?["id"]?.stringValue)]
        case "turn/completed":
            let turn = object["turn"]?.objectValue ?? [:]
            return [.turnCompleted(turnID: turn["id"]?.stringValue, outcome: outcome(turn))]
        case "item/started":
            return object["item"].flatMap(item).map { [.itemStarted($0)] } ?? []
        case "item/completed":
            return object["item"].flatMap(item).map { [.itemCompleted($0)] } ?? []
        case "item/agentMessage/delta":
            return delta(object, channel: .text)
        case "item/commandExecution/outputDelta":
            return delta(object, channel: .output)
        case "item/reasoning/summaryTextDelta", "item/plan/delta":
            return delta(object, channel: .text)
        case "item/reasoning/summaryPartAdded":
            // A second summary part starts a new paragraph of the same item.
            guard (object["summaryIndex"]?.intValue ?? 0) > 0,
                  let itemID = object["itemId"]?.stringValue else { return [] }
            return [.itemDelta(itemID: itemID, channel: .text, text: "\n\n")]
        case "turn/plan/updated":
            return planUpdated(object)
        case "account/updated":
            return [.account(account(params))]
        default:
            return []
        }
    }

    /// The thread a `thread/start` or `thread/resume` reply describes.
    static func threadOpened(_ result: JSONValue) -> [AgentEvent] {
        guard let object = result.objectValue,
              let id = object["thread"]?.objectValue?["id"]?.stringValue else { return [] }
        var events: [AgentEvent] = [.sessionBound(providerSessionID: id)]
        let history = history(from: result)
        if !history.isEmpty {
            events.append(.historyLoaded(history))
        }
        return events
    }

    static func history(from result: JSONValue) -> [AgentItem] {
        guard let object = result.objectValue else { return [] }
        let turns = object["initialTurnsPage"]?.objectValue?["data"]?.arrayValue
            ?? object["thread"]?.objectValue?["turns"]?.arrayValue
            ?? []
        return turns
            .flatMap { $0.objectValue?["items"]?.arrayValue ?? [] }
            .compactMap(item)
            .map { item in
                var item = item
                if item.status == .inProgress { item.status = .completed }
                return item
            }
    }

    static func item(_ value: JSONValue) -> AgentItem? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let type = object["type"]?.stringValue else { return nil }
        return AgentItem(
            id: id,
            kind: kind(type: type, object),
            status: status(object["status"]?.stringValue),
            native: value
        )
    }

    static func account(_ value: JSONValue) -> AgentAccountState {
        let object = value.objectValue ?? [:]
        if let account = object["account"]?.objectValue {
            return .authenticated(account["email"]?.stringValue ?? account["type"]?.stringValue)
        }
        return object["requiresOpenaiAuth"]?.boolValue == true ? .loginRequired : .authenticated(nil)
    }

    private static func kind(type: String, _ object: [String: JSONValue]) -> AgentItemKind {
        switch type {
        case "userMessage":
            return .userMessage(text: messageText(object) ?? "", attachments: attachments(object))
        case "agentMessage":
            return .agentMessage(text: object["text"]?.stringValue ?? messageText(object) ?? "")
        case "reasoning":
            let summary = object["summary"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: "\n")
                ?? object["text"]?.stringValue
                ?? ""
            return .reasoning(summary: summary)
        case "commandExecution":
            return .command(
                command: object["command"]?.stringValue ?? "",
                output: object["aggregatedOutput"]?.stringValue ?? "",
                exitCode: object["exitCode"]?.intValue
            )
        case "fileChange":
            return .fileChange((object["changes"]?.arrayValue ?? []).compactMap(fileChange))
        case "plan":
            return .plan(AgentPlan(text: object["text"]?.stringValue))
        case "mcpToolCall":
            return .toolCall(AgentToolCall(
                origin: .mcp(server: object["server"]?.stringValue ?? "MCP"),
                name: object["tool"]?.stringValue ?? object["name"]?.stringValue ?? "tool"
            ))
        case "dynamicToolCall":
            return .toolCall(AgentToolCall(
                origin: .agent,
                name: object["tool"]?.stringValue ?? object["name"]?.stringValue ?? "tool"
            ))
        case "collabAgentToolCall":
            return .toolCall(AgentToolCall(
                origin: .delegation,
                name: object["tool"]?.stringValue ?? "agent"
            ))
        default:
            return .other(type: type)
        }
    }

    /// One entry of a `fileChange` item's `changes`. The kind is an object
    /// (`{"type":"update","move_path":…}`) in the current protocol and a bare
    /// string in older ones.
    private static func fileChange(_ value: JSONValue) -> AgentFileChange? {
        guard let object = value.objectValue, let path = object["path"]?.stringValue else { return nil }
        let kindName = object["kind"]?.objectValue?["type"]?.stringValue ?? object["kind"]?.stringValue
        let diff = object["diff"]?.stringValue
        return AgentFileChange(
            path: path,
            kind: kindName.flatMap(AgentFileChange.Kind.init(rawValue:)) ?? .update,
            diff: diff?.isEmpty == false ? diff : nil
        )
    }

    /// Codex's plan is turn state, not an item; it becomes one item per turn,
    /// replaced whole each time the plan changes.
    private static func planUpdated(_ object: [String: JSONValue]) -> [AgentEvent] {
        let steps = (object["plan"]?.arrayValue ?? []).compactMap { value -> AgentPlan.Step? in
            guard let step = value.objectValue, let text = step["step"]?.stringValue else { return nil }
            let status = step["status"]?.stringValue.flatMap(AgentPlan.Step.Status.init(rawValue:)) ?? .pending
            return AgentPlan.Step(text: text, status: status)
        }
        guard !steps.isEmpty else { return [] }
        let turnID = object["turnId"]?.stringValue ?? "turn"
        let done = steps.allSatisfy { $0.status == .completed }
        return [.itemCompleted(AgentItem(
            id: "plan-\(turnID)",
            kind: .plan(AgentPlan(text: object["explanation"]?.stringValue, steps: steps)),
            status: done ? .completed : .inProgress,
            native: .object(object)
        ))]
    }

    private static func status(_ value: String?) -> AgentItem.Status {
        switch value {
        case "completed": .completed
        case "failed": .failed
        case "declined": .declined
        default: .inProgress
        }
    }

    private static func outcome(_ turn: [String: JSONValue]) -> AgentTurnOutcome {
        switch turn["status"]?.stringValue {
        case "failed":
            .failed(turn["error"]?.objectValue?["message"]?.stringValue)
        case "interrupted":
            .interrupted
        default:
            .completed
        }
    }

    private static func delta(_ object: [String: JSONValue], channel: AgentDeltaChannel) -> [AgentEvent] {
        guard let text = object["delta"]?.stringValue,
              let itemID = object["itemId"]?.stringValue else { return [] }
        return [.itemDelta(itemID: itemID, channel: channel, text: text)]
    }

    /// Images a user message carried. Codex has no other kind of attachment;
    /// a file reaches it as a path in the text.
    private static func attachments(_ object: [String: JSONValue]) -> [AgentAttachment] {
        (object["content"]?.arrayValue ?? []).compactMap { content in
            let value = content.objectValue ?? [:]
            switch value["type"]?.stringValue {
            case "localImage":
                guard let path = value["path"]?.stringValue else { return nil }
                return AgentAttachment(
                    kind: .image, url: URL(fileURLWithPath: path), promptPath: path
                )
            case "image":
                guard let string = value["url"]?.stringValue,
                      let url = URL(string: string) else { return nil }
                return AgentAttachment(kind: .image, url: url, promptPath: string)
            default:
                return nil
            }
        }
    }

    /// The `turn/start` input for a prompt and its attachments. Images go as
    /// images; files are already named in the text.
    static func turnInput(text: String, attachments: [AgentAttachment]) -> JSONValue {
        var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for attachment in attachments where attachment.kind == .image {
            input.append(attachment.url.isFileURL
                ? .object(["type": .string("localImage"), "path": .string(attachment.url.path)])
                : .object(["type": .string("image"), "url": .string(attachment.url.absoluteString)]))
        }
        return .array(input)
    }

    private static func messageText(_ object: [String: JSONValue]) -> String? {
        if let text = object["text"]?.stringValue { return text }
        return object["content"]?.arrayValue?
            .compactMap { content in
                let value = content.objectValue
                return value?["text"]?.stringValue ?? value?["value"]?.stringValue
            }
            .joined()
    }
}
