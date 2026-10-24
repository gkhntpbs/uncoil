import Foundation

/// What one Uncoil Auto conversation knows beyond its transcript, shared by
/// the session and the views drawing it: which agents this conversation has
/// been narrowed away from, where a message naming nobody goes, and the Auto
/// runs it has started.
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

    /// Runs kept per conversation, newest last.
    static let runLimit = 10

    let sessionID: UUID

    /// The agent sessions this conversation is directing: the ones it has
    /// spoken to and listens to. Empty once the conversation stops.
    @Published var participants: Set<UUID> = []
    /// Where a prompt that names nobody goes, by handle, until the user picks
    /// another. nil ⇒ not chosen yet; `UncoilAutoRouting` picks one. In an
    /// Auto run this agent is Main.
    @Published var target: String? {
        didSet { if target != oldValue { onChange?() } }
    }

    /// Agents this conversation may not address, by provider raw value, on
    /// top of what Settings already allows. A conversation can narrow the
    /// app-wide list; it cannot widen it.
    @Published var excludedAgents: Set<String> = [] {
        didSet { if excludedAgents != oldValue { onChange?() } }
    }

    /// The conversation's Auto runs, newest last; the last may be running.
    @Published private(set) var runs: [AutoRun] = []
    /// Whether the last run is still going.
    @Published private(set) var isRunning = false

    /// Set by the session: persists the conversation.
    var onChange: (() -> Void)?
    /// Set by the session: stops the run in progress.
    var cancelRun: (() -> Void)?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var currentRun: AutoRun? { runs.last }

    /// What a relaunch reads back from the conversation's file.
    func restore(excluded: Set<String>, target: String? = nil, runs: [AutoRun] = []) {
        let callback = onChange
        onChange = nil
        excludedAgents = excluded
        self.target = target
        // A run that was going when Uncoil quit did not finish; its
        // orchestration is gone with the process that ran it.
        self.runs = runs.map { run in
            guard !run.phase.isFinished else { return run }
            var interrupted = run
            interrupted.phase = .cancelled
            interrupted.reason = String(localized: "Uncoil quit while the run was going.")
            interrupted.endedAt = interrupted.endedAt ?? interrupted.events.last?.date ?? run.startedAt
            return interrupted
        }
        isRunning = false
        onChange = callback
    }

    /// The run's latest state, from its orchestrator.
    func update(_ run: AutoRun) {
        if let index = runs.lastIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
            if runs.count > Self.runLimit { runs.removeFirst(runs.count - Self.runLimit) }
        }
        isRunning = !run.phase.isFinished
        onChange?()
    }

    func allows(_ provider: AgentProvider, settings: UncoilAutoSettings) -> Bool {
        settings.allows(provider) && !excludedAgents.contains(provider.rawValue)
    }

    func setExcluded(_ provider: AgentProvider, _ excluded: Bool) {
        if excluded { excludedAgents.insert(provider.rawValue) } else { excludedAgents.remove(provider.rawValue) }
    }
}
