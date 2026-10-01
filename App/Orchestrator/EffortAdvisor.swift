import Foundation

// MARK: - Settings

/// Everything the user sets for Uncoil Auto, kept in `settings.json`.
struct UncoilAutoSettings: Codable, Equatable {
    /// Agents an Uncoil Auto conversation may address, by provider raw value.
    /// nil ⇒ every installed agent; a conversation can only narrow this.
    var allowedAgents: [String]?
    var advisor = EffortAdvisorSettings()
    /// Whether the agents a conversation directs still notify on their own.
    var notifications: DirectedAgentNotifications = .whenConversationHidden

    static let `default` = UncoilAutoSettings()

    init() {}

    /// Field by field, so a file written before a field existed still loads —
    /// a synthesized decoder would reject it, and with it all of settings.json.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedAgents = try container.decodeIfPresent([String].self, forKey: .allowedAgents)
        advisor = try container.decodeIfPresent(EffortAdvisorSettings.self, forKey: .advisor) ?? EffortAdvisorSettings()
        notifications = (try? container.decodeIfPresent(DirectedAgentNotifications.self, forKey: .notifications))
            ?? .whenConversationHidden
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

/// How the effort advisor reads a prompt and what it may suggest.
struct EffortAdvisorSettings: Codable, Equatable {
    enum Engine: String, Codable, CaseIterable, Identifiable {
        /// Keywords and length, in the app. Always available.
        case heuristic
        /// A System 1 decision model served on this Mac by `laya-apple`.
        case laya

        var id: String { rawValue }
    }

    var enabled = true
    var engine: Engine = .heuristic
    /// Suggestions the advisor is less sure of than this are not shown.
    var confidenceThreshold = 0.3
    /// Per agent, by provider raw value; a missing entry ⇒ on, whole ladder.
    var perAgent: [String: AgentEffortPolicy] = [:]
    /// Whether each decision is written to `decisions.jsonl`, the data a
    /// later fine-tune learns from.
    var keepDecisionLog = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EffortAdvisorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        engine = (try? container.decodeIfPresent(Engine.self, forKey: .engine)) ?? defaults.engine
        confidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .confidenceThreshold)
            ?? defaults.confidenceThreshold
        perAgent = try container.decodeIfPresent([String: AgentEffortPolicy].self, forKey: .perAgent) ?? [:]
        keepDecisionLog = try container.decodeIfPresent(Bool.self, forKey: .keepDecisionLog) ?? defaults.keepDecisionLog
    }

    func policy(for provider: AgentProvider) -> AgentEffortPolicy {
        perAgent[provider.rawValue] ?? AgentEffortPolicy()
    }
}

/// The part of an agent's effort ladder the advisor may choose from.
struct AgentEffortPolicy: Codable, Equatable {
    var enabled = true
    /// Lowest level to suggest; nil ⇒ the ladder's lowest.
    var minimum: String?
    /// Highest level to suggest; nil ⇒ the ladder's highest.
    var maximum: String?

    init(enabled: Bool = true, minimum: String? = nil, maximum: String? = nil) {
        self.enabled = enabled
        self.minimum = minimum
        self.maximum = maximum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minimum = try container.decodeIfPresent(String.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(String.self, forKey: .maximum)
    }

    /// Indices into `ladder` the advisor may pick, after fitting the saved
    /// bounds to what the installed CLI offers today: a level that is gone
    /// falls back to the ladder's end, and bounds saved the wrong way round
    /// are swapped rather than leaving nothing to choose from.
    func range(in ladder: EffortLadder) -> ClosedRange<Int>? {
        guard !ladder.levels.isEmpty else { return nil }
        let low = minimum.flatMap(ladder.index(of:)) ?? 0
        let high = maximum.flatMap(ladder.index(of:)) ?? ladder.levels.count - 1
        return min(low, high)...max(low, high)
    }
}

// MARK: - Ladder

/// An agent's effort levels, lowest first, as its installed CLI names them.
struct EffortLadder: Equatable {
    let provider: AgentProvider
    let levels: [String]

    init(provider: AgentProvider, levels: [String]) {
        self.provider = provider
        self.levels = levels
    }

