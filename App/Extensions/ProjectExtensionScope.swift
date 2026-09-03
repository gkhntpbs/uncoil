import Foundation

/// What one project lets one agent load: the MCP servers and skills a session
/// started in that project may see, out of everything the agent's own config
/// declares.
///
/// The point is context, not security. An agent handed twenty MCP servers and
/// thirty skills pays for all of them in its context window before it reads a
/// line of the user's code, and most of them have nothing to do with the
/// project in front of it. A project says which ones are its own; a session
/// launched there gets those and no others.
///
/// Two rules the type keeps:
/// - **No record means allowed.** A project that has never been configured
///   behaves exactly as it did before this existed, and an extension installed
///   tomorrow reaches every project that has not explicitly refused it.
/// - **`uncoil` is never excluded.** It is how the agent reaches the app at
///   all; dropping it would take away the control plane along with the noise.
///
/// The type carries decisions — names — and never a rebuilt server definition.
/// See `filteredMCPServers` for why that distinction is load-bearing.
struct ProjectExtensionScope: Equatable {
    /// One skill the agent can see, with this project's verdict. The allowed
    /// ones are kept as well as the refused, because the picker has to show
    /// what a project *could* turn off, not only what it already did.
    struct SkillDecision: Equatable {
        var name: String
        /// Absolute path of the skill's `SKILL.md`, which is how Codex's
        /// `skills.config` addresses it.
        var path: String
        var isEnabled: Bool
    }

    /// Servers the project allows, in the order the agent's config declares
    /// them. `uncoil` is not in here — the launcher adds it separately, and it
    /// is not the project's to remove.
    var allowedMCPNames: [String] = []
    /// Servers the agent declares and the project refuses.
    var excludedMCPNames: [String] = []
    /// Every skill the agent can see, allowed and refused alike.
    var skills: [SkillDecision] = []

    var allowedSkillNames: [String] { skills.filter(\.isEnabled).map(\.name) }
    var excludedSkillNames: [String] { skills.filter { !$0.isEnabled }.map(\.name) }

    /// True when the project takes nothing away. The launcher uses this to stay
    /// out of the command line entirely: a project that excludes nothing must
    /// produce byte-for-byte the command it produced before.
    var isUnrestricted: Bool {
        excludedMCPNames.isEmpty && excludedSkillNames.isEmpty
    }

    /// The scope of a project that has never been configured.
    static let unrestricted = ProjectExtensionScope()

    // MARK: - Resolution

    /// Reads one agent's live configuration through the project's records.
    ///
    /// `packages` is what `ExtensionRegistry.discover()` produced from these
    /// same configurations, and it is the only place a server's or skill's
    /// *binding id* can be recovered from its name — bindings are keyed by
    /// package id, while an agent config knows only names.
    static func resolve(
        configuration: AgentConfiguration,
        packages: [ExtensionPackage],
        projectBindings: [ProjectBinding],
        projectID: UUID
    ) -> ProjectExtensionScope {
        let agent = configuration.installation.agent
        var scope = ProjectExtensionScope()

        for server in configuration.mcpServers where server.name != ControlPlaneMCPName {
            let id = packageID(name: server.name, kind: .mcpServer, agent: agent, in: packages)
            if allows(
                extensionID: id, projectID: projectID,
                agent: agent, projectBindings: projectBindings
            ) {
                scope.allowedMCPNames.append(server.name)
            } else {
                scope.excludedMCPNames.append(server.name)
            }
        }

        // Without a skills directory there is no path to hand Codex, and a
        // decision that cannot be expressed is not worth carrying.
        if let skillsRoot = configuration.installation.skillsDirectory {
            let root = URL(fileURLWithPath: skillsRoot)
            for name in configuration.skillNames {
                let id = packageID(name: name, kind: .skill, agent: agent, in: packages)
                scope.skills.append(SkillDecision(
                    name: name,
                    path: root.appendingPathComponent(name, isDirectory: true)
                        .appendingPathComponent("SKILL.md").path,
                    isEnabled: allows(
                        extensionID: id, projectID: projectID,
                        agent: agent, projectBindings: projectBindings
                    )
                ))
            }
        }

        return scope
    }

