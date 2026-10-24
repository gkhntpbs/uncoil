import Foundation

// MARK: - Uncoil Auto

/// Everything the user sets for Uncoil Auto, kept in `settings.json`.
struct UncoilAutoSettings: Codable, Equatable {
    /// Agents an Uncoil Auto conversation may address, by provider raw value.
    /// nil ⇒ every installed agent; a conversation can only narrow this.
    var allowedAgents: [String]?
    /// Whether the agents a conversation directs still notify on their own.
    var notifications: DirectedAgentNotifications = .whenConversationHidden
    /// How an Auto run is staffed, how far it goes, and what decides it.
    var harness = AutoHarnessSettings()

    static let `default` = UncoilAutoSettings()

    init() {}

    /// Field by field, so a file written before a field existed still loads —
    /// a synthesized decoder would reject it, and with it all of settings.json.
    /// The effort advisor's old `advisor` key is not read: it is gone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedAgents = try container.decodeIfPresent([String].self, forKey: .allowedAgents)
        notifications = (try? container.decodeIfPresent(DirectedAgentNotifications.self, forKey: .notifications))
            ?? .whenConversationHidden
        harness = (try? container.decodeIfPresent(AutoHarnessSettings.self, forKey: .harness)) ?? AutoHarnessSettings()
    }

    func allows(_ provider: AgentProvider) -> Bool {
        allowedAgents.map { $0.contains(provider.rawValue) } ?? true
    }
}

/// What happens to the notifications of an agent an Uncoil Auto conversation
/// is directing. An agent in no conversation is never affected.
enum DirectedAgentNotifications: String, Codable, CaseIterable, Identifiable {
    /// Exactly as for any other session.
    case asUsual
    /// Held back while the conversation directing the agent is on screen,
    /// where its replies and waits already show.
    case whenConversationHidden
    /// Only permission requests, and only while the conversation is not on
    /// screen: the one thing the conversation cannot answer for the agent.
    case permissionsOnly

    var id: String { rawValue }

    /// The events an agent's conversation already reports.
    static let covered: Set<NotificationEvent> = [.input, .turnCompleted, .permission, .problem]

    /// Whether this event, for an agent directed by `directors`, stays quiet.
    static func mutes(
        _ event: NotificationEvent,
        mode: DirectedAgentNotifications,
        directors: Set<UUID>,
        visibleSessionID: UUID?,
        appIsActive: Bool
    ) -> Bool {
        guard !directors.isEmpty, covered.contains(event) else { return false }
        let onScreen = appIsActive && visibleSessionID.map(directors.contains) == true
        switch mode {
        case .asUsual: return false
        case .whenConversationHidden: return onScreen
        case .permissionsOnly: return event == .permission ? onScreen : true
        }
    }
}

// MARK: - Harness

/// The specialists an Auto run can bring in. The main agent is not one of
/// them: it is the conversation's own target, chosen the way any session is.
enum AutoRole: String, Codable, CaseIterable, Identifiable {
    /// Reads the repository and reports what matters, so Main does not have to.
    case explorer
    /// Looks outside the repository: documentation, APIs, release notes.
    case researcher
    /// Makes the change Main delegated, and builds and tests it.
    case worker
    /// A rare, deep second opinion at the checkpoints the user chose.
    case advisor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .explorer: String(localized: "Explorer")
        case .researcher: String(localized: "Researcher")
        case .worker: String(localized: "Worker")
        case .advisor: String(localized: "Advisor")
        }
    }

    /// Roles that only read: started in the provider's read-only or plan mode
    /// when the user keeps them read-only.
    var readsOnly: Bool { self != .worker }
}

/// How one specialist is staffed: its agent, account, model and effort,
/// each set by hand. A model name only means something to the CLI it was
/// chosen for, so changing the agent clears them. `provider` nil is only
/// read from an older file and falls back to Main's agent.
struct AutoRoleSettings: Codable, Equatable {
    var enabled = true
    var provider: AgentProvider?
    /// One of the provider's logins; nil ⇒ its default login.
    var accountID: UUID?
    var model: String?
    var effort: String?
    /// Started in the provider's read-only mode where it has one.
    var readOnly = true
    /// Worker only: a fresh worktree per run, so its edits never land in the
    /// tree Main or the user is working in.
    var worktreeIsolation = true
    /// Worker only: turns spent fixing a failed verification before the
    /// failure goes back to Main.
    var maxRetries = 2
    /// One turn longer than this is interrupted and counted as a timeout.
    var maxRuntimeMinutes = 15
    /// Replaces the built-in instructions for the role when not empty.
    var instructions = ""

