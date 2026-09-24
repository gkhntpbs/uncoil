import Foundation

// MARK: - Descriptor

/// Where a session's status comes from — read, not guessed, wherever possible.
///
/// Kept as one value rather than a pair of booleans because the three answers
/// are exclusive: an agent reports through Uncoil's hooks, or through its own
/// structured protocol, or not at all. The old shape asked
/// `reportsStatusThroughHooks` and left "and otherwise?" to each caller.
enum AgentStatusSource: String, Equatable, Sendable, Codable {
    /// The agent runs Uncoil's hook binary and posts lifecycle events to it.
    case hooks
    /// The agent speaks its own structured protocol (Codex's app server).
    case appServer
    /// Nothing structured: status is inferred from terminal output.
    case none
}

/// How Uncoil registers its MCP control plane for one session, if it can.
///
/// The mechanism differs per CLI and the difference is the whole answer to
/// "does this session get Uncoil's tools": a provider with no per-session
/// mechanism must not be handed the control socket, because the agent would
/// read the environment, find no tools, and report a broken socket rather than
/// a missing feature.
enum AgentControlPlaneWiring: String, Equatable, Sendable, Codable {
    /// A generated config file named on the command line (`--mcp-config`).
    case mcpConfigFile
    /// Config keys overridden on the command line (`-c mcp_servers.uncoil.*`).
    case cliOverride
    /// Inline config handed over in the environment (`OPENCODE_CONFIG_CONTENT`).
    case environment
    /// No per-session mechanism that does not write to the user's own config.
    case none

    var isWired: Bool { self != .none }
}

/// Everything Uncoil knows about one agent CLI, stated once.
///
/// Before this existed the same facts were re-stated across `AgentProvider`'s
/// computed properties, `ExtensionAgentID`, `AgentIntegration` and about thirty
/// files of `switch provider` — so "which agents are there" had three different
/// answers depending on which screen asked. A descriptor is the answer; views
/// and services read it instead of re-deciding.
///
/// Facts only. Anything that needs the main actor (a colour, a view) stays
/// where it can have it; anything probed from disk (a binary's real path, a
/// CLI's version) belongs to detection, not here.
struct AgentDescriptor: Equatable, Sendable, Identifiable {
    /// The persisted identity. Sessions on disk carry this, so it never changes.
    var provider: AgentProvider
    var id: AgentProvider { provider }

    /// Short name, used where space is tight ("Claude").
    var displayName: String
    /// The product's own full name ("Claude Code"), used in prose and settings.
    var fullName: String

    /// Executed (via `exec`) when a session starts; `nil` is a plain shell.
    var launchCommand: String?
    /// The provider's own sign-in flow, run inside a login terminal.
    var loginCommand: String?
    /// Looked up on the search path to decide whether the agent is installed.
    var cliBinaryName: String?
    /// The agent's documented config root, relative to home. Detection and
    /// display only; reading inside it is adapter work.
    var defaultConfigDirectory: String?

    /// Whether Uncoil runs an agent here, or just a shell.
    var isAgent: Bool
    var statusSource: AgentStatusSource
    var controlPlane: AgentControlPlaneWiring
    var extensionScoping: ExtensionScopingSupport
    /// The CLI updates itself through its own subcommand.
    var hasBuiltInUpdater: Bool
    /// Relaunching with a stored session id brings the conversation back — the
    /// same fact that decides whether a session may be hibernated.
    var resumesConversation: Bool
    /// Default for Shift+Enter inserting a literal newline.
    var defaultShiftEnterNewline: Bool
    /// What that newline is on the wire. Agents disagree: Claude Code and
    /// Gemini read backslash + CR; Codex and OpenCode take the backslash as
    /// text and the CR as "submit", but read a bare line feed (⌃J) as a newline.
    var newlineSequence: [UInt8] {
        switch provider {
        case .claude, .gemini: TerminalKeyTranslation.newlineSequence
        default: TerminalKeyTranslation.lineFeedNewline
        }
    }

    /// The agent's own approval levels, in the order it presents them.
    var workingModes: [AgentWorkingMode]
    /// The mode for a process Uncoil runs with nobody watching.
    var unattendedMode: AgentWorkingMode

    /// The Extensions system's id for the same agent, while the two enums
    /// still coexist. `nil` for the plain terminal, which has no config.
    var extensionAgentID: ExtensionAgentID?
}

// MARK: - Registry

/// The table. One entry per `AgentProvider`, checked by a test that fails if a
/// case is missing — so adding an agent is adding a row here, and the screens
/// that render agents follow by construction.
enum AgentRegistry {
    static let all: [AgentDescriptor] = AgentProvider.allCases.map(descriptor(for:))

    /// Descriptors for the agents Uncoil runs, in the order they are offered.
    static var agents: [AgentDescriptor] { all.filter(\.isAgent) }

