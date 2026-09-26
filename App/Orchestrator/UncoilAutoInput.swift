import Foundation

/// The agents Uncoil Auto can talk to in a project, by the handle a prompt
/// uses for them.
///
/// Every agent session in the project gets one — `@claude`, and `@claude-2`
/// for the next Claude, in the order the sessions were made, so a handle does
/// not move to another session when a newer one appears. An installed agent
/// with no session yet is offered under its bare name; mentioning it starts one.
enum UncoilAutoRoster {
    struct Entry: Equatable, Identifiable {
        var handle: String
        var provider: AgentProvider
        /// Nil for an agent that has no session in the project yet.
        var sessionID: UUID?
        var title: String

        var id: String { handle }

        var source: AgentItemSource? {
            sessionID.map { AgentItemSource(sessionID: $0, provider: provider, handle: handle) }
        }
    }

    static func entries(sessions: [SessionRecord], installed: Set<AgentProvider>) -> [Entry] {
        var counts: [AgentProvider: Int] = [:]
        var entries: [Entry] = []
        for record in sessions.filter({ $0.provider.isAgent }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let count = counts[record.provider, default: 0] + 1
            counts[record.provider] = count
            entries.append(Entry(
                handle: count == 1 ? record.provider.rawValue : "\(record.provider.rawValue)-\(count)",
                provider: record.provider,
                sessionID: record.id,
                title: record.displayTitle
            ))
        }
        for provider in AgentProvider.agents where installed.contains(provider) && counts[provider] == nil {
            entries.append(Entry(
                handle: provider.rawValue, provider: provider, sessionID: nil,
                title: String(localized: "New \(provider.displayName) session")))
        }
        return entries
    }
}

/// What a line typed into Uncoil Auto asks for.
enum UncoilAutoInput: Equatable {
    /// One of Uncoil Auto's own commands: `/new claude`, `/stop @codex`.
    case command(UncoilAutoCommand, argument: String, mentions: [String])
    /// A message, and whom it names. `text` is the message without the
    /// mentions; when it starts with `/` it is the agent's own command.
    case message(text: String, mentions: [String])

    static func parse(_ raw: String) -> UncoilAutoInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let (text, mentions) = extractMentions(trimmed)
        if trimmed.hasPrefix("/") {
            let body = trimmed.dropFirst()
            let name = String(body.prefix { !$0.isWhitespace })
            if let command = UncoilAutoCommand(rawValue: name.lowercased()) {
                let rest = extractMentions(String(body.dropFirst(name.count))).text
                return .command(command, argument: rest, mentions: mentions)
            }
        }
        return .message(text: text, mentions: mentions)
    }

    /// `@handle` tokens — at the start or after whitespace — in the order
    /// written, each once, and the text with them taken out.
    static func extractMentions(_ text: String) -> (text: String, mentions: [String]) {
        var mentions: [String] = []
        var kept: [Substring] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if word.hasPrefix("@"), word.count > 1,
               word.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                let handle = word.dropFirst().lowercased()
                if !mentions.contains(handle) { mentions.append(handle) }
            } else {
                kept.append(word)
            }
        }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined, mentions)
    }
}

enum UncoilAutoCommand: String, CaseIterable, Equatable {
    case new
    case stop
    case agents
    case clear
    case help

    var usage: String {
        switch self {
        case .new: "/new <agent> [prompt]"
        case .stop: "/stop [@agent]"
        case .agents: "/agents"
        case .clear: "/clear"
        case .help: "/help"
        }
    }

    var summary: String {
        switch self {
        case .new: String(localized: "Start a new agent session in this project")
        case .stop: String(localized: "Stop what the agents are doing")
        case .agents: String(localized: "List the agents in this project")
        case .clear: String(localized: "Clear this conversation")
        case .help: String(localized: "Show what Uncoil Auto understands")
        }
    }
}

/// An agent's own slash commands, offered after `@agent /`. Typed into the
/// agent's terminal as they are, so only commands that make sense sent as one
/// line are listed.
enum NativeAgentCommands {
    /// Whether the command answers in the agent's own terminal rather than in
    /// its transcript — a picker waiting for a choice, a screen of status.
    /// The conversation cannot show either, so it offers the terminal instead.
    static func answersInTerminal(_ line: String, provider: AgentProvider) -> Bool {
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        guard let name = parts.first.map(String.init) else { return false }
        let hasArguments = parts.count > 1
        switch provider {
        case .claude:
            // With an argument these just act; bare, they open a picker.
            if ["model", "effort", "output-style"].contains(name) { return !hasArguments }
            return ["config", "permissions", "agents", "mcp", "resume", "memory", "hooks",
                    "login", "logout", "add-dir", "export", "status", "doctor", "ide"].contains(name)
        case .codex:
            // Codex keeps no record of a command's answer; it is on screen only.
            return !["compact", "init"].contains(name)
        default:
            return true
        }
    }

