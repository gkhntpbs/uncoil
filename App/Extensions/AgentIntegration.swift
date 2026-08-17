import Foundation

/// How deeply Uncoil can talk to a given agent.
///
/// The levels are ordered, and the order is the point: an agent is reported at
/// the best level it actually supports, never at the level we wish it had.
/// Claude Code has a hook system; Codex does not, and no amount of UI copy
/// changes that. Saying so plainly is better than a row that claims
/// "connected" and silently means "we launched the binary".
enum AgentIntegrationLevel: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Uncoil never launched it and cannot see anything. Detected only.
    case none = 0
    /// Uncoil launches it in a terminal and reads what the terminal shows.
    /// No structured events: state is inferred, and inference can be wrong.
    case observed = 1
    /// The agent loads Uncoil's MCP control plane, so it can call back in.
    /// One direction: Uncoil answers the agent, the agent does not report.
    case controlPlane = 2
    /// The agent emits lifecycle events into Uncoil's hook socket. Session
    /// state is reported rather than guessed.
    case hooks = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .none: "Detected only"
        case .observed: "Terminal only"
        case .controlPlane: "Control plane"
        case .hooks: "Live events"
        }
    }

    /// One sentence the UI can show without the user having to know what a hook
    /// is. Written to be honest about the limitation, not to sell the level.
    var explanation: String {
        switch self {
        case .none:
            "Uncoil found this agent but has no way to work with it yet."
        case .observed:
            "Uncoil can run this agent and read its terminal, but the agent sends no events back — status is inferred from the output."
        case .controlPlane:
            "This agent can load Uncoil's MCP tools, so it can ask Uncoil for projects, sessions and tasks. It still reports no lifecycle events."
        case .hooks:
            "This agent reports session events to Uncoil directly, so status is read rather than guessed."
        }
    }
}

/// What an agent is *capable* of, independent of what is currently wired up.
///
/// Declared per agent rather than probed, because the answer is a property of
/// the agent's design and not of the machine: Codex will not grow a hook system
/// because we scanned harder.
struct AgentIntegrationSupport: Equatable, Sendable {
    /// Best level this agent can reach.
    var ceiling: AgentIntegrationLevel
    /// True when Uncoil can reach the ceiling on its own, without the user
    /// editing anything by hand.
    var isAutomatic: Bool
    /// Why the ceiling is where it is — shown when it is below `.hooks`, so a
    /// user asking "why is Codex worse than Claude?" gets an answer.
    var ceilingReason: String?

    /// The table mirrors what the rest of the app actually does — notably
    /// `AgentProvider.wiresControlPlane`, which is why Codex reaches
    /// `.controlPlane` on its own and Gemini does not.
    static func forAgent(_ agent: ExtensionAgentID) -> Self {
        switch agent {
        case .claudeCode:
            Self(
                ceiling: .hooks,
                isAutomatic: true,
                ceilingReason: nil
            )
        case .codex:
            // Uncoil registers its MCP server per session with
            // `-c mcp_servers.uncoil.*`, so this needs no setup — but Codex has
            // no hook system, so it stops one level short of Claude Code.
            Self(
                ceiling: .controlPlane,
                isAutomatic: true,
                ceilingReason: "Codex has no hook system, so it cannot report session events. Uncoil reads its terminal instead."
            )
        case .geminiCLI:
            // No verified per-session MCP registration for Gemini yet, so
            // handing it the control socket would advertise tools that are not
            // served. Terminal output is all Uncoil honestly has.
            Self(
                ceiling: .observed,
                isAutomatic: true,
                ceilingReason: "Gemini CLI has neither a hook system nor a per-session way to load Uncoil's tools, so Uncoil only reads its terminal."
            )
        case .opencode:
            // Uncoil launches OpenCode and merges its MCP server into the
            // session through OPENCODE_CONFIG_CONTENT, so this needs no setup.
            // No hook system, so it stops one level short of Claude Code.
            Self(
                ceiling: .controlPlane,
                isAutomatic: true,
                ceilingReason: "OpenCode has no hook system, so it cannot report session events. Uncoil reads its terminal instead."
            )
        case .cursor:
            // Uncoil launches `cursor-agent` and manages ~/.cursor/mcp.json,
            // but Cursor has no hook system and no per-session way to load
            // Uncoil's tools: `CURSOR_CONFIG_DIR` moves the credentials with
            // the config, so a per-session root would start logged out.
            Self(
                ceiling: .observed,
                isAutomatic: true,
                ceilingReason: "Cursor has neither a hook system nor a per-session way to load Uncoil's tools, so Uncoil only reads its terminal."
            )
        case .amp:
            // Uncoil never launches Amp, so there is no session to wire and no
            // terminal to read. The only shared surface is the config file,
            // and writing to it is a change the user reviews first.
            Self(
                ceiling: .controlPlane,
                isAutomatic: false,
                ceilingReason: "Uncoil does not launch this agent, so there is no session to observe. Its MCP configuration can still be shared."
            )
        case .grok:
            // Uncoil launches Grok and manages its config, but Grok has no
            // hook system and no per-session way to load Uncoil's tools: its
            // MCP servers live only in config.toml, where a session id would
            // be the same stale value for every session. Terminal output is
            // what Uncoil honestly has.
            Self(
                ceiling: .observed,
                isAutomatic: true,
                ceilingReason: "Grok has neither a hook system nor a per-session way to load Uncoil's tools, so Uncoil only reads its terminal."
            )
        }
    }
}

