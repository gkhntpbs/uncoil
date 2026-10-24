import Foundation

/// Sub-agents a session's agent has started and not yet seen finish.
///
/// Claude Code runs its own sub-agents through the Task/Agent tool, without
/// going through Uncoil. Run in the background, they outlive the turn that
/// started them: the main agent's `Stop` arrives while they are still working,
/// and reading that `Stop` as "done" is what sent "Turn done" for work that
/// was not. `SubagentStart` / `SubagentStop` are what say how many are left.
///
/// Pure, so the sequences can be tested without a hook socket.
struct SubagentLedger {
    /// How long a sub-agent may go unheard-of before it is presumed gone. A
    /// lost `SubagentStop` (a crash, an older hook set) must not hold a session
    /// in "Sub-agents working" forever.
    static let expiry: TimeInterval = 2 * 60 * 60

    private struct Session {
        /// Started sub-agents by id, with when each was last heard from. Ids
        /// are Claude's `agent_id`; one without an id gets a synthetic key.
        var running: [String: Date] = [:]
        /// The main agent's turn has ended while sub-agents were still
        /// running — the session is waiting on them, not on the human.
        var mainTurnOver = false
    }

    private var sessions: [UUID: Session] = [:]
    private var anonymousSerial = 0

    func count(for id: UUID, now: Date = .now) -> Int {
        sessions[id]?.running.values.filter { now.timeIntervalSince($0) < Self.expiry }.count ?? 0
    }

    func isWaiting(for id: UUID, now: Date = .now) -> Bool {
        (sessions[id]?.mainTurnOver ?? false) && count(for: id, now: now) > 0
    }

    mutating func started(_ agentID: String?, in id: UUID, now: Date = .now) {
        prune(id, now: now)
        let key: String
        if let agentID, !agentID.isEmpty {
            key = agentID
        } else {
            anonymousSerial += 1
            key = "anonymous-\(anonymousSerial)"
        }
        sessions[id, default: Session()].running[key] = now
    }

    /// - Returns: true when this was the last one the main agent was waiting
    ///   on — the moment the session is really done.
    @discardableResult
    mutating func stopped(_ agentID: String?, in id: UUID, now: Date = .now) -> Bool {
        guard var session = sessions[id] else { return false }
        let wasWaiting = session.mainTurnOver && !session.running.isEmpty
        if let agentID, session.running[agentID] != nil {
            session.running[agentID] = nil
        } else if let anyKey = session.running.min(by: { $0.value < $1.value })?.key {
            // No id, or one we never saw start: retire the oldest, so the
            // count still comes down.
            session.running[anyKey] = nil
        }
        sessions[id] = session
        prune(id, now: now)
        let finished = wasWaiting && count(for: id, now: now) == 0
        if finished { sessions[id]?.mainTurnOver = false }
        return finished
    }

    /// The main agent's `Stop`. Returns whether sub-agents are still running,
    /// in which case the turn is not the end of the work.
    mutating func mainStopped(in id: UUID, now: Date = .now) -> Bool {
        prune(id, now: now)
        guard count(for: id, now: now) > 0 else {
            sessions[id]?.mainTurnOver = false
            return false
        }
        sessions[id]?.mainTurnOver = true
        return true
    }

    /// A new prompt: the main agent is working again, whatever is left over.
    mutating func mainResumed(in id: UUID) {
        sessions[id]?.mainTurnOver = false
    }

    /// Activity from inside a sub-agent keeps it from expiring.
    mutating func heard(in id: UUID, now: Date = .now) {
        guard var session = sessions[id], !session.running.isEmpty else { return }
        for key in session.running.keys { session.running[key] = now }
        sessions[id] = session
    }

    mutating func reset(_ id: UUID) {
        sessions[id] = nil
    }

    private mutating func prune(_ id: UUID, now: Date) {
        guard var session = sessions[id] else { return }
        session.running = session.running.filter { now.timeIntervalSince($0.value) < Self.expiry }
        sessions[id] = session
    }
}
