import Foundation

/// One row of a chat transcript.
///
/// The transcript is the timeline read in order and nothing more: an item is
/// named by its id and drawn from the timeline's own `AgentItem`, a marker is
/// the timeline's own marker. What the chat adds is only what the timeline
/// states rather than lists — the approvals still waiting, and that the agent
/// is working.
enum AgentChatRow: Equatable, Identifiable {
    case item(String)
    case marker(AgentTimelineMarker)
    /// An approval still waiting for an answer.
    case approval(AgentApproval)
    /// A turn is running and nothing else on screen says so.
    case working
    /// Who is speaking from here on, in a conversation with several agents.
    case speaker(AgentItemSource, beforeItem: String)

    var id: String {
        switch self {
        case .item(let id): "item:\(id)"
        case .marker(let marker): "marker:\(marker.id)"
        case .approval(let approval): "approval:\(approval.id)"
        case .working: "working"
        case .speaker(_, let item): "speaker:\(item)"
        }
    }
}

/// Pure transformations from the timeline to what the chat draws.
enum AgentChatTranscript {
    static func rows(for timeline: AgentTimeline) -> [AgentChatRow] {
        let shown = timeline.items.filter(isVisible)
        let shownIDs = Set(shown.map(\.id))
        let known = Set(timeline.items.map(\.id))
        var markersAfter: [String: [AgentTimelineMarker]] = [:]
        var rows: [AgentChatRow] = []
        for marker in timeline.markers where isVisible(marker) {
            if let after = marker.afterItemID, known.contains(after) {
                markersAfter[after, default: []].append(marker)
            } else {
                // Before the first item, or after one the timeline has since
                // dropped: either way, earlier than everything still here.
                rows.append(.marker(marker))
            }
        }
        var speaker: AgentItemSource?
        for item in timeline.items {
            if shownIDs.contains(item.id) {
                // A header each time the voice changes: the user speaking
                // resets it, so the agent answering is named again.
                if let source = item.source, source != speaker {
                    rows.append(.speaker(source, beforeItem: item.id))
                }
                if item.source != nil || !(isUserMessage(item)) {
                    speaker = item.source ?? speaker
                } else {
                    speaker = nil
                }
                rows.append(.item(item.id))
            }
            for marker in markersAfter[item.id] ?? [] {
                rows.append(.marker(marker))
            }
        }
        rows += timeline.pendingApprovals.map(AgentChatRow.approval)
        if timeline.turnInProgress, timeline.pendingApprovals.isEmpty,
           !(shown.last.map(showsOwnActivity) ?? false) {
            rows.append(.working)
        }
        return rows
    }

    private static func isUserMessage(_ item: AgentItem) -> Bool {
        if case .userMessage = item.kind { return true }
        return false
    }

    /// An item with nothing to show yet is left out until it has: a reply
    /// announced before its first word, a thought with no summary.
    static func isVisible(_ item: AgentItem) -> Bool {
        switch item.kind {
        case .agentMessage(let text):
            return !text.isEmpty
        case .reasoning(let summary):
            return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .userMessage(let text, let attachments):
            return !text.isEmpty || !attachments.isEmpty
        case .plan(let plan):
            return !plan.steps.isEmpty || !(plan.text ?? "").isEmpty
        default:
            return true
        }
    }

    /// A turn that completed is the ordinary case and says nothing; one that
    /// was stopped or failed is worth a line where it stopped.
    static func isVisible(_ marker: AgentTimelineMarker) -> Bool {
        if case .turnEnded(.completed) = marker.kind { return false }
        return true
    }

    /// Whether the row already shows that work is happening, so a separate
    /// "working" line would only repeat it.
    private static func showsOwnActivity(_ item: AgentItem) -> Bool {
        guard item.status == .inProgress else { return false }
        switch item.kind {
        case .userMessage, .plan: return false
        default: return true
        }
    }

    // MARK: - Commands

    /// A command as worth reading. Agents prefix a command with a `cd` into
    /// the directory it already runs in; the prefix is the long part and says
    /// nothing, so it goes — the full line is still the row's tooltip.
    static func displayCommand(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*"#
        while let range = text.range(of: pattern, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    // MARK: - Output

    /// The end of a long output, and how many lines were left out before it.
    /// Output is read from the bottom: that is where a command says how it went.
    static func tail(_ text: String, lines limit: Int) -> (text: String, hidden: Int) {
        var body = text
        while body.hasSuffix("\n") { body.removeLast() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return (body, 0) }
        return (lines.suffix(limit).joined(separator: "\n"), lines.count - limit)
    }

    /// A one-line label for a reasoning summary folded away: its first line,
    /// without the markdown emphasis agents like to open with.
    static func headline(_ text: String) -> String {
        let first = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return MarkdownInline.plain(String(first ?? "").trimmingCharacters(in: .whitespaces))
    }

    /// A provider's payload, readable. Keys sorted so the same payload always
    /// reads the same, and cut at `limit` characters.
    static func details(_ value: JSONValue?, limit: Int = 6_000) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              var text = String(data: data, encoding: .utf8) else { return nil }
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n…"
        }
        return text
    }
}
