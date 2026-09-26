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
        // A blueprint is a prompt that a later session gets handed. A session
        // able to write one silently could leave instructions behind for a
        // session that has not started yet, so the grant belongs to the one
        // session the user opened in order to write blueprints — not to every
        // agent that happens to be running.
        "blueprints.write",
        // Answering another session's approval is deciding, on the user's
        // behalf, that a command may run or a file may change. An agent that
        // can do that for any session it controls can approve its own work by
        // way of a child, so it is granted deliberately — or asked for, per
        // target, through the user.
        "sessions.approve",
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

    // MARK: - Effects

    /// Everything a call can *do* to a session, as opposed to reading it.
    ///
    /// Every handler that acts asks `authorize` with one of these, so what
    /// "may this caller interrupt that session" means is decided here once, not
    /// re-derived in each action. The raw values are stable: they are what the
    /// audit log and `describe` report.
    enum Effect: String, CaseIterable {
        case read
        /// Input that starts or steers work: submit, send_text, send_raw.
        case control
        case interrupt
        case respondToApproval = "respond_to_approval"
        case createSession = "create_session"
        case resume
        case close
    }

    enum EffectDecision: Equatable {
        case allow
        case deny(ControlErrorCode, String)
        /// Policy says no, but the user may say yes for this caller → target
        /// under this grant key (`PermissionService`).
        case requiresPermission(String)
    }

    /// The one answer to "may this caller cause this effect on this target".
    ///
    /// Pure: identity has already been established (`ControlCallContext`), and
    /// the user's directional permissions are consulted by the caller of this
    /// only when the answer is `requiresPermission`.
    static func authorize(
        _ effect: Effect,
        caller: SessionRecord,
        target: SessionRecord?,
        grants: Set<String>,
        in all: [UUID: SessionRecord]
    ) -> EffectDecision {
        if effect == .createSession {
            let decision = canCreateChild(grants: grants)
            return decision.allowed ? .allow : .deny(decision.code ?? .capabilityDisabled, decision.message ?? "")
        }
        guard let target else { return .deny(.unknownSession, "session not found") }
        let relation = self.relation(of: target, to: caller, in: all)
        switch effect {
        case .read:
            let decision = canRead(target: target, caller: caller, relation: relation, grants: grants)
            return decision.allowed ? .allow : .deny(decision.code ?? .permissionDenied, decision.message ?? "")
        case .close:
            let decision = canClose(relation: relation, grants: grants)
            if decision.allowed { return .allow }
            return decision.code == .permissionDenied
                ? .requiresPermission("sessions.close")
                : .deny(decision.code ?? .permissionDenied, decision.message ?? "")
        case .control, .interrupt, .resume, .respondToApproval:
            let decision = canControl(relation: relation, grants: grants)
            if !decision.allowed {
                // A missing grant is the session's configuration and final; a
                // relationship policy does not cover is the user's to lift.
                return decision.code == .permissionDenied
                    ? .requiresPermission("sessions.control")
                    : .deny(decision.code ?? .permissionDenied, decision.message ?? "")
            }
            if effect == .respondToApproval, !grants.contains("sessions.approve") {
                return .requiresPermission("sessions.approve")
            }
            return .allow
        case .createSession:
            return .allow
        }
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
