import Foundation

/// What an agent session said, in Uncoil's own terms.
///
/// A provider speaks its own protocol — Codex app-server notifications, Claude
/// Code hooks, whatever Gemini or OpenCode offer next. Each integration
/// translates that into `AgentEvent`s once, at the edge, and every consumer —
/// the terminal, a chat surface, the control plane, usage, orchestration —
/// reads the same events. The terminal is one consumer among several, not the
/// place the information ends up.
///
/// Nothing provider-specific is thrown away to get here: every item and
/// approval keeps the provider's own payload in `native`, so a consumer that
/// knows the provider can still reach what the common model does not describe.
enum AgentEvent: Equatable, Codable {
    /// The provider named the conversation this session is attached to — the
    /// id that resumes it, in Uncoil or in the provider's own interface.
    case sessionBound(providerSessionID: String)
    /// Earlier turns of a resumed conversation, oldest first.
    case historyLoaded([AgentItem])
    case turnStarted(turnID: String?)
    case turnCompleted(turnID: String?, outcome: AgentTurnOutcome)
    case itemStarted(AgentItem)
    /// Streaming text for an item already started.
    case itemDelta(itemID: String, channel: AgentDeltaChannel, text: String)
    /// The item's final form. Replaces whatever the deltas built up.
    case itemCompleted(AgentItem)
    case runState(AgentRunState)
    case approvalRequested(AgentApproval)
    case approvalResolved(approvalID: String, decision: String)
    case account(AgentAccountState)
    /// A line Uncoil itself has to say about the session: ready, an error, a
    /// fallback. Not the agent's words.
    case notice(AgentNotice)
}

/// One unit of a conversation: a message, a command, a file change, a tool call.
struct AgentItem: Equatable, Identifiable, Codable {
    enum Status: String, Equatable, Codable {
        case inProgress
        case completed
        case failed
        case declined
    }

    let id: String
    var kind: AgentItemKind
    var status: Status
    /// The provider's own description of the item, untouched.
    var native: JSONValue?
    /// Who said it, in a conversation with more than one agent in it. Nil is
    /// the session's own agent — or, for a user message, the user.
    var source: AgentItemSource? = nil
    /// Whom a user message was sent to, when it went to other sessions.
    var recipients: [AgentItemSource]? = nil
}

/// An agent session, named the way a conversation refers to it.
struct AgentItemSource: Equatable, Hashable, Codable {
    var sessionID: UUID
    var provider: AgentProvider
    /// The handle the conversation uses for it: `claude`, `codex-2`.
    var handle: String
}

enum AgentItemKind: Equatable, Codable {
    case userMessage(text: String, attachments: [AgentAttachment])
    case agentMessage(text: String)
    case reasoning(summary: String)
    case command(command: String, output: String, exitCode: Int?)
    case fileChange([AgentFileChange])
    case toolCall(AgentToolCall)
    /// What the agent intends to do, step by step. Replaced whole on each
    /// update rather than appended to: a plan is a state, not a log.
    case plan(AgentPlan)
    /// A kind the common model has no name for yet. `native` carries it whole.
    case other(type: String)

    /// Short machine name, stable across providers.
    var name: String {
        switch self {
        case .userMessage: "user_message"
        case .agentMessage: "agent_message"
        case .reasoning: "reasoning"
        case .command: "command"
        case .fileChange: "file_change"
        case .toolCall: "tool_call"
        case .plan: "plan"
        case .other(let type): type
        }
    }
}

/// One file an agent changed, and how, when the provider said.
struct AgentFileChange: Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case add
        case delete
        case update
    }

    var path: String
    var kind: Kind
    /// A unified diff of the change — hunks, no file headers needed. Nil when
    /// the provider named the file and nothing more.
    var diff: String?

    init(path: String, kind: Kind = .update, diff: String? = nil) {
        self.path = path
        self.kind = kind
        self.diff = diff
    }
}