    init(
        enabled: Bool = true,
        provider: AgentProvider? = nil,
        model: String? = nil,
        effort: String? = nil,
        readOnly: Bool = true,
        worktreeIsolation: Bool = true,
        maxRetries: Int = 2,
        maxRuntimeMinutes: Int = 15
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.effort = effort
        self.readOnly = readOnly
        self.worktreeIsolation = worktreeIsolation
        self.maxRetries = maxRetries
        self.maxRuntimeMinutes = maxRuntimeMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoRoleSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        provider = try? container.decodeIfPresent(AgentProvider.self, forKey: .provider)
        accountID = try? container.decodeIfPresent(UUID.self, forKey: .accountID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? defaults.readOnly
        worktreeIsolation = try container.decodeIfPresent(Bool.self, forKey: .worktreeIsolation) ?? defaults.worktreeIsolation
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? defaults.maxRetries
        maxRuntimeMinutes = try container.decodeIfPresent(Int.self, forKey: .maxRuntimeMinutes) ?? defaults.maxRuntimeMinutes
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    }
}

/// When the Advisor is asked.
struct AutoAdvisorCheckpoints: Codable, Equatable {
    /// After Main's plan, before any work starts.
    var beforePlan = true
    /// When the same verification failure keeps coming back.
    var onRepeatedFailure = true
    /// Before the run is declared done.
    var beforeCompletion = false

    init(beforePlan: Bool = true, onRepeatedFailure: Bool = true, beforeCompletion: Bool = false) {
        self.beforePlan = beforePlan
        self.onRepeatedFailure = onRepeatedFailure
        self.beforeCompletion = beforeCompletion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoAdvisorCheckpoints()
        beforePlan = try container.decodeIfPresent(Bool.self, forKey: .beforePlan) ?? defaults.beforePlan
        onRepeatedFailure = try container.decodeIfPresent(Bool.self, forKey: .onRepeatedFailure) ?? defaults.onRepeatedFailure
        beforeCompletion = try container.decodeIfPresent(Bool.self, forKey: .beforeCompletion) ?? defaults.beforeCompletion
    }
}

/// What starts a run.
enum AutoExecutionMode: String, Codable, CaseIterable, Identifiable {
    /// Only `/auto <task>`; everything else is the conversation as before.
    case onCommand
    /// Every message that names nobody is a task for an Auto run.
    case everyMessage

    var id: String { rawValue }
}

/// When the Researcher is brought in.
enum AutoResearchMode: String, Codable, CaseIterable, Identifiable {
    case never
    /// When the research decision says the task needs outside information.
    case whenNeeded
    case always

    var id: String { rawValue }
}

/// What a specialist that fails, crashes or times out does to the run.
enum AutoSpecialistFailure: String, Codable, CaseIterable, Identifiable {
    /// Main carries on without that specialist's result, and is told so.
    case continueWithoutIt
    /// The run stops and says why.
    case stopRun

    var id: String { rawValue }
}

/// The policies that change how much work a run does.
struct AutoExecutionPolicy: Codable, Equatable {
    /// Explorer and Researcher run at the same time.
    var parallelSpecialists = true
    var research: AutoResearchMode = .whenNeeded
    /// The same failure this many times in a row goes to the Advisor (when
    /// that checkpoint is on) or back to Main — by policy, never by Laya.
    var repeatedFailureThreshold = 2
    /// A run is not complete without a verification phase.
    var alwaysVerify = true
    /// When the project declares a test suite, it must pass.
    var requireTestsWhenAvailable = true
    /// Main reads each specialist's result before work goes on.
    var mainReviewsSpecialistResults = true
    var specialistFailure: AutoSpecialistFailure = .continueWithoutIt
    var maxChildSessions = 8
    var maxConcurrentSpecialists = 2
    /// The whole run, after which it stops where it is.
    var maxRunMinutes = 90
    /// Times the Worker's failure goes back to Main for a new brief.
    var maxMainRevisions = 2
    /// Stops specialist processes when the run ends. Their sessions stay in
    /// the sidebar either way, to be read or resumed.
    var stopSpecialistsWhenDone = false
    /// A Worker worktree that ends the run with no changes is removed.
    var removeEmptyWorktrees = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoExecutionPolicy()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        parallelSpecialists = value(.parallelSpecialists, d.parallelSpecialists)
        research = value(.research, d.research)
        repeatedFailureThreshold = value(.repeatedFailureThreshold, d.repeatedFailureThreshold)
        alwaysVerify = value(.alwaysVerify, d.alwaysVerify)
        requireTestsWhenAvailable = value(.requireTestsWhenAvailable, d.requireTestsWhenAvailable)
        mainReviewsSpecialistResults = value(.mainReviewsSpecialistResults, d.mainReviewsSpecialistResults)
        specialistFailure = value(.specialistFailure, d.specialistFailure)
        maxChildSessions = value(.maxChildSessions, d.maxChildSessions)
        maxConcurrentSpecialists = value(.maxConcurrentSpecialists, d.maxConcurrentSpecialists)
        maxRunMinutes = value(.maxRunMinutes, d.maxRunMinutes)
        maxMainRevisions = value(.maxMainRevisions, d.maxMainRevisions)
        stopSpecialistsWhenDone = value(.stopSpecialistsWhenDone, d.stopSpecialistsWhenDone)
        removeEmptyWorktrees = value(.removeEmptyWorktrees, d.removeEmptyWorktrees)
    }
}