    init(provider: AgentProvider, capabilities: AgentLaunchCapabilities) {
        self.init(provider: provider, levels: capabilities.efforts.map(\.id))
    }

    var isEmpty: Bool { levels.isEmpty }

    func index(of level: String) -> Int? {
        levels.firstIndex(of: level.lowercased())
    }

    /// The ladder the installed CLI offers, read the way the launch sheet
    /// reads it: from the CLI's own `--help`, once per run.
    @MainActor
    static func detect(_ provider: AgentProvider, settings: SettingsStore) async -> EffortLadder {
        let capabilities = await AgentLaunchCatalog.detect(
            provider: provider, binaryPath: settings.binaryPath(for: provider))
        return EffortLadder(provider: provider, capabilities: capabilities)
    }
}

// MARK: - Reading a prompt

/// What the advisor is asked about: the prompt, and where the conversation
/// has been going.
struct EffortContext: Equatable {
    var prompt: String
    var provider: AgentProvider
    /// The last few things said in the conversation, oldest first, already
    /// one line each.
    var recent: [String] = []

    static let stateLimit = 1_800

    /// The text the model reads. The request comes first: a long history is
    /// cut from the end, and the request is what must survive the cut.
    var state: String {
        var text = "Request: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !recent.isEmpty {
            text += "\n\nEarlier in this conversation:\n" + recent.map { "- \($0)" }.joined(separator: "\n")
        }
        return text.count > Self.stateLimit ? String(text.prefix(Self.stateLimit)) : text
    }
}

/// What the advisor read out of a prompt. The same shape whichever engine
/// read it, so the policy that turns it into an effort is engine-blind.
struct EffortFeatures: Codable, Equatable {
    enum Source: String, Codable {
        case heuristic
        case laya
        /// The model and the heuristic averaged: what a non-English prompt
        /// gets, where the model's complexity reading is weakest.
        case blended
    }

    /// Expected value on 0 (trivial) … 4 (very hard).
    var complexity: Double
    /// Probability of each of the five complexity buckets.
    var distribution: [Double]
    var questionOnly: Double
    var multiStep: Double
    var afterFailure: Double
    var needsDesign: Double
    var source: Source
    /// The checkpoint that answered, when a model did.
    var model: String?
    var latencyMilliseconds: Double?

    static let buckets = 5
}

protocol EffortAdvisor: Sendable {
    func features(for context: EffortContext) async throws -> EffortFeatures
}

// MARK: - Policy

/// One effort the advisor would pick for one agent.
struct EffortSuggestion: Equatable {
    var provider: AgentProvider
    var level: String
    /// How much of the model's probability lands on this level.
    var confidence: Double
    /// Short phrases saying why, for the chip's tooltip.
    var reasons: [String]
    var features: EffortFeatures
    /// The effort the session runs at now; nil ⇒ the CLI's own default.
    var current: String?

    var isChange: Bool { level != current }
}

/// Turns what the advisor read into a level on the agent's ladder.
///
/// Deterministic, and blind to the engine: complexity sets the base, a
/// failed earlier attempt or a request for design lifts it, and the result
/// is placed inside the user's bounds. Each complexity bucket is placed the
/// same way, and the confidence is the probability of the buckets that land
/// on the chosen level — so a reading split between "small" and "hard" says
/// so instead of claiming certainty.
enum EffortPolicy {
    static let signalThreshold = 0.6

    static func decide(
        _ features: EffortFeatures,
        ladder: EffortLadder,
        policy: AgentEffortPolicy,
        current: String?
    ) -> EffortSuggestion? {
        guard policy.enabled, let range = policy.range(in: ladder) else { return nil }
        var lift = 0.0
        var reasons: [String] = []
        if features.afterFailure >= signalThreshold {
            lift += 0.2
            reasons.append("an earlier attempt did not work")
        }
        if features.needsDesign >= signalThreshold {
            lift += 0.2
            reasons.append("asks for design or a plan")
        }
        if features.multiStep >= 0.7 {
            lift += 0.1
            reasons.append("several steps or files")
        }
        func place(_ complexity: Double) -> Int {
            let score = min(1, max(0, complexity / 4 + lift))
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + Int((score * span).rounded())
        }
        let index = place(features.complexity)
        let confidence = features.distribution.enumerated()
            .filter { place(Double($0.offset)) == index }
            .reduce(0) { $0 + $1.element }
        reasons.insert(complexityPhrase(features.complexity), at: 0)
        return EffortSuggestion(
            provider: ladder.provider,
            level: ladder.levels[index],
            confidence: min(1, confidence),
            reasons: reasons,
            features: features,
            current: current)
    }

