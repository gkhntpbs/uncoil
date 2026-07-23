import Foundation

/// The caller-relative relationship of a target session.
enum SessionRelation: String, Codable {
    case current = "self"
    case parent
    case child
    case ancestor
    case descendant
    case sibling
    case unrelated
}

struct PolicyDecision {
    let allowed: Bool
    let code: ControlErrorCode?
    let message: String?

    static let allow = PolicyDecision(allowed: true, code: nil, message: nil)
    static func deny(_ code: ControlErrorCode, _ message: String) -> PolicyDecision {
        PolicyDecision(allowed: false, code: code, message: message)
    }
}

/// Pure, socket-free capability policy so it is fully unit-testable: every
/// method takes plain records and a lookup map.
enum PolicyEngine {
    /// Grants every session has unless its record overrides `capabilities`.
    static let defaultGrants: Set<String> = [
        "projects.read", "worktrees.read", "sessions.read",
        "artifacts.read", "artifacts.write",
    ]

    /// Opt-in grants that are OFF by default; a session must explicitly list
    /// them in `capabilities`. Browser/computer control (Milestones 3+4) plus
    /// the earlier control grants live here for discoverability.
    static let optionalGrants: Set<String> = [
        "sessions.read_all", "sessions.control_children", "worktrees.create",
        "browser.use", "browser.persistent_state",
        "computer.inspect", "computer.background_control", "computer.foreground_control",
    ]

    static func grants(for record: SessionRecord) -> Set<String> {
        if let caps = record.capabilities { return Set(caps) }
        return defaultGrants
    }

    // MARK: - Relationship calculator

    /// Ancestor session ids of `record`, nearest first, guarding against cycles.
    static func ancestors(of record: SessionRecord, in all: [UUID: SessionRecord]) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = [record.id]
        var current = record.parentSessionID
        while let id = current, !seen.contains(id), let parent = all[id] {
            result.append(id)
            seen.insert(id)
            current = parent.parentSessionID
        }
        return result
    }

    static func relation(
        of target: SessionRecord,
        to caller: SessionRecord,
        in all: [UUID: SessionRecord]
    ) -> SessionRelation {
        if target.id == caller.id { return .current }
        if target.parentSessionID == caller.id { return .child }
        if caller.parentSessionID == target.id { return .parent }
        if ancestors(of: caller, in: all).contains(target.id) { return .ancestor }
        if ancestors(of: target, in: all).contains(caller.id) { return .descendant }
        if let callerParent = caller.parentSessionID,
           callerParent == target.parentSessionID { return .sibling }
        return .unrelated
    }

    // MARK: - Decisions

    static func canRead(
        target: SessionRecord, caller: SessionRecord,
        relation: SessionRelation, grants: Set<String>
    ) -> PolicyDecision {
        if relation == .current { return .allow }
        if target.projectID == caller.projectID {
            return grants.contains("sessions.read")
                ? .allow
                : .deny(.capabilityDisabled, "sessions.read is not granted")
        }
        return grants.contains("sessions.read_all")
            ? .allow
            : .deny(.permissionDenied, "cross-project read is denied by default")
    }

    static func canControl(relation: SessionRelation, grants: Set<String>) -> PolicyDecision {
        if relation == .current {
            return .deny(.invalidRelationship, "a session cannot control itself")
        }
        guard grants.contains("sessions.control_children") else {
            return .deny(.capabilityDisabled, "sessions.control_children is not granted")
        }
        return relation == .child
            ? .allow
            : .deny(.permissionDenied, "only direct children can be controlled")
    }

    static func canClose(relation: SessionRelation, grants: Set<String>) -> PolicyDecision {
        if relation == .current { return .allow }
        guard grants.contains("sessions.control_children") else {
            return .deny(.capabilityDisabled, "sessions.control_children is not granted")
        }
        return relation == .child
            ? .allow
            : .deny(.permissionDenied, "cannot close an unrelated session")
    }

    /// Child creation arrives in a later milestone.
    static func canCreateChild(relation: SessionRelation, grants: Set<String>) -> PolicyDecision {
        .deny(.invalidAction, "create_child is not available yet")
    }
}