    static func descriptor(for provider: AgentProvider) -> AgentDescriptor {
        switch provider {
        case .claude:
            AgentDescriptor(
                provider: .claude,
                displayName: "Claude",
                fullName: "Claude Code",
                launchCommand: "claude",
                loginCommand: "claude /login",
                cliBinaryName: "claude",
                defaultConfigDirectory: ".claude",
                isAgent: true,
                statusSource: .hooks,
                controlPlane: .mcpConfigFile,
                // Claude Code scopes MCP exactly — `--mcp-config` names the
                // servers and `--strict-mcp-config` ignores every other source
                // — but has no per-session skill selection.
                // `--setting-sources project,local` would drop the user's
                // skills, and with them the hooks Uncoil installs into
                // `~/.claude/settings.json`, so the session would go dark in
                // the UI to buy a shorter skill list.
                extensionScoping: .mcpOnly,
                hasBuiltInUpdater: true,
                resumesConversation: true,
                // Claude Code accepts backslash+CR for an in-prompt newline;
                // this is what `claude /terminal-setup` configures elsewhere.
                defaultShiftEnterNewline: true,
                workingModes: [
                    .providerDefault, .manual, .acceptEdits, .plan, .auto,
                    .dangerouslySkipPermissions,
                ],
                unattendedMode: .dangerouslySkipPermissions,
                extensionAgentID: .claudeCode
            )
        case .codex:
            AgentDescriptor(
                provider: .codex,
                displayName: "Codex",
                fullName: "Codex",
                launchCommand: "codex",
                loginCommand: "codex login",
                cliBinaryName: "codex",
                defaultConfigDirectory: ".codex",
                isAgent: true,
                // No hook system; Codex reports through its own app-server
                // events instead, which is a different wire but still read
                // rather than inferred.
                statusSource: .appServer,
                controlPlane: .cliOverride,
                // Codex answers both halves from its own config:
                // `mcp_servers.<name>` and each `[[skills.config]]` entry carry
                // an `enabled` flag, and `-c` overrides either without touching
                // `~/.codex/config.toml`.
                extensionScoping: .strict,
                hasBuiltInUpdater: false,
                resumesConversation: true,
                defaultShiftEnterNewline: true,
                // Codex's own two axes, in the pairs its `/approvals` screen
                // offers. `providerDefault` matters most: without it every
                // launch carried `--sandbox` and `--ask-for-approval`, so
                // whatever the user had set in `~/.codex/config.toml` was
                // overruled every time.
                workingModes: [
                    .providerDefault, .readOnly, .askForApproval, .approveForMe,
                    .fullAccess,
                ],
                unattendedMode: .fullAccess,
                extensionAgentID: .codex
            )
        case .gemini:
            AgentDescriptor(
                provider: .gemini,
                displayName: "Gemini",
                fullName: "Gemini CLI",
                launchCommand: "gemini",
                // The Gemini CLI runs its own sign-in on first start, and
                // Uncoil has no verified non-interactive command to drive it.
                // Offering a login terminal that types a guessed command would
                // be worse than not offering one.
                loginCommand: nil,
                cliBinaryName: "gemini",
                defaultConfigDirectory: ".gemini",
                isAgent: true,
                statusSource: .none,
                controlPlane: .none,
                extensionScoping: .none,
                hasBuiltInUpdater: false,
                // No verified resume flag, and guessing one is a launch failure
                // rather than a cosmetic bug.
                resumesConversation: false,
                // Unverified: backslash+CR is what Claude Code and the Codex
                // TUI document, and sending it to a prompt that does not
                // understand it would put a stray backslash in the message.
                defaultShiftEnterNewline: false,
                // No modes offered: the approval flags are not verified here,
                // and Uncoil adds no flag it was not asked for.
                workingModes: [.providerDefault],
                unattendedMode: .providerDefault,
                extensionAgentID: .geminiCLI
            )
        case .opencode:
            AgentDescriptor(
                provider: .opencode,
                displayName: "OpenCode",
                fullName: "OpenCode",
                launchCommand: "opencode",
                // Verified against the CLI's own help: `providers login` is the
                // documented sign-in, and it drives a browser flow.
                loginCommand: "opencode providers login",
                cliBinaryName: "opencode",
                defaultConfigDirectory: ".config/opencode",
                isAgent: true,
                statusSource: .none,
                // `opencode debug config` shows the inline content *merged*
                // over the user's own file, so the server arrives without any
                // write to `~/.config/opencode`.
                controlPlane: .environment,
                // `OPENCODE_CONFIG_CONTENT` scopes its servers, and it reads no
                // skills at all, so there is no second half to answer for.
                extensionScoping: .mcpOnly,
                hasBuiltInUpdater: true,
                // `--session <id>` is documented in its own `--help`.
                resumesConversation: true,
                defaultShiftEnterNewline: false,
                // `--auto` is documented in OpenCode's own `--help`.
                workingModes: [.providerDefault, .auto],
                unattendedMode: .auto,
                extensionAgentID: .opencode
            )
        case .grok:
            AgentDescriptor(
                provider: .grok,
                displayName: "Grok",
                fullName: "Grok CLI",
                launchCommand: "grok",
                loginCommand: "grok login",
                cliBinaryName: "grok",
                defaultConfigDirectory: ".grok",
                isAgent: true,
                statusSource: .none,
                // Grok registers MCP servers only in its own config.toml, and
                // the one entry Uncoil would write carries a session id — the
                // same stale id for every session. `GROK_HOME` redirects the
                // whole home, credentials included, rather than one file.
                controlPlane: .none,
                extensionScoping: .none,
                hasBuiltInUpdater: true,
                // Documents both `--resume <id>` and `--session-id`.
                resumesConversation: true,
                defaultShiftEnterNewline: false,
                // Read straight off `--permission-mode`'s own possible values.
                workingModes: [
                    .providerDefault, .plan, .acceptEdits, .auto, .dontAsk,
                    .dangerouslySkipPermissions,
                ],
                unattendedMode: .dangerouslySkipPermissions,
                extensionAgentID: .grok
            )
        case .hermes:
            AgentDescriptor(
                provider: .hermes,
                displayName: "Hermes",
                fullName: "Hermes",
                launchCommand: "hermes",
                // `hermes login` still exists but prints "Deprecated" and
                // points at three other commands; `hermes setup` is the
                // interactive sign-in it names.
                loginCommand: "hermes setup",
                cliBinaryName: "hermes",
                // `HERMES_HOME` moves this root wholesale; `HermesAdapter`
                // resolves it.
                defaultConfigDirectory: ".hermes",
                isAgent: true,
                // Hermes has a hook system of the same shape —
                // `on_session_start`, `pre_tool_call`, a JSON payload on stdin
                // carrying `session_id` — but Uncoil's hook bridge speaks
                // Claude Code's wire format only.
                statusSource: .none,
                // Same shape as Grok, with one difference worth recording: it
                // interpolates `${VAR}` in an MCP entry's values from the
                // process environment, so a single config.yaml entry could pick
                // up a per-session id. That is a real path, but it needs a
                // persistent write to the user's config.
                controlPlane: .none,
                extensionScoping: .none,
                // `hermes update` is its own documented updater; the CLI
                // installs outside any package manager's tree.
                hasBuiltInUpdater: true,
                // Documents `--resume <session_id>` and `-c/--continue`.
                resumesConversation: true,
                defaultShiftEnterNewline: false,
                // `--yolo` is the one approval flag its own `--help` documents.
                // `--safe-mode` is a troubleshooting switch, not an approval
                // level, so it is not offered as one.
                workingModes: [.providerDefault, .dangerouslySkipPermissions],
                unattendedMode: .dangerouslySkipPermissions,
                extensionAgentID: .hermes
            )
        case .cursor:
            AgentDescriptor(
                provider: .cursor,
                displayName: "Cursor",
                fullName: "Cursor",
                // The agent CLI, not the editor's `cursor` command.
                launchCommand: "cursor-agent",
                loginCommand: "cursor-agent login",
                cliBinaryName: "cursor-agent",
                defaultConfigDirectory: ".cursor",
                isAgent: true,
                statusSource: .none,
                // `CURSOR_CONFIG_DIR` moves the whole config root, credentials
                // included, so a per-session copy would start logged out.
                controlPlane: .none,
                extensionScoping: .none,
                hasBuiltInUpdater: true,
                resumesConversation: true,
                defaultShiftEnterNewline: false,
                // `--mode` lists plan and ask; `--auto-review` and `--force`
                // are its two documented booleans.
                workingModes: [
                    .providerDefault, .plan, .readOnly, .auto,
                    .dangerouslySkipPermissions,
                ],
                unattendedMode: .dangerouslySkipPermissions,
                extensionAgentID: .cursor
            )
        case .terminal:
            AgentDescriptor(
                provider: .terminal,
                displayName: "Terminal",
                fullName: "Terminal",
                // A plain login shell.
                launchCommand: nil,
                loginCommand: nil,
                cliBinaryName: nil,
                defaultConfigDirectory: nil,
                // A terminal session has no agent, so it has no agent status,
                // no hooks and no control plane.
                isAgent: false,
                statusSource: .none,
                controlPlane: .none,
                extensionScoping: .none,
                hasBuiltInUpdater: false,
                resumesConversation: false,
                defaultShiftEnterNewline: false,
                workingModes: [.providerDefault],
                unattendedMode: .providerDefault,
                extensionAgentID: nil
            )
        }
    }
}

extension AgentProvider {
    /// The one place a provider fact is stated. Views and services should read
    /// this rather than switching on the provider themselves.
    var descriptor: AgentDescriptor { AgentRegistry.descriptor(for: self) }
}
