import Foundation

/// What one Uncoil Auto conversation knows beyond its transcript, shared by
/// the session and the views drawing it: which agents this conversation has
/// been narrowed away from, the efforts the user applied from it, and the
/// suggestions standing for the prompt being written.
@MainActor
final class UncoilAutoConversationState: ObservableObject {
    private static var states: [UUID: UncoilAutoConversationState] = [:]

    static func `for`(_ sessionID: UUID) -> UncoilAutoConversationState {
        if let state = states[sessionID] { return state }
        let state = UncoilAutoConversationState(sessionID: sessionID)
        states[sessionID] = state
        return state
    }

    /// The conversations directing an agent session right now.
    static func conversations(directing agentSessionID: UUID) -> Set<UUID> {
        Set(states.values.filter { $0.participants.contains(agentSessionID) }.map(\.sessionID))
    }

    let sessionID: UUID

    /// The agent sessions this conversation is directing: the ones it has
    /// spoken to and listens to. Empty once the conversation stops.
    @Published var participants: Set<UUID> = []
    /// Where a prompt that names nobody goes, by handle, until the user picks
    /// another. nil ⇒ not chosen yet; `UncoilAutoRouting` picks one.
    @Published var target: String? {
        didSet { if target != oldValue { onChange?() } }
    }

    /// Agents this conversation may not address, by provider raw value, on
    /// top of what Settings already allows. A conversation can narrow the
    /// app-wide list; it cannot widen it.
    @Published var excludedAgents: Set<String> = [] {
        didSet { if excludedAgents != oldValue { onChange?() } }
    }
    /// Efforts applied from this conversation, by agent session: the one
    /// place that knows a running session's effort changed after launch.
    @Published private(set) var appliedEffort: [UUID: String] = [:]
    /// Efforts to launch not-yet-started agents with, by provider raw value.
    @Published private(set) var launchEffort: [String: String] = [:]
    /// The suggestions on screen. Republished only when they would look
    /// different, so a reading that changes nothing visible redraws nothing.
    @Published private(set) var suggestions: [EffortSuggestionItem] = []
    /// The latest reading, whether or not it changed what is shown: what a
    /// sent prompt is logged with.
    private(set) var standing: [EffortSuggestionItem] = []

    /// Set by the session: persists the conversation.
    var onChange: (() -> Void)?
    /// Set by the session: sends one of the agent's own commands without
    /// letting it name the session or echo back into the conversation.
    var sendCommand: ((String, AgentItemSource) async -> Void)?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    /// What a relaunch reads back from the conversation's file.
    func restore(excluded: Set<String>, applied: [UUID: String], target: String? = nil) {
        let callback = onChange
        onChange = nil
        excludedAgents = excluded
        appliedEffort = applied
        self.target = target
        onChange = callback
    }

    func allows(_ provider: AgentProvider, settings: UncoilAutoSettings) -> Bool {
        settings.allows(provider) && !excludedAgents.contains(provider.rawValue)
    }

    func setExcluded(_ provider: AgentProvider, _ excluded: Bool) {
        if excluded { excludedAgents.insert(provider.rawValue) } else { excludedAgents.remove(provider.rawValue) }
    }

    func publish(_ items: [EffortSuggestionItem]) {
        standing = items
        guard !EffortSuggestionItem.looksSame(items, suggestions) else { return }
        suggestions = items
    }

    /// Takes the chips off screen. The standing reading stays until a send
    /// takes it: clearing the field on send must not lose what gets logged.
    func hide() {
        if !suggestions.isEmpty { suggestions = [] }
    }

    /// The reading a prompt going out now was written under, used once.
    func takeStanding() -> [EffortSuggestionItem] {
        defer { standing = [] }
        return standing
    }

    /// The effort a session runs at now, as far as Uncoil knows it.
    func currentEffort(for entry: UncoilAutoRoster.Entry, record: SessionRecord?) -> String? {
        if let id = entry.sessionID {
            return appliedEffort[id] ?? record?.launchSelection?.effort
        }
        return launchEffort[entry.provider.rawValue]
    }

    /// Applies a suggestion the only way its target can take it.
    func apply(_ item: EffortSuggestionItem) async {
        switch item.application {
        case .command:
            guard let source = item.entry.source, let sendCommand else { return }
            await sendCommand("/effort \(item.suggestion.level)", source)
            appliedEffort[source.sessionID] = item.suggestion.level
        case .atLaunch:
            launchEffort[item.entry.provider.rawValue] = item.suggestion.level
        case .unavailable:
            return
        }
        func applied(_ items: [EffortSuggestionItem]) -> [EffortSuggestionItem] {
            items.map { shown in
                guard shown.id == item.id else { return shown }
                var applied = shown
                applied.suggestion.current = item.suggestion.level
                return applied
            }
        }
        suggestions = applied(suggestions)
        standing = applied(standing)
    }

    /// Taken once, by the session that starts the agent with it.
    func takeLaunchEffort(for provider: AgentProvider) -> String? {
        launchEffort.removeValue(forKey: provider.rawValue)
    }
}

/// One suggestion as the composer shows it: for whom, what, and how Apply
/// would reach the agent.
struct EffortSuggestionItem: Identifiable, Equatable {
    enum Application: Equatable {
        /// `/effort <level>` into the running session (Claude's terminal).
        case command
        /// Written into the launch of a session not started yet.
        case atLaunch
        /// Nothing Uncoil can do mid-session; the reason says what would.
        case unavailable(String)
    }

    var entry: UncoilAutoRoster.Entry
    var suggestion: EffortSuggestion
    var application: Application

    var id: String { entry.handle }

    /// Whether two readings would draw the same chips: same agents, levels,
    /// current efforts and ways to apply, and confidence within 5%. A reading
    /// that differs only below that is not worth a redraw while typing.
    static func looksSame(_ lhs: [EffortSuggestionItem], _ rhs: [EffortSuggestionItem]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.entry == b.entry
                && a.suggestion.level == b.suggestion.level
                && a.suggestion.current == b.suggestion.current
                && a.application == b.application
                && Int(a.suggestion.confidence * 20) == Int(b.suggestion.confidence * 20)
        }
    }

    /// How a suggestion for this agent can be applied.
    static func application(
        for entry: UncoilAutoRoster.Entry, isStructured: Bool
    ) -> Application {
        guard entry.sessionID != nil else { return .atLaunch }
        switch entry.provider {
        case .claude where !isStructured:
            return .command
        case .claude:
            return .unavailable(String(localized: "A structured Claude session takes its effort at launch."))
        default:
            return .unavailable(String(localized: "\(entry.provider.displayName) takes its effort at launch; it applies to new sessions."))
        }
    }
}

// MARK: - Decision log

/// Every suggestion made for a prompt that was sent, and what came of it:
/// the data a fine-tuned model will learn from. One JSON object per line, on
/// this Mac only.
struct EffortDecisionLog {
    struct Decision: Codable, Equatable {
        var kind = "decision"
        var id: String
        var date: Date
        var provider: String
        var prompt: String
        var state: String
        var features: EffortFeatures
        var suggested: String
        var confidence: Double
        var current: String?
        /// Whether the session ran at the suggested effort when the prompt went.
        var followed: Bool
    }

    struct Outcome: Codable, Equatable {
        var kind = "outcome"
        var id: String
        var date: Date
        var seconds: Double
        var result: String
    }

    let url: URL

    static var defaultURL: URL {
        LayaSidecar.defaultRoot.appendingPathComponent("decisions.jsonl")
    }

    func append(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(value) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    var count: Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.contains("\"kind\":\"decision\"") }.count
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
