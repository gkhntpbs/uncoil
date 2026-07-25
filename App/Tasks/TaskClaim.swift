import Foundation

/// Where a task stands from the claim system's point of view.
///
/// Distinct from `ProjectTaskExecutionState`, which describes what an assigned
/// agent is doing: this describes whether the task is *takeable*.
enum TaskClaimState: String, Equatable, Codable, CaseIterable, Identifiable {
    case available
    case claimed
    case running
    case released
    case expired
    case blocked
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: "Alınabilir"
        case .claimed: "Alındı"
        case .running: "Çalışıyor"
        case .released: "Bırakıldı"
        case .expired: "Süresi doldu"
        case .blocked: "Bloklandı"
        case .completed: "Tamamlandı"
        }
    }

    /// States another implementer may take the task from.
    var isTakeable: Bool {
        switch self {
        case .available, .released, .expired: true
        case .claimed, .running, .blocked, .completed: false
        }
    }
}

/// Claim rules: who may hold a task, and what a second agent is allowed to do.
///
/// Only one implementer works a task at a time. A reviewer, a tester and an
/// orchestrator attach alongside it — they have their own jobs and would be
/// pointless if the implementer's claim excluded them. An observer never claims
/// anything at all, and an orchestrator manages the task without owning the
/// implementation.
enum TaskClaimPolicy {
    /// Roles whose work conflicts with each other on one task.
    static let exclusiveRoles: Set<TaskAgentRole> = [.implementer]

    /// Roles that take a lease at all.
    static func claims(_ role: TaskAgentRole) -> Bool {
        switch role {
        case .implementer, .tester: true
        // An observer only watches; an owner and an orchestrator coordinate.
        case .observer, .owner, .orchestrator, .reviewer: false
        }
    }

    /// Whether `role` may claim while `existing` holds a live lease.
    static func mayClaim(
        role: TaskAgentRole,
        whileHeldBy existing: TaskAgentRole?,
        sameSession: Bool
    ) -> Bool {
        guard claims(role) else { return false }
        guard let existing else { return true }
        if sameSession { return true }
        // Two implementers on one task is the case the whole system exists to
        // prevent; anything else coexists.
        return !(exclusiveRoles.contains(role) && exclusiveRoles.contains(existing))
    }

    /// Why a claim was refused, for a message the agent can act on.
    static func refusal(
        role: TaskAgentRole,
        heldBy existing: TaskAgentRole
    ) -> String {
        guard claims(role) else {
            return "\(role.label) rolü claim almaz; atama yeterli."
        }
        return "Görev \(existing.label) tarafından tutuluyor."
    }

    /// The claim state of a task, from its lease and what its agents report.
    static func state(
        lease: TaskClaimLease?,
        executionStates: [ProjectTaskExecutionState],
        checkboxDone: Bool,
        now: Date = .now
    ) -> TaskClaimState {
        if checkboxDone || executionStates.contains(.completed) { return .completed }
        if executionStates.contains(.blocked) || executionStates.contains(.failed) {
            return .blocked
        }
        guard let lease else {
            // No lease: either never taken, or given back.
            return executionStates.isEmpty ? .available : .released
        }
        if lease.isExpired(at: now) { return .expired }
        if executionStates.contains(where: { $0 == .running || $0 == .agentStarting }) {
            return .running
        }
        return .claimed
    }
}

/// How a heartbeat keeps a lease alive, and what happens when it stops.
///
/// The lease is deliberately short and renewed: an agent that crashes, is killed
/// or loses its session stops sending heartbeats, and the task becomes takeable
/// again on its own rather than staying locked forever.
struct TaskLeaseKeeper: Equatable {
    /// A heartbeat is expected at least this often.
    var heartbeatInterval: TimeInterval = 60
    /// Lease length granted on each heartbeat.
    var leaseDuration: TimeInterval = 15 * 60

    /// Whether a lease should be considered dead: expired outright, or silent
    /// for more than a few missed heartbeats.
    func isStale(_ lease: TaskClaimLease, lastHeartbeat: Date, now: Date = .now) -> Bool {
        if lease.isExpired(at: now) { return true }
        return now.timeIntervalSince(lastHeartbeat) > heartbeatInterval * 3
    }

    func renewed(_ lease: TaskClaimLease, now: Date = .now) -> TaskClaimLease {
        TaskClaimLease(
            id: lease.id,
            taskID: lease.taskID,
            sourcePath: lease.sourcePath,
            sessionID: lease.sessionID,
            acquiredAt: now,
            duration: leaseDuration,
            generation: lease.generation + 1
        )
    }
}
