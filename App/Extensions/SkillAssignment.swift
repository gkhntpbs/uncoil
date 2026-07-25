import Foundation

/// Resolves whether an extension is active for a given agent and project.
///
/// Two independent axes:
/// - **agent**: an `AgentBinding` must exist and be enabled. No binding for an
///   agent means the extension is simply not assigned there.
/// - **project**: with no project bindings the extension is global; once any
///   exist, an enabled binding has to match the project (or be the global one).
///
/// A project binding may also name an agent, which is how "this skill, but only
/// for Codex in this project" is expressed.
enum SkillAssignment {
    struct Scope: Equatable {
        var extensionID: String
        var agent: ExtensionAgentID
        var projectID: UUID?
    }

    static func isActive(
        _ scope: Scope,
        agentBindings: [AgentBinding],
        projectBindings: [ProjectBinding]
    ) -> Bool {
        guard let agentBinding = agentBindings.first(where: {
            $0.extensionID == scope.extensionID && $0.agent == scope.agent
        }), agentBinding.isEnabled else { return false }

        let relevant = projectBindings.filter { $0.extensionID == scope.extensionID }
        guard !relevant.isEmpty else { return true }

        // A binding naming another agent says nothing about this one.
        let applicable = relevant.filter { $0.agent == nil || $0.agent == scope.agent }
        guard !applicable.isEmpty else { return true }

        // The most specific match wins: project-scoped over global.
        if let scoped = applicable.first(where: { $0.projectID == scope.projectID && $0.projectID != nil }) {
            return scoped.isEnabled
        }
        if let global = applicable.first(where: \.isGlobal) {
            return global.isEnabled
        }
        // Only other projects are named, so this one is out of scope.
        return false
    }

    /// Every agent an extension is currently linked into — the answer to "where
    /// is this active?" on one screen.
    static func activeAgents(
        extensionID: String,
        agentBindings: [AgentBinding]
    ) -> [ExtensionAgentID] {
        agentBindings
            .filter { $0.extensionID == extensionID && $0.isEnabled }
            .map(\.agent)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Assignments that contradict each other: the same extension enabled and
    /// disabled for the same (project, agent) pair.
    static func conflicts(_ projectBindings: [ProjectBinding]) -> [ProjectBinding] {
        var seen: [String: ProjectBinding] = [:]
        var conflicting: [ProjectBinding] = []
        for binding in projectBindings {
            let key = "\(binding.extensionID)|\(binding.projectID?.uuidString ?? "global")|\(binding.agent?.rawValue ?? "any")"
            if let existing = seen[key] {
                if existing.isEnabled != binding.isEnabled {
                    conflicting.append(existing)
                    conflicting.append(binding)
                }
            } else {
                seen[key] = binding
            }
        }
        return conflicting
    }

    /// Turning an extension off for one agent must never affect another, so
    /// this only ever rewrites the binding it was asked about.
    static func setting(
        _ isEnabled: Bool,
        extensionID: String,
        agent: ExtensionAgentID,
        in bindings: [AgentBinding]
    ) -> [AgentBinding] {
        var result = bindings
        if let index = result.firstIndex(where: {
            $0.extensionID == extensionID && $0.agent == agent
        }) {
            result[index].isEnabled = isEnabled
        } else {
            result.append(AgentBinding(extensionID: extensionID, agent: agent, isEnabled: isEnabled))
        }
        return result
    }

    /// Removes an extension from one agent. The central copy is untouched —
    /// that is a store operation, not an assignment one.
    static func removing(
        extensionID: String,
        agent: ExtensionAgentID,
        from bindings: [AgentBinding]
    ) -> [AgentBinding] {
        bindings.filter { !($0.extensionID == extensionID && $0.agent == agent) }
    }
}
