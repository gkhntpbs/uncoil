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
        "projects.read", "worktrees.read", "worktrees.create",
        "sessions.read", "sessions.read_all", "sessions.control_children",
        "sessions.control_all", "sessions.create_children", "sessions.cross_project",
        "sessions.organize",
        "artifacts.read", "artifacts.write",
        "browser.use", "browser.persistent_state",
        // Reading and editing the project's own TODO.md is ordinary work; the
        // destructive and orchestrating halves are opt-in below.
        "tasks.read", "tasks.write",
        // Detecting, editing and driving the project's own run configurations
        // is the core "verify my change actually launches" loop, so all three
        // are default-on; runs.control is still flagged risky in the catalog.
        "runs.read", "runs.write", "runs.control",
    ]

    /// Opt-in grants that are OFF by default; a session must explicitly list
    /// them in `capabilities`. Browser/computer control (Milestones 3+4) plus
    /// the earlier control grants live here for discoverability.
    static let optionalGrants: Set<String> = [
        "computer.inspect", "computer.background_control", "computer.foreground_control",
        // Deleting a task, spawning agents for it, cutting a worktree or asking
        // for a merge all need to be granted deliberately.
        "tasks.delete", "tasks.orchestrate", "tasks.worktree", "tasks.merge",
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
        if grants.contains("sessions.control_all") { return .allow }
        guard grants.contains("sessions.control_children") else {
            return .deny(.capabilityDisabled, "sessions.control_children is not granted")
        }
        return relation == .child
            ? .allow
            : .deny(.permissionDenied, "only direct children can be controlled")
    }

    static func canClose(relation: SessionRelation, grants: Set<String>) -> PolicyDecision {
        if relation == .current { return .allow }
        if grants.contains("sessions.control_all") { return .allow }
        guard grants.contains("sessions.control_children") else {
            return .deny(.capabilityDisabled, "sessions.control_children is not granted")
        }
        return relation == .child
            ? .allow
            : .deny(.permissionDenied, "cannot close an unrelated session")
    }

    /// A caller may spawn children when it holds `sessions.create_children`.
    static func canCreateChild(grants: Set<String>) -> PolicyDecision {
        grants.contains("sessions.create_children")
            ? .allow
            : .deny(.capabilityDisabled, "sessions.create_children is not granted")
    }

    /// Intersects a requested capability set with what the preset allows and
    /// what the caller itself holds, so a child can never escalate beyond both.
    /// `nil` requested ⇒ take the preset's full granted set (still intersected
    /// with the caller's grants).
    static func childCapabilities(
        requested: [String]?,
        preset: [String],
        callerGrants: Set<String>
    ) -> [String] {
        let base = requested.map(Set.init) ?? Set(preset)
        let allowed = base
            .intersection(Set(preset))
            .intersection(callerGrants)
        return allowed.sorted()
    }
}
