import Foundation

/// Where a run is.
enum AutoPhase: String, Codable, Equatable {
    case starting
    case exploring
    case planning
    case advising
    case implementing
    case verifying
    case reviewing
    case completed
    case failed
    case cancelled

    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }

    var displayName: String {
        switch self {
        case .starting: String(localized: "Starting…")
        case .exploring: String(localized: "Exploring the project…")
        case .planning: String(localized: "Planning…")
        case .advising: String(localized: "Advisor reviewing…")
        case .implementing: String(localized: "Implementing…")
        case .verifying: String(localized: "Verifying…")
        case .reviewing: String(localized: "Main reviewing the result…")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Stopped")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

/// One session taking part in a run, as the run sees it.
struct AutoParticipant: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case working
        case idle
        case done
        case failed
        case timedOut
        case crashed
        case stopped
    }

    var sessionID: UUID
    /// "main", or an `AutoRole` raw value.
    var role: String
    var provider: AgentProvider
    var handle: String
    var model: String?
    var effort: String?
    var worktreePath: String?
    var state: State = .idle

    var id: UUID { sessionID }

    var roleName: String {
        role == "main" ? String(localized: "Main") : (AutoRole(rawValue: role)?.displayName ?? role)
    }

    /// "Explorer · Claude · sonnet · medium".
    var label: String {
        ([roleName, provider.displayName] + [model, effort].compactMap { $0 }).joined(separator: " · ")
    }
}

/// One line of a run's history.
struct AutoRunEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case phase
        case session
        case prompt
        case handoff
        case advisor
        case verification
        case decision
        case policy
        case warning
        case error
        case outcome
    }

    var id: Int
    var date: Date
    var kind: Kind
    var title: String
    var detail: String?
}

/// What one verification found.
struct AutoVerificationRecord: Codable, Equatable {
    enum Verdict: String, Codable {
        /// Observable evidence says the work holds.
        case passed
        case failed
        /// Nothing could be checked; only the Worker's word is there.
        case unverified
    }

    struct Suite: Codable, Equatable {
        var name: String
        var command: String
        var exitCode: Int32?
        var timedOut: Bool
        var outputTail: String
    }

    var attempt: Int
    var date: Date
    var verdict: Verdict
    /// What the Worker said about its own work.
    var claimedStatus: String?
    var turnOutcome: String
    var suites: [Suite] = []
    var changedFiles: [String] = []
    /// Commands the Worker ran this turn, with their exit codes when known.
    var workerCommands: [String] = []
    var reasons: [String] = []
    /// What makes two failures "the same failure".
    var signature: String?

    /// The evidence, as Main and the Advisor are told it.
    var summary: String {
        var lines = ["Verdict: \(verdict.rawValue) (attempt \(attempt))", "Worker turn: \(turnOutcome)"]
        if let claimedStatus { lines.append("Worker says: \(claimedStatus)") }
        for suite in suites {
            let result = suite.timedOut ? "timed out" : "exit \(suite.exitCode.map(String.init) ?? "?")"
            lines.append("\(suite.name) (`\(suite.command)`): \(result)")
            if suite.exitCode != 0, !suite.outputTail.isEmpty {
                lines.append("```\n\(suite.outputTail)\n```")
            }
        }
        if suites.isEmpty { lines.append("No project test suite was run.") }
        if !changedFiles.isEmpty { lines.append("Changed files: \(changedFiles.prefix(30).joined(separator: ", "))") }
        lines += reasons
        return lines.joined(separator: "\n")
    }
}

/// One Auto run, from task to outcome. Persisted with the conversation, so
/// its diagnostics outlive a relaunch; bounded, so it never grows without end.
struct AutoRun: Codable, Equatable, Identifiable {
    static let eventLimit = 400
    static let decisionLimit = 100

    var id = UUID()
    var task: String
    var startedAt: Date
    var endedAt: Date?
    var phase: AutoPhase = .starting
    /// Why it stopped, when it did not complete.
    var reason: String?
    var participants: [AutoParticipant] = []
    var events: [AutoRunEvent] = []
    var decisions: [AutoDecisionRecord] = []
    var verifications: [AutoVerificationRecord] = []
    private var nextEventID = 0

    init(task: String, startedAt: Date) {
        self.task = task
        self.startedAt = startedAt
    }

    var main: AutoParticipant? { participants.first { $0.role == "main" } }

    func participant(_ role: AutoRole) -> AutoParticipant? {
        participants.last { $0.role == role.rawValue }
    }

    var childCount: Int { participants.filter { $0.role != "main" }.count }

    mutating func log(_ kind: AutoRunEvent.Kind, _ title: String, detail: String? = nil, at date: Date) {
        nextEventID += 1
        events.append(AutoRunEvent(id: nextEventID, date: date, kind: kind, title: title, detail: detail.map { String($0.prefix(6_000)) }))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    mutating func record(_ decision: AutoDecisionRecord) {
        decisions.append(decision)
        if decisions.count > Self.decisionLimit { decisions.removeFirst(decisions.count - Self.decisionLimit) }
    }

    mutating func update(_ sessionID: UUID, _ change: (inout AutoParticipant) -> Void) {
        guard let index = participants.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        change(&participants[index])
    }
}