    static func commands(for provider: AgentProvider) -> [(name: String, summary: String)] {
        switch provider {
        case .claude:
            [
                ("compact", "Summarise the conversation to free context"),
                ("clear", "Start the conversation over"),
                ("context", "Show what is using the context window"),
                ("cost", "Show this session's token use"),
                ("model", "Change the model"),
                ("review", "Review a pull request"),
                ("init", "Write a CLAUDE.md for the project"),
                ("memory", "Edit memory files"),
                ("status", "Show account and session status"),
            ]
        case .codex:
            [
                ("compact", "Summarise the conversation to free context"),
                ("new", "Start a new conversation"),
                ("diff", "Show the working tree diff"),
                ("review", "Review the current changes"),
                ("model", "Change the model"),
                ("status", "Show session configuration and usage"),
                ("init", "Write an AGENTS.md for the project"),
            ]
        default:
            []
        }
    }
}

/// What the word under the cursor is asking to be completed to.
struct ComposerToken: Equatable {
    enum Kind: Equatable {
        /// `@…`: an agent.
        case mention
        /// `/…` at the start: an Uncoil Auto command.
        case command
        /// `/…` after `@agent`: that agent's own command.
        case agentCommand(handle: String)
    }

    var kind: Kind
    /// What has been typed after the `@` or `/`.
    var query: String
    /// The word, in UTF-16 offsets, as `NSTextView` counts them.
    var range: NSRange

    static func at(_ text: String, cursor: Int) -> ComposerToken? {
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return nil }
        var start = cursor
        while start > 0, !isSpace(utf16[start - 1]) { start -= 1 }
        guard start < cursor else { return nil }
        let word = String(decoding: utf16[start..<cursor], as: UTF16.self)
        let query = String(word.dropFirst())
        let range = NSRange(location: start, length: cursor - start)
        if word.hasPrefix("@") {
            return ComposerToken(kind: .mention, query: query.lowercased(), range: range)
        }
        guard word.hasPrefix("/") else { return nil }
        let before = String(decoding: utf16[0..<start], as: UTF16.self)
        let (rest, mentions) = UncoilAutoInput.extractMentions(before)
        guard rest.isEmpty else { return nil }
        if let handle = mentions.last {
            return ComposerToken(kind: .agentCommand(handle: handle), query: query.lowercased(), range: range)
        }
        return ComposerToken(kind: .command, query: query.lowercased(), range: range)
    }

    private static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}

/// One line of the composer's completion list.
struct ChatSuggestion: Equatable, Identifiable {
    var id: String { insertion }
    /// What replaces the word being completed.
    var insertion: String
    var title: String
    var detail: String
    /// The agent the line is about, for its mark.
    var provider: AgentProvider?
}

enum UncoilAutoCompletions {
    static func suggestions(for token: ComposerToken, roster: [UncoilAutoRoster.Entry]) -> [ChatSuggestion] {
        switch token.kind {
        case .mention:
            return roster
                .filter { token.query.isEmpty || $0.handle.hasPrefix(token.query) || $0.provider.displayName.lowercased().hasPrefix(token.query) }
                .map { ChatSuggestion(insertion: "@\($0.handle)", title: "@\($0.handle)", detail: $0.title, provider: $0.provider) }
        case .command:
            return UncoilAutoCommand.allCases
                .filter { token.query.isEmpty || $0.rawValue.hasPrefix(token.query) }
                .map { ChatSuggestion(insertion: "/\($0.rawValue)", title: $0.usage, detail: $0.summary, provider: .uncoil) }
        case .agentCommand(let handle):
            guard let provider = roster.first(where: { $0.handle == handle })?.provider else { return [] }
            return NativeAgentCommands.commands(for: provider)
                .filter { token.query.isEmpty || $0.name.hasPrefix(token.query) }
                .map { command in
                    let inTerminal = NativeAgentCommands.answersInTerminal("/\(command.name)", provider: provider)
                    return ChatSuggestion(
                        insertion: "/\(command.name)", title: "/\(command.name)",
                        detail: inTerminal ? "\(command.summary) · opens in its terminal" : command.summary,
                        provider: provider)
                }
        }
    }

    /// The text after a suggestion is taken, and where the cursor goes.
    static func apply(_ suggestion: ChatSuggestion, to token: ComposerToken, in text: String) -> (text: String, cursor: Int) {
        let ns = text as NSString
        let replacement = suggestion.insertion + " "
        let result = ns.replacingCharacters(in: token.range, with: replacement)
        return (result, token.range.location + (replacement as NSString).length)
    }
}
