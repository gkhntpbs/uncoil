import Foundation

// MARK: - Catalog

/// The small control decisions an Auto run may put to Laya. Each is a typed
/// question with a closed set of options and a deterministic answer the run
/// takes whenever Laya is off, in shadow, unsure, slow or wrong.
///
/// Every wording Laya reads lives here and nowhere else, so changing what a
/// decision asks is one edit, and the diagnostics can show exactly what was
/// asked.
enum AutoDecisionKind: String, Codable, CaseIterable, Identifiable {
    /// Before exploration: does the task need outside information?
    case research
    /// After a failed verification: what to do with the failure.
    case failureTriage
    /// Before completion, when no checkpoint already requires the Advisor:
    /// is a deep review worth its cost?
    case completionReview

    var id: String { rawValue }

    var schema: AutoDecisionSchema {
        switch self {
        case .research:
            AutoDecisionSchema(
                kind: self,
                title: String(localized: "Research gate"),
                question: "Does completing this coding task need information from outside the repository, such as documentation, API behaviour, release notes or recent changes in a framework?",
                options: [
                    .init(id: "no_research", description: "no: the repository and general knowledge are enough"),
                    .init(id: "research", description: "yes: it depends on external, version-specific or current information"),
                ],
                fallback: "no_research")
        case .failureTriage:
            AutoDecisionSchema(
                kind: self,
                title: String(localized: "Failure triage"),
                question: "A worker agent's change failed verification. What should the orchestrator do next?",
                options: [
                    .init(id: "retry", description: "retry: the failure looks like an ordinary mistake the worker can fix with the error output"),
                    .init(id: "return_to_main", description: "return to main: the brief or the plan seems wrong, the main agent should decide again"),
                    .init(id: "escalate_to_advisor", description: "escalate: the failure is repeated or suspicious, a deeper review of the approach is needed"),
                ],
                fallback: "retry")
        case .completionReview:
            AutoDecisionSchema(
                kind: self,
                title: String(localized: "Completion review"),
                question: "The change passed verification. Is a deep independent review needed before declaring the task complete?",
                options: [
                    .init(id: "advisor_not_needed", description: "no: the change is small, verified and low risk"),
                    .init(id: "advisor_recommended", description: "yes: the change is broad, risky or its verification is thin"),
                ],
                fallback: "advisor_not_needed")
        }
    }
}

/// One decision as Laya is asked it.
struct AutoDecisionSchema: Equatable {
    struct Option: Equatable, Codable {
        var id: String
        var description: String
    }

    var kind: AutoDecisionKind
    var title: String
    var question: String
    var options: [Option]
    /// What the run does when nothing better is known.
    var fallback: String

    var optionIDs: [String] { options.map(\.id) }
}

// MARK: - Answers

/// What the decision engine answered.
struct AutoDecisionAnswer: Codable, Equatable {
    var choice: String
    var probabilities: [String: Double]
    var confidence: Double
    /// The checkpoint that answered.
    var model: String?
    var latencyMilliseconds: Double?
}

/// A decision engine: Laya, or a fake in tests.
protocol AutoDecisionEngine: Sendable {
    func decide(_ schema: AutoDecisionSchema, state: String, checkpoint: String) async throws -> AutoDecisionAnswer
}

enum AutoDecisionError: Error, Equatable, CustomStringConvertible {
    case unavailable
    case timedOut
    case status(Int)
    case malformed
    /// The engine answered something that is not one of the options.
    case invalidChoice(String)

    var description: String {
        switch self {
        case .unavailable: "the decision engine is not running"
        case .timedOut: "the decision engine did not answer in time"
        case .status(let code): "the decision engine answered HTTP \(code)"
        case .malformed: "the decision engine's answer could not be read"
        case .invalidChoice(let choice): "the decision engine chose '\(choice)', which is not an option"
        }
    }
}

/// Asks a local `laya-apple serve` one `choice` question over its
/// Jev-compatible `POST /v1/systemone`.
struct LayaDecisionClient: AutoDecisionEngine {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    var timeout: TimeInterval = 5
    var transport: Transport = { request in try await URLSession.shared.data(for: request) }

    /// The longest state Laya is handed; it cuts longer ones itself, but a
    /// cut made here keeps the beginning, which is where the question is.
    static let stateLimit = 2_400

