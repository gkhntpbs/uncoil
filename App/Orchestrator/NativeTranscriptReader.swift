import Foundation

/// Reads what an agent CLI writes about itself as it works.
///
/// Claude Code and Codex both keep a transcript on disk while they run in
/// their own terminal — one JSON object per line, appended as the
/// conversation happens. Reading it is how Uncoil sees what an agent said and
/// did without standing between the user and the CLI: the terminal stays the
/// agent's own, and the transcript is the account it gives of itself.
///
/// A reader is fed complete lines in order and answers with `AgentEvent`s,
/// the same events a structured session publishes. It may keep state between
/// lines — a Claude tool call is finished by a later line — so one reader
/// reads one file.
protocol NativeTranscriptReader {
    mutating func events(forLine line: Substring) -> [AgentEvent]
}

enum NativeTranscriptReaders {
    /// A reader for the provider's transcript format, or nil when Uncoil does
    /// not know where or how the provider keeps one.
    static func reader(for provider: AgentProvider) -> (any NativeTranscriptReader)? {
        switch provider {
        case .claude: ClaudeTranscriptReader()
        case .codex: CodexRolloutReader()
        default: nil
        }
    }

    static func decode(_ line: Substring) -> [String: JSONValue]? {
        guard !line.isEmpty,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
        return value.objectValue
    }
}

/// Claude Code's `projects/<slug>/<session>.jsonl`. It holds the same `user`
/// and `assistant` messages its stream-json output does, so the stream's own
/// normalizer reads it — plus the user's prompts, which only the transcript
/// records.
struct ClaudeTranscriptReader: NativeTranscriptReader {
    private var normalizer = ClaudeEventNormalizer()
    /// A `!command` typed into the terminal, until its output line arrives.
    private var shellCommand: (id: String, command: String)?
    /// The last slash command sent, so its output can say whose it is.
    private var slashCommand: String?

    mutating func events(forLine line: Substring) -> [AgentEvent] {
        guard let object = NativeTranscriptReaders.decode(line) else { return [] }
        // A subagent's side conversation, and lines Claude writes for itself.
        if object["isSidechain"]?.boolValue == true || object["isMeta"]?.boolValue == true { return [] }
        if object["type"]?.stringValue == "user", let prompt = ClaudeEventNormalizer.promptText(object) {
            let id = object["uuid"]?.stringValue ?? UUID().uuidString
            return userLine(ClaudeTranscriptText.read(prompt), id: id)
        }
        return normalizer.events(for: .object(object)).filter {
            switch $0 {
            case .itemStarted, .itemCompleted, .notice, .turnCompleted: true
            default: false
            }
        }
    }

    /// What a line on the user's side of the transcript was. Claude files its
    /// own slash commands, their output, `!` shell commands and background
    /// task reports there too, each wrapped in its own tags.
    private mutating func userLine(_ line: ClaudeTranscriptText.Line, id: String) -> [AgentEvent] {
        switch line {
        case .prompt(let text):
            slashCommand = text.hasPrefix("/") ? text : nil
            return [
                .turnStarted(turnID: id),
                .itemCompleted(AgentItem(id: id, kind: .userMessage(text: text, attachments: []), status: .completed, native: nil)),
            ]
        case .commandOutput(let text):
            return text.isEmpty ? [] : [.itemCompleted(AgentItem(
                id: id, kind: .command(command: slashCommand ?? "", output: text, exitCode: nil),
                status: .completed, native: nil))]
        case .shellInput(let command):
            shellCommand = (id, command)
            return [.itemStarted(AgentItem(
                id: id, kind: .command(command: command, output: "", exitCode: nil), status: .inProgress, native: nil))]
        case .shellOutput(let output, let failed):
            let started = shellCommand
            shellCommand = nil
            return [.itemCompleted(AgentItem(
                id: started?.id ?? id,
                kind: .command(command: started?.command ?? "", output: output, exitCode: nil),
                status: failed ? .failed : .completed, native: nil))]
        case .notice(let text):
            return [.notice(AgentNotice(level: .info, message: text))]
        case .ignored:
            return []
        }
    }
}

/// Claude Code's tagged user lines, read into what they mean.
enum ClaudeTranscriptText {
    enum Line: Equatable {
        /// Something the user sent — typed, pasted, or a slash command.
        case prompt(String)
        /// What a slash command printed.
        case commandOutput(String)
        /// A `!command` run in the terminal, and what it printed.
        case shellInput(String)
        case shellOutput(String, failed: Bool)
        /// A background task finishing.
        case notice(String)
        case ignored
    }

