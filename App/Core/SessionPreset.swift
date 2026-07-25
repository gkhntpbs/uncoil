import Foundation

/// A reusable template describing how a child (or standalone) agent session
/// should be launched: which provider, extra CLI arguments, an optional
/// initial-prompt template, and the control-plane capabilities it may be
/// granted. Presets are the ONLY way `uncoil_sessions create_child` can spawn
/// work — raw shell commands are never accepted, so the set of grantable
/// capabilities is bounded by what a preset declares.
struct SessionPreset: Codable, Equatable, Identifiable {
    /// Stable slug (e.g. "claude-worker"). Used as the `preset_id`.
    let id: String
    var name: String
    var provider: AgentProvider
    var extraArguments: [String]
    var initialPromptTemplate: String?
    /// Capability grant keys this preset is allowed to hand to a child. The
    /// effective set is always intersected with the caller's own grants, so a
    /// preset can never escalate beyond what the caller already holds.
    var grantedCapabilities: [String]
    /// Permission mode label; reserved for future provider-specific mapping.
    var permissionMode: String

    init(
        id: String,
        name: String,
        provider: AgentProvider,
        extraArguments: [String] = [],
        initialPromptTemplate: String? = nil,
        grantedCapabilities: [String] = [],
        permissionMode: String = "standard"
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.extraArguments = extraArguments
        self.initialPromptTemplate = initialPromptTemplate
        self.grantedCapabilities = grantedCapabilities
        self.permissionMode = permissionMode
    }

    /// Built-in defaults used when the user has configured none. Both grant the
    /// default read set plus `sessions.read` so a child can inspect siblings in
    /// its own project; nothing more privileged is granted by default.
    static let builtInDefaults: [SessionPreset] = [
        SessionPreset(
            id: "claude-worker",
            name: "Claude Worker",
            provider: .claude,
            grantedCapabilities: Array(PolicyEngine.defaultGrants) + ["sessions.read"]
        ),
        SessionPreset(
            id: "codex-reviewer",
            name: "Codex Reviewer",
            provider: .codex,
            grantedCapabilities: Array(PolicyEngine.defaultGrants) + ["sessions.read"]
        ),
        // The orchestrator reads tasks, projects, sessions and worktrees, and
        // may spawn agents and cut worktrees for them. It deliberately does NOT
        // get `tasks.delete` or `tasks.merge`: destroying work and merging stay
        // with the user.
        SessionPreset(
            id: "task-orchestrator",
            name: "Task Orchestrator",
            provider: .claude,
            grantedCapabilities: Array(PolicyEngine.defaultGrants) + [
                "sessions.read", "tasks.orchestrate", "tasks.worktree",
            ]
        ),
    ]

    /// JSON payload for `list_presets` / `inspect_preset`.
    func asJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "provider": .string(provider.rawValue),
            "extra_arguments": .array(extraArguments.map(JSONValue.string)),
            "initial_prompt_template": .string(optional: initialPromptTemplate),
            "granted_capabilities": .array(grantedCapabilities.map(JSONValue.string)),
            "permission_mode": .string(permissionMode),
        ])
    }
}
