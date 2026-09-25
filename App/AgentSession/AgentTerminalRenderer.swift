import Foundation

/// Draws agent events as terminal text.
///
/// The terminal is a consumer of the event stream like any other: it gets the
/// same events a chat surface or the control plane would, and decides for
/// itself how they look. Its only state is what keeps a streamed reply or a
/// streamed command output from being printed a second time when the item's
/// final form arrives.
struct AgentTerminalRenderer {
    private var streamedMessages: Set<String> = []
    private var streamedOutputs: Set<String> = []
    private var startedItems: Set<String> = []

    /// Terminal bytes for the event, or nil when it draws nothing.
    mutating func render(_ event: AgentEvent) -> String? {
        switch event {
        case .historyLoaded(let items):
            let text = items.compactMap { Self.text(for: $0, includeAgentMessage: true) }.joined()
            return text.isEmpty ? nil : text
        case .turnStarted:
            // An interrupted or failed turn never completes its items, so the
            // bookkeeping is reset at turn boundaries rather than trusted to drain.
            resetTurn()
            return nil
        case .turnCompleted(_, let outcome):
            resetTurn()
            if case .failed = outcome {
                return "\r\n\u{001B}[31mTurn failed.\u{001B}[0m\r\n"
            }
            return nil
        case .itemStarted(let item):
            startedItems.insert(item.id)
            return Self.text(for: item, includeAgentMessage: false)
        case .itemDelta(let itemID, let channel, let text):
            switch channel {
            case .text: streamedMessages.insert(itemID)
            case .output: streamedOutputs.insert(itemID)
            }
            return text
        case .itemCompleted(let item):
            return completed(item)
        case .notice(let notice):
            return Self.text(for: notice)
        case .sessionBound, .runState, .approvalRequested, .approvalResolved, .account:
            return nil
        }
    }

    private mutating func completed(_ item: AgentItem) -> String? {
        let streamed = streamedMessages.remove(item.id) != nil
        if startedItems.remove(item.id) != nil {
            var output = ""
            if case .command(_, let aggregated, _) = item.kind,
               streamedOutputs.remove(item.id) == nil,
               !aggregated.isEmpty {
                output = aggregated.hasSuffix("\n") ? aggregated : aggregated + "\r\n"
            }
            // What was announced at start is already on screen. Only a reply
            // and a file change have more to say once they finish.
            switch item.kind {
            case .agentMessage, .fileChange:
                break
            default:
                return output.isEmpty ? nil : output
            }
        }
        if case .agentMessage = item.kind, streamed {
            return "\r\n"
        }
        return Self.text(for: item, includeAgentMessage: true)
    }

    private mutating func resetTurn() {
        streamedMessages.removeAll()
        streamedOutputs.removeAll()
        startedItems.removeAll()
    }

    static func text(for item: AgentItem, includeAgentMessage: Bool) -> String? {
        switch item.kind {
        case .userMessage(let text, let attachments):
            let names = attachments.map { "[\($0.kind.rawValue): \($0.displayName)]" }
            let line = ([text] + names).filter { !$0.isEmpty }.joined(separator: " ")
            guard !line.isEmpty else { return nil }
            return "\r\n\u{001B}[1;36m›\u{001B}[0m \(line)\r\n"
        case .agentMessage(let text):
            guard includeAgentMessage, !text.isEmpty else { return nil }
            return "\(text)\r\n"
        case .reasoning(let summary):
            guard !summary.isEmpty else { return nil }
            return "\r\n\u{001B}[2m\(summary)\u{001B}[0m\r\n"
        case .command(let command, _, _):
            guard !command.isEmpty else { return nil }
            return "\r\n\u{001B}[1;33m$ \(command)\u{001B}[0m\r\n"
        case .fileChange(let paths):
            guard !paths.isEmpty else { return "\r\n\u{001B}[1;35mFile change\u{001B}[0m\r\n" }
            return "\r\n\u{001B}[1;35mFile change:\u{001B}[0m \(paths.joined(separator: ", "))\r\n"
        case .toolCall(let call):
            let prefix = switch call.origin {
            case .mcp(let server): server
            case .agent: "Tool"
            case .delegation: "Agent"
            }
            return "\r\n\u{001B}[1;34m\(prefix) › \(call.name)\u{001B}[0m\r\n"
        case .other:
            return nil
        }
    }

    static func text(for notice: AgentNotice) -> String {
        switch notice.level {
        case .info: "\u{001B}[2m\(notice.message)\u{001B}[0m\r\n"
        case .warning: "\r\n\u{001B}[33m\(notice.message)\u{001B}[0m\r\n"
        case .error: "\r\n\u{001B}[31m\(notice.message)\u{001B}[0m\r\n"
        }
    }
}