    static func requestBody(_ schema: AutoDecisionSchema, state: String, checkpoint: String) throws -> Data {
        var criteria: [String: String] = [:]
        for option in schema.options { criteria[option.id] = option.description }
        var body: [String: Any] = [
            "state": String(state.prefix(stateLimit)),
            "questions": [
                "decision": [
                    "type": "choice",
                    "instructions": schema.question,
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]
        if checkpoint != "auto", !checkpoint.isEmpty { body["model"] = checkpoint }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func decide(_ schema: AutoDecisionSchema, state: String, checkpoint: String) async throws -> AutoDecisionAnswer {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(schema, state: state, checkpoint: checkpoint)
        let started = Date()
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AutoDecisionError.status(http.statusCode)
        }
        var answer = try Self.parse(data, schema: schema)
        if answer.latencyMilliseconds == nil {
            answer.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
        }
        return answer
    }

    static func parse(_ data: Data, schema: AutoDecisionSchema) throws -> AutoDecisionAnswer {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let decision = answers["decision"] as? [String: Any],
              let choice = decision["choice"] as? String
        else { throw AutoDecisionError.malformed }
        guard schema.optionIDs.contains(choice) else { throw AutoDecisionError.invalidChoice(choice) }
        let raw = decision["probabilities"] as? [String: Any] ?? [:]
        var probabilities: [String: Double] = [:]
        for id in schema.optionIDs {
            probabilities[id] = (raw[id] as? NSNumber)?.doubleValue ?? 0
        }
        let block = root["laya_apple"] as? [String: Any]
        let routing = root["routing"] as? [String: Any]
        return AutoDecisionAnswer(
            choice: choice,
            probabilities: probabilities,
            confidence: (decision["confidence"] as? NSNumber)?.doubleValue ?? probabilities[choice] ?? 0,
            model: block?["model"] as? String ?? routing?["model"] as? String,
            latencyMilliseconds: (block?["latency_ms"] as? NSNumber)?.doubleValue)
    }
}

// MARK: - Resolving a decision

/// One decision as the run took it: what was asked, what Laya said, what the
/// policy said, and what was done. Kept in the run's diagnostics.
struct AutoDecisionRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: AutoDecisionKind
    var question: String
    var options: [String]
    /// The state Laya read.
    var state: String
    var authority: AutoDecisionAuthority
    var answer: AutoDecisionAnswer?
    /// Why Laya had no answer: off, unavailable, timed out, invalid.
    var engineError: String?
    /// What the deterministic policy would do on its own.
    var deterministic: String
    /// A policy above Laya that decided regardless, and why.
    var override: String?
    /// What the run did.
    var action: String

    /// Whether Laya's answer is what the run did.
    var layaDecided: Bool {
        authority == .active && override == nil && answer?.choice == action
    }
}

/// Turns a question into an action, with Laya in whatever role the user gave
/// it. Pure apart from the engine call, so every branch is testable.
enum AutoDecisionResolver {
    /// - Parameters:
    ///   - deterministic: what the run does without Laya.
    ///   - forced: a policy that decides regardless — a budget, a threshold,
    ///     a checkpoint the user switched on. Laya is still asked (unless
    ///     off), so the diagnostics show what it would have done.
    static func resolve(
        _ kind: AutoDecisionKind,
        state: String,
        deterministic: String,
        forced: (action: String, reason: String)? = nil,
        settings: AutoDecisionSettings,
        engine: (any AutoDecisionEngine)?,
        now: Date = Date()
    ) async -> AutoDecisionRecord {
        let schema = kind.schema
        let authority = settings.authority(for: kind)
        var record = AutoDecisionRecord(
            date: now, kind: kind, question: schema.question, options: schema.optionIDs,
            state: String(state.prefix(LayaDecisionClient.stateLimit)),
            authority: authority, deterministic: deterministic, action: deterministic)
        if authority != .off {
            if let engine {
                do {
                    record.answer = try await withTimeout(milliseconds: settings.timeoutMilliseconds) {
                        try await engine.decide(schema, state: state, checkpoint: settings.checkpoint)
                    }
                } catch let error as AutoDecisionError {
                    record.engineError = error.description
                } catch {
                    record.engineError = error.localizedDescription
                }
            } else {
                record.engineError = AutoDecisionError.unavailable.description
            }
        } else {
            record.engineError = "off"
        }
        if let forced {
            record.override = forced.reason
            record.action = forced.action
            return record
        }
        if authority == .active, let answer = record.answer {
            if answer.confidence >= settings.minimumConfidence {
                record.action = answer.choice
            } else {
                record.override = String(format: "confidence %.2f below %.2f", answer.confidence, settings.minimumConfidence)
            }
        }
        return record
    }

    static func withTimeout<T: Sendable>(
        milliseconds: Int,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(max(1, milliseconds)))
                throw AutoDecisionError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AutoDecisionError.timedOut }
            return first
        }
    }
}