/// One agent's discovered state: is it here, how deep can we go, how deep are
/// we right now, and what — if anything — is there to do about it.
struct AgentIntegrationState: Identifiable, Equatable {
    let agent: ExtensionAgentID
    /// nil when the agent is not installed on this machine.
    var installation: AgentInstallation?
    var support: AgentIntegrationSupport
    /// Level actually in effect right now.
    var active: AgentIntegrationLevel
    /// Set when the ceiling is reachable automatically but is not in effect —
    /// what `AgentHookupService` would do if asked.
    var pendingAction: Action?

    var id: String { agent.rawValue }

    var isInstalled: Bool { installation != nil }

    /// True when the agent is at the best level it can reach — and that level
    /// is worth reaching. A ceiling of "detected only" never counts as wired:
    /// being at it means nothing is connected, not that everything is.
    var isFullyWired: Bool {
        isInstalled && active >= support.ceiling && support.ceiling > .none
    }

    /// One sentence for the row: the pending action's cost, the ceiling's
    /// reason, or the level's own explanation — in that order. Shared by the
    /// Extensions card and the Settings page so the two never drift apart.
    var statusDetail: String {
        guard isInstalled else {
            return String(localized: "Not found in any of the usual install locations.")
        }
        if let pendingAction { return pendingAction.detail }
        // The ceiling's reason wins whenever there is one, not only at the
        // ceiling. Amp is the case that made this wrong: Uncoil never launches
        // it, so its active level is `.none`, and the row read "Uncoil found
        // this agent but has no way to work with it yet" — directly
        // contradicting the reason on file, which says Uncoil does manage its
        // MCP configuration. The sentence that explains the limit is the one
        // worth showing.
        if let reason = support.ceilingReason { return reason }
        return active.explanation
    }

    enum Action: Equatable {
        /// No Uncoil hooks in the agent's settings yet.
        case installHooks
        /// Hooks are there but some events are missing — a partial install.
        case completeHooks(missing: [String])
        /// Hooks point at a helper path that no longer exists (app moved or was
        /// rebuilt elsewhere). Left alone, every tool call logs a hook failure.
        case repairHooks

        var label: String {
            switch self {
            case .installHooks: "Connect"
            case .completeHooks: "Complete setup"
            case .repairHooks: "Repair"
            }
        }

        var detail: String {
            switch self {
            case .installHooks:
                "Add Uncoil's event hooks to this agent's settings, after backing the file up."
            case .completeHooks(let missing):
                "\(missing.count) of Uncoil's hooks are missing from this agent's settings."
            case .repairHooks:
                "This agent's hooks point at an Uncoil helper that is no longer there."
            }
        }
    }

    /// Derives the state for a hook-capable agent from what was found on disk.
    ///
    /// Pure, so the whole decision table is unit-testable without a real
    /// `~/.claude/settings.json`.
    static func forHookCapableAgent(
        _ agent: ExtensionAgentID,
        installation: AgentInstallation?,
        hookStatus: HookInstaller.Status,
        hasStaleCommands: Bool
    ) -> Self {
        // Derived from the agent, never passed in: a caller who could hand
        // Codex Claude Code's support table would render a hook offer for an
        // agent that has no hook system.
        let support = AgentIntegrationSupport.forAgent(agent)
        guard installation != nil else {
            return Self(
                agent: agent,
                installation: nil,
                support: support,
                active: .none,
                pendingAction: nil
            )
        }
        // A stale path outranks everything else: the hooks look installed and
        // fire on every tool call, but the helper they name is gone, so the
        // agent logs a failure each time. Repair before anything else.
        if hasStaleCommands {
            return Self(
                agent: agent,
                installation: installation,
                support: support,
                active: .observed,
                pendingAction: .repairHooks
            )
        }
        switch hookStatus {
        case .installed:
            return Self(
                agent: agent,
                installation: installation,
                support: support,
                active: .hooks,
                pendingAction: nil
            )
        case .partiallyInstalled(let missing):
            return Self(
                agent: agent,
                installation: installation,
                support: support,
                active: .observed,
                pendingAction: .completeHooks(missing: missing)
            )
        case .notInstalled:
            return Self(
                agent: agent,
                installation: installation,
                support: support,
                active: .observed,
                pendingAction: .installHooks
            )
        }
    }

    /// Derives the state for an agent with no hook system.
    ///
    /// `active` is the honest floor. `.controlPlane` is claimed on two grounds
    /// and no others: Uncoil registers its MCP server for this provider on
    /// every session it launches (`AgentProvider.wiresControlPlane`), or the
    /// agent's own config already names that server. `.observed` needs only
    /// that Uncoil can launch the agent at all; an agent it never launches and
    /// whose config does not mention Uncoil is `.none`, however installed it is.
    static func forHooklessAgent(
        _ agent: ExtensionAgentID,
        installation: AgentInstallation?,
        hasUncoilMCPServer: Bool
    ) -> Self {
        let support = AgentIntegrationSupport.forAgent(agent)
        guard installation != nil else {
            return Self(
                agent: agent,
                installation: nil,
                support: support,
                active: .none,
                pendingAction: nil
            )
        }
        let provider = agent.provider
        let wiresPerSession = provider?.wiresControlPlane ?? false
        let unclamped: AgentIntegrationLevel =
            if wiresPerSession || hasUncoilMCPServer { .controlPlane }
            else if provider != nil { .observed }
            else { .none }
        // Never above the ceiling: a Gemini config can name Uncoil's MCP
        // server, but nothing serves that session, so claiming the level would
        // advertise tools that only answer "control plane unavailable".
        let active = min(unclamped, support.ceiling)
        return Self(
            agent: agent,
            installation: installation,
            support: support,
            active: active,
            // Registering an MCP server rewrites the user's config, so it is
            // offered on the Extensions screen as a reviewable change rather
            // than performed here behind their back.
            pendingAction: nil
        )
    }
}