    static func complexityPhrase(_ complexity: Double) -> String {
        switch complexity {
        case ..<0.75: "reads as trivial"
        case ..<1.75: "reads as a small change"
        case ..<2.5: "reads as moderate work"
        case ..<3.25: "reads as hard"
        default: "reads as very hard"
        }
    }
}

// MARK: - Heuristic engine

/// Length and a few words, in English and Turkish. Fast, always there, and
/// the fallback when the model is not.
struct HeuristicEffortAdvisor: EffortAdvisor {
    private static let trivial = [
        "typo", "rename", "yazım hata", "yeniden adlandır", "adını değiştir", "bump", "format",
        "one line", "tek satır", "comment", "yorum satırı",
    ]
    private static let hard = [
        "refactor", "architecture", "redesign", "migrate", "migration", "root cause", "race condition",
        "concurrency", "deadlock", "performance", "security", "debug", "investigate",
        "mimari", "yeniden tasarla", "kök neden", "performans", "güvenlik", "araştır", "incele",
    ]
    private static let failure = [
        "still", "didn't work", "did not work", "doesn't work", "does not work", "not working", "again",
        "hâlâ", "hala", "olmadı", "çalışmadı", "işe yaramadı", "yine", "tekrar bozuldu",
    ]
    private static let design = [
        "design", "architecture", "plan", "propose", "approach", "trade-off",
        "tasarla", "tasarım", "mimari", "plan", "öner", "yaklaşım",
    ]
    private static let question = [
        "what ", "why ", "how does", "explain", "is there", "nedir", "neden", "nasıl çalışıyor",
        "açıkla", "ne işe yarıyor", "ne yapıyor",
    ]
    private static let multiStep = [
        " and then", "all files", "every ", "across", "each ", "tüm ", "her yerde", "bütün ", "ardından",
    ]

    func features(for context: EffortContext) async throws -> EffortFeatures {
        Self.read(context)
    }

    static func read(_ context: EffortContext) -> EffortFeatures {
        let text = context.prompt.lowercased()
        let history = context.recent.joined(separator: "\n").lowercased()
        func hits(_ words: [String], in haystack: String) -> Int {
            words.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        var complexity: Double = switch words {
        case ..<12: 1
        case ..<40: 1.5
        case ..<120: 2
        default: 2.5
        }
        complexity -= Double(min(hits(trivial, in: text), 1))
        complexity += Double(min(hits(hard, in: text), 2)) * 0.75
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let multi = min(1, Double(hits(multiStep, in: text)) * 0.4 + (lines > 3 ? 0.4 : 0))
        let failed = hits(failure, in: text) > 0 ? 0.8 : (hits(failure, in: history) > 0 ? 0.4 : 0.05)
        let designed = hits(design, in: text) > 0 ? 0.75 : 0.05
        let asked = hits(question, in: text) > 0 || text.hasSuffix("?") ? 0.8 : 0.1
        if asked > 0.5, designed < 0.5 { complexity -= 0.5 }
        complexity = min(4, max(0, complexity))
        return EffortFeatures(
            complexity: complexity,
            distribution: softDistribution(around: complexity),
            questionOnly: asked,
            multiStep: multi,
            afterFailure: failed,
            needsDesign: designed,
            source: .heuristic)
    }

    /// Most of the weight on the nearest bucket, some on its neighbours: a
    /// heuristic is never as sure as a one-hot answer would claim.
    static func softDistribution(around complexity: Double) -> [Double] {
        let center = Int(complexity.rounded())
        var weights = (0..<EffortFeatures.buckets).map { bucket -> Double in
            switch abs(bucket - center) {
            case 0: 0.6
            case 1: 0.2
            default: 0.0
            }
        }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        return weights
    }
}

// MARK: - Laya engine

/// Asks a local `laya-apple serve` over its Jev-compatible
/// `POST /v1/systemone`: one ordinal question and four yes/no questions,
/// batched into a single forward pass.
struct LayaEffortAdvisor: EffortAdvisor {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Failure: Error, Equatable {
        case status(Int)
        case malformed
    }