    static func read(_ raw: String) -> Line {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<local-command-caveat>") { return .ignored }
        if let name = inner("command-name", text) {
            let args = inner("command-args", text) ?? ""
            return .prompt(args.isEmpty ? name : "\(name) \(args)")
        }
        if let output = inner("local-command-stdout", text) ?? inner("local-command-stderr", text) {
            return .commandOutput(stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let command = inner("bash-input", text) {
            return .shellInput(command.trimmingCharacters(in: .whitespaces))
        }
        if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") {
            let out = inner("bash-stdout", text) ?? ""
            let err = inner("bash-stderr", text) ?? ""
            let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            return .shellOutput(stripANSI(combined), failed: !err.isEmpty && out.isEmpty)
        }
        if text.hasPrefix("<task-notification>") {
            let summary = inner("summary", text) ?? inner("status", text) ?? "A background task finished."
            return .notice(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let cleaned = clean(text)
        return cleaned.isEmpty ? .ignored : .prompt(cleaned)
    }

    /// A prompt without the wrappers Claude adds: the paste marker around
    /// pasted text, and system reminders appended to it.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "</?pasted_content[^>]*>", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text between `<tag>` and `</tag>`, if the tag is there.
    static func inner(_ tag: String, _ text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

/// Codex's `sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl`. Its
/// `item_completed` events carry the same items the app server sends, spelled
/// in the rollout's own case — `CommandExecution`, `exit_code` — and its task
/// events bound each turn.
struct CodexRolloutReader: NativeTranscriptReader {
    mutating func events(forLine line: Substring) -> [AgentEvent] {
        guard let object = NativeTranscriptReaders.decode(line),
              object["type"]?.stringValue == "event_msg",
              let payload = object["payload"]?.objectValue else { return [] }
        switch payload["type"]?.stringValue {
        case "task_started":
            return [.turnStarted(turnID: payload["turn_id"]?.stringValue)]
        case "task_complete":
            return [.turnCompleted(turnID: payload["turn_id"]?.stringValue, outcome: .completed)]
        case "turn_aborted":
            let reason = payload["reason"]?.stringValue
            return [.turnCompleted(
                turnID: payload["turn_id"]?.stringValue,
                outcome: reason == nil || reason == "interrupted" ? .interrupted : .failed(reason))]
        case "item_completed":
            guard let item = payload["item"].flatMap(Self.item) else { return [] }
            return [.itemCompleted(item)]
        default:
            return []
        }
    }

    static func item(_ value: JSONValue) -> AgentItem? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let type = object["type"]?.stringValue else { return nil }
        let failed = object["status"]?.stringValue == "failed"
        let kind: AgentItemKind
        switch type {
        case "UserMessage":
            kind = .userMessage(text: text(object["content"]), attachments: [])
        case "AgentMessage":
            kind = .agentMessage(text: text(object["content"]))
        case "Reasoning":
            let summary = (object["summary_text"]?.arrayValue ?? []).compactMap(\.stringValue)
            kind = .reasoning(summary: summary.joined(separator: "\n\n"))
        case "CommandExecution":
            kind = .command(
                command: command(object["command"]),
                output: object["aggregated_output"]?.stringValue ?? object["stdout"]?.stringValue ?? "",
                exitCode: object["exit_code"]?.intValue)
        case "FileChange":
            kind = .fileChange(fileChanges(object["changes"]))
        case "McpToolCall":
            kind = .toolCall(AgentToolCall(
                origin: .mcp(server: object["server"]?.stringValue ?? "MCP"),
                name: object["tool"]?.stringValue ?? "tool"))
        case "CollabAgentToolCall":
            kind = .toolCall(AgentToolCall(origin: .delegation, name: object["tool"]?.stringValue ?? "agent"))
        default:
            kind = .other(type: type)
        }
        return AgentItem(id: id, kind: kind, status: failed ? .failed : .completed, native: value)
    }

    private static func text(_ content: JSONValue?) -> String {
        if let string = content?.stringValue { return string }
        return (content?.arrayValue ?? [])
            .compactMap { $0.objectValue?["text"]?.stringValue }
            .joined()
    }

    /// `["/bin/zsh", "-lc", "git status"]` is the command `git status`.
    private static func command(_ value: JSONValue?) -> String {
        if let string = value?.stringValue { return string }
        let parts = (value?.arrayValue ?? []).compactMap(\.stringValue)
        if parts.count == 3, parts[1] == "-lc" || parts[1] == "-c" { return parts[2] }
        return parts.joined(separator: " ")
    }

    /// `{ "<path>": { "type": "update", "unified_diff": "…" } }`.
    private static func fileChanges(_ value: JSONValue?) -> [AgentFileChange] {
        (value?.objectValue ?? [:]).keys.sorted().compactMap { path in
            let change = value?.objectValue?[path]?.objectValue ?? [:]
            let diff = change["unified_diff"]?.stringValue ?? change["diff"]?.stringValue
            return AgentFileChange(
                path: path,
                kind: change["type"]?.stringValue.flatMap(AgentFileChange.Kind.init(rawValue:)) ?? .update,
                diff: diff?.isEmpty == false ? diff : nil)
        }
    }
}