/// How much say Laya has over one decision.
enum AutoDecisionAuthority: String, Codable, CaseIterable, Identifiable {
    /// Not asked.
    case off
    /// Asked and recorded; the deterministic policy acts.
    case shadow
    /// Its choice is the action, inside the policies that sit above it.
    case active

    var id: String { rawValue }
}

/// The local decision engine.
struct AutoDecisionSettings: Codable, Equatable {
    var enabled = true
    /// Which Laya checkpoint answers; "auto" lets the server pick by language.
    var checkpoint = "auto"
    /// A decision slower than this is dropped for the deterministic one.
    var timeoutMilliseconds = 1_500
    /// A choice less certain than this is not acted on, even when active.
    var minimumConfidence = 0.5
    /// By `AutoDecisionKind` raw value; missing ⇒ shadow.
    var authority: [String: AutoDecisionAuthority] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoDecisionSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        checkpoint = (try? container.decodeIfPresent(String.self, forKey: .checkpoint)) ?? d.checkpoint
        timeoutMilliseconds = (try? container.decodeIfPresent(Int.self, forKey: .timeoutMilliseconds)) ?? d.timeoutMilliseconds
        minimumConfidence = (try? container.decodeIfPresent(Double.self, forKey: .minimumConfidence)) ?? d.minimumConfidence
        authority = (try? container.decodeIfPresent([String: AutoDecisionAuthority].self, forKey: .authority)) ?? [:]
    }

    func authority(for kind: AutoDecisionKind) -> AutoDecisionAuthority {
        guard enabled else { return .off }
        return authority[kind.rawValue] ?? .shadow
    }
}

/// How Uncoil Auto runs a task: who does what, when the Advisor is asked,
/// what Laya decides, and the limits around all of it.
struct AutoHarnessSettings: Codable, Equatable {
    var enabled = true
    var mode: AutoExecutionMode = .onCommand
    /// By `AutoRole` raw value; a missing role takes its default.
    var roles: [AutoRole: AutoRoleSettings] = Self.defaultRoles
    var advisorCheckpoints = AutoAdvisorCheckpoints()
    var policy = AutoExecutionPolicy()
    var decisions = AutoDecisionSettings()

    /// Where every role starts: each one names its agent, model and effort
    /// explicitly, and every value is the user's to change.
    static let defaultRoles: [AutoRole: AutoRoleSettings] = [
        .explorer: AutoRoleSettings(provider: .claude, model: "sonnet", effort: "medium", readOnly: true, maxRuntimeMinutes: 10),
        .researcher: AutoRoleSettings(provider: .claude, model: "sonnet", effort: "medium", readOnly: true, maxRuntimeMinutes: 10),
        .worker: AutoRoleSettings(provider: .claude, model: "sonnet", effort: "medium", readOnly: false, worktreeIsolation: true, maxRetries: 2, maxRuntimeMinutes: 25),
        .advisor: AutoRoleSettings(provider: .claude, model: "fable", effort: nil, readOnly: true, maxRuntimeMinutes: 10),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoHarnessSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        mode = (try? container.decodeIfPresent(AutoExecutionMode.self, forKey: .mode)) ?? d.mode
        // Keyed by raw value on disk, so an unknown role in a newer file is
        // skipped rather than failing the whole dictionary.
        let raw = (try? container.decodeIfPresent([String: AutoRoleSettings].self, forKey: .roles)) ?? [:]
        var roles = Self.defaultRoles
        for (key, value) in raw {
            guard let role = AutoRole(rawValue: key) else { continue }
            var value = value
            // A role saved as "the same agent as Main" names its agent now.
            if value.provider == nil {
                value.provider = Self.defaultRoles[role]?.provider
                value.model = Self.defaultRoles[role]?.model
                value.effort = Self.defaultRoles[role]?.effort
            }
            roles[role] = value
        }
        self.roles = roles
        advisorCheckpoints = (try? container.decodeIfPresent(AutoAdvisorCheckpoints.self, forKey: .advisorCheckpoints)) ?? d.advisorCheckpoints
        policy = (try? container.decodeIfPresent(AutoExecutionPolicy.self, forKey: .policy)) ?? d.policy
        decisions = (try? container.decodeIfPresent(AutoDecisionSettings.self, forKey: .decisions)) ?? d.decisions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mode, forKey: .mode)
        try container.encode(
            Dictionary(uniqueKeysWithValues: roles.map { ($0.key.rawValue, $0.value) }), forKey: .roles)
        try container.encode(advisorCheckpoints, forKey: .advisorCheckpoints)
        try container.encode(policy, forKey: .policy)
        try container.encode(decisions, forKey: .decisions)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, roles, advisorCheckpoints, policy, decisions
    }

    func role(_ role: AutoRole) -> AutoRoleSettings {
        roles[role] ?? Self.defaultRoles[role] ?? AutoRoleSettings()
    }
}