    let baseURL: URL
    var timeout: TimeInterval = 1.5
    var transport: Transport = { request in try await URLSession.shared.data(for: request) }

    /// Wording measured against the shipped checkpoints: the ordinal
    /// question orders typo < rename < feature < failing debug < redesign.
    static let questions: [String: Any] = [
        "complexity": [
            "type": "score",
            "instructions": "How much reasoning effort does a coding agent need to complete this request well?",
            "criteria": [
                "trivial: a one-line edit, rename, typo or a quick factual answer",
                "small: a contained change in one file or a short explanation",
                "moderate: a feature or fix touching a few files, some investigation",
                "hard: debugging an unclear failure, cross-cutting refactor or design decisions",
                "very hard: architecture, a large redesign, or a problem that already resisted several attempts",
            ],
        ],
        "question_only": [
            "type": "noul",
            "instructions": "Is the user only asking a question or for an explanation, with no code change requested?",
        ],
        "multi_step": [
            "type": "noul",
            "instructions": "Does the request require several steps or changes across multiple files?",
        ],
        "after_failure": [
            "type": "noul",
            "instructions": "Does the user say a previous attempt failed or the problem still happens?",
        ],
        "needs_design": [
            "type": "noul",
            "instructions": "Does the request ask for architecture, design or a plan rather than a direct edit?",
        ],
    ]

    static func requestBody(for context: EffortContext) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["state": context.state, "questions": questions], options: [.sortedKeys])
    }

    func features(for context: EffortContext) async throws -> EffortFeatures {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(for: context)
        let started = Date()
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.status(http.statusCode)
        }
        var features = try Self.parse(data)
        features.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
        // The multilingual checkpoint orders complexity poorly on the
        // prompts measured (a Turkish typo read as harder than a feature),
        // while its yes/no answers held up; average its complexity with the
        // heuristic's rather than trust it alone.
        if features.model?.contains("multilingual") == true {
            let heuristic = HeuristicEffortAdvisor.read(context)
            features.complexity = (features.complexity + heuristic.complexity) / 2
            features.distribution = zip(features.distribution, heuristic.distribution).map { ($0 + $1) / 2 }
            features.source = .blended
        }
        return features
    }

    static func parse(_ data: Data) throws -> EffortFeatures {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let complexity = answers["complexity"] as? [String: Any],
              let score = (complexity["score"] as? NSNumber)?.doubleValue
        else { throw Failure.malformed }
        let probabilities = complexity["probabilities"] as? [String: Any] ?? [:]
        var distribution = (0..<EffortFeatures.buckets).map {
            (probabilities[String($0)] as? NSNumber)?.doubleValue ?? 0
        }
        if distribution.reduce(0, +) <= 0 {
            distribution = HeuristicEffortAdvisor.softDistribution(around: score)
        }
        func noul(_ key: String) -> Double {
            ((answers[key] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue ?? 0
        }
        let routing = root["routing"] as? [String: Any]
        return EffortFeatures(
            complexity: min(4, max(0, score)),
            distribution: distribution,
            questionOnly: noul("question_only"),
            multiStep: noul("multi_step"),
            afterFailure: noul("after_failure"),
            needsDesign: noul("needs_design"),
            source: .laya,
            model: routing?["model"] as? String)
    }
}

/// The model when it answers, the heuristic when it does not: a suggestion
/// is never held up by a sidecar that is starting, stopped or slow.
struct FallbackEffortAdvisor: EffortAdvisor {
    let primary: (any EffortAdvisor)?
    var fallback: any EffortAdvisor = HeuristicEffortAdvisor()

    func features(for context: EffortContext) async throws -> EffortFeatures {
        if let primary, let features = try? await primary.features(for: context) {
            return features
        }
        return try await fallback.features(for: context)
    }
}