extension AgentFileChange {
    /// A diff for a provider that reports an edit as "this text became that
    /// text" rather than as a patch. Lines both sides share at the ends are
    /// kept as context, three at most, so the change reads as a change and not
    /// as the whole block removed and written again.
    static func replacementDiff(old: String, new: String) -> String {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        var lines: [String] = []
        lines += before[max(0, prefix - 3)..<prefix].map { " " + $0 }
        lines += before[prefix..<(before.count - suffix)].map { "-" + $0 }
        lines += after[prefix..<(after.count - suffix)].map { "+" + $0 }
        lines += before[(before.count - suffix)..<min(before.count, before.count - suffix + 3)].map { " " + $0 }
        return lines.joined(separator: "\n")
    }
}

extension AgentItemKind {
    /// A file change that only names its files.
    static func fileChange(paths: [String]) -> AgentItemKind {
        .fileChange(paths.map { AgentFileChange(path: $0) })
    }
}

struct AgentPlan: Equatable, Codable {
    struct Step: Equatable, Codable {
        enum Status: String, Equatable, Codable {
            case pending
            case inProgress
            case completed
        }

        var text: String
        var status: Status
    }

    /// Prose around the steps, or a plan that is only prose.
    var text: String?
    var steps: [Step]

    init(text: String? = nil, steps: [Step] = []) {
        self.text = text
        self.steps = steps
    }
}

struct AgentToolCall: Equatable, Codable {
    enum Origin: Equatable, Codable {
        /// An MCP server's tool, named by the server.
        case mcp(server: String)
        /// A tool built into the agent.
        case agent
        /// A tool that hands work to another agent.
        case delegation
    }

    var origin: Origin
    var name: String
}

enum AgentDeltaChannel: String, Equatable, Codable {
    /// The item's prose: a reply, a reasoning summary.
    case text
    /// A command's output.
    case output
}

enum AgentTurnOutcome: Equatable, Codable {
    case completed
    case interrupted
    case failed(String?)
}

enum AgentRunState: String, Equatable, Codable {
    case idle
    case active
    case systemError
}

struct AgentApproval: Equatable, Identifiable, Codable {
    enum Kind: String, Equatable, Codable {
        case command
        case fileChange
        case permissions
    }

    let id: String
    var kind: Kind
    var title: String
    var detail: String?
    var decisions: [String]
    var native: JSONValue?
}

enum AgentAccountState: Equatable, Codable {
    case authenticated(String?)
    case loginRequired
    case unavailable(String)
}

struct AgentNotice: Equatable, Codable {
    enum Level: String, Equatable, Codable {
        case info
        case warning
        case error
    }

    var level: Level
    var message: String
    /// Something the user can do about it, offered beside the notice.
    var action: AgentNoticeAction? = nil
}

/// What a notice offers to do.
enum AgentNoticeAction: Equatable, Codable {
    /// The answer is in the agent's own terminal — a picker, a prompt, a
    /// screen the conversation cannot show — so open it.
    case openTerminal(sessionID: UUID, handle: String)
}

/// An event as it was published: which session, which provider, in what order.
struct AgentEventRecord: Equatable {
    /// Monotonic per session, so a consumer that attaches late can ask for
    /// "everything after N" instead of guessing.
    let sequence: Int
    let sessionID: UUID
    let provider: AgentProvider
    let date: Date
    let event: AgentEvent
}

/// A file handed to an agent alongside a prompt.
///
/// The file is already on disk, inside the session's working directory, where
/// any agent may read it. How it reaches the agent is the session's business:
/// a structured session sends an image as an image, a terminal types its path.
struct AgentAttachment: Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case image
        case file
    }

    var kind: Kind
    /// Where the file is. A remote image may be an `https` URL.
    var url: URL
    /// How a prompt refers to it: relative to the working directory, so no
    /// agent has to ask before reading it.
    var promptPath: String

    var displayName: String { url.lastPathComponent }
}
