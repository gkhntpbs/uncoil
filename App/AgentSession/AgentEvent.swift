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
enum AgentEvent: Equatable {
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
struct AgentItem: Equatable, Identifiable {
    enum Status: String, Equatable {
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
}

enum AgentItemKind: Equatable {
    case userMessage(text: String, attachments: [AgentAttachment])
    case agentMessage(text: String)
    case reasoning(summary: String)
    case command(command: String, output: String, exitCode: Int?)
    case fileChange(paths: [String])
    case toolCall(AgentToolCall)
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
        case .other(let type): type
        }
    }
}

struct AgentToolCall: Equatable {
    enum Origin: Equatable {
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

enum AgentDeltaChannel: String, Equatable {
    /// The item's prose: a reply, a reasoning summary.
    case text
    /// A command's output.
    case output
}

enum AgentTurnOutcome: Equatable {
    case completed
    case interrupted
    case failed(String?)
}

enum AgentRunState: String, Equatable {
    case idle
    case active
    case systemError
}

struct AgentApproval: Equatable, Identifiable {
    enum Kind: String, Equatable {
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

enum AgentAccountState: Equatable {
    case authenticated(String?)
    case loginRequired
    case unavailable(String)
}

struct AgentNotice: Equatable {
    enum Level: String, Equatable {
        case info
        case warning
        case error
    }

    var level: Level
    var message: String
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
struct AgentAttachment: Equatable {
    enum Kind: String, Equatable {
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