    /// Whether this project allows one extension.
    ///
    /// This reads `ProjectBinding` records as a **deny**-list: a project allows
    /// everything it has not explicitly refused. `SkillAssignment.isActive`
    /// reads the very same records as an **allow**-list — there, naming a
    /// project is how "this extension belongs to that project, and nowhere
    /// else" is said, and an unnamed project gets nothing.
    ///
    /// The two are not a contradiction to reconcile; they answer different
    /// questions, and sharing an implementation would break one of them. The
    /// assignment matrix hands out an extension to chosen projects. This asks
    /// what a session may load, and the answer has to be "everything, minus
    /// what this project turned off" — otherwise switching one server off in
    /// one project would switch it off in every project that had never been
    /// configured, which is every other project by default.
    static func allows(
        extensionID: String,
        projectID: UUID,
        agent: ExtensionAgentID,
        projectBindings: [ProjectBinding]
    ) -> Bool {
        let relevant = projectBindings.filter { $0.extensionID == extensionID }
        // Four records can speak to one launch, so they are ranked rather than
        // searched. Naming this agent beats saying nothing about agents, and
        // naming this project beats saying nothing about projects.
        //
        // A single `first(where:)` over a mixed list would answer with whichever
        // record the store happened to hold first, so "off for Codex in this
        // project" and "on everywhere" would trade places between launches for
        // no reason the user could see.
        let ranked: [(project: UUID?, agent: ExtensionAgentID?)] = [
            (projectID, agent),
            (projectID, nil),
            (nil, agent),
            (nil, nil),
        ]
        for want in ranked {
            if let match = relevant.first(where: {
                $0.projectID == want.project && $0.agent == want.agent
            }) {
                return match.isEnabled
            }
        }
        // Only other projects are named, and what they refused is their own
        // business.
        return true
    }

    /// The binding id for an extension the agent knows only by name.
    ///
    /// `discover()` ids an unmanaged entry as `<agent>:<name>` for a server and
    /// `local:<name>` for a skill, while anything Uncoil installed keeps its own
    /// id. Matching on kind and name and preferring the agent-qualified id
    /// covers all three without re-deriving discovery's rule here — two agents
    /// may each declare a server called `figma`, and this project may well have
    /// something to say about only one of them.
    ///
    /// The name itself is the fallback: a package that vanished between the last
    /// discovery pass and this launch still resolves to a stable key, so its
    /// records keep applying instead of silently reverting to "allowed".
    static func packageID(
        name: String,
        kind: ExtensionKind,
        agent: ExtensionAgentID,
        in packages: [ExtensionPackage]
    ) -> String {
        let candidates = packages.filter { $0.kind == kind && $0.name == name }
        if let qualified = candidates.first(where: { $0.id == "\(agent.rawValue):\(name)" }) {
            return qualified.id
        }
        return candidates.first?.id ?? "\(agent.rawValue):\(name)"
    }

    // MARK: - Rendering an allow-list

    /// The allowed servers as their agent's own config declares them, copied
    /// verbatim out of the raw JSON.
    ///
    /// Copying rather than re-serialising a parsed `MCPServerDefinition` is not
    /// a shortcut, it is the only correct move: reading a config deliberately
    /// throws away secret environment **values**
    /// (`AgentAdapterSupport.partitionEnvironment`), keeping only the variable
    /// names, because a value belongs in the Keychain and never in a diff. A
    /// server rebuilt from its parsed definition would therefore start without
    /// its credentials — and under `--strict-mcp-config` that broken copy is
    /// the only one the session would get.
    ///
    /// Only Claude Code needs this. Codex and OpenCode are told what to switch
    /// *off*, which leaves their own entries untouched and never re-states a
    /// secret.
    static func filteredMCPServers(
        rawConfig: String,
        allowing names: [String]
    ) -> [String: Any] {
        guard !rawConfig.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: Data(rawConfig.utf8)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [:] }
        let allowed = Set(names)
        return servers.filter { allowed.contains($0.key) }
    }
}

/// The name Uncoil registers its own control-plane server under. It is excluded
/// from every project decision, so no selection can cut the session off from
/// the app that started it.
let ControlPlaneMCPName = "uncoil"
