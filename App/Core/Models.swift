import SwiftUI
import AppKit

// MARK: - Provider

/// How far a provider can be held to a project's extension selection. See
/// `AgentProvider.extensionScoping` for the per-CLI evidence.
enum ExtensionScopingSupport: Equatable {
    /// MCP servers and skills alike can be restricted for one session.
    case strict
    /// MCP servers only; the CLI offers no per-session skill selection.
    case mcpOnly
    /// Nothing can be restricted without writing to the user's own config.
    case none

    var scopesMCPServers: Bool { self != .none }
    var scopesSkills: Bool { self == .strict }
}

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case opencode
    case grok
    case hermes
    case cursor
    case terminal

    var id: String { rawValue }

    /// Every provider that runs an agent, in the order they are offered.
    ///
    /// This list was written out by hand in twenty-two places — some with the
    /// terminal, some without, and the difference between the two was never
    /// stated. Adding a provider meant finding all of them, and missing one
    /// meant an agent that existed everywhere except the screen you forgot.
    /// `CaseIterable` is derived from the cases themselves, so a new case is
    /// picked up here by construction rather than by remembering.
    static let agents: [AgentProvider] = allCases.filter(\.isAgent)

    /// The agents plus the plain shell: what a "new session" chooser offers.
    static let sessionKinds: [AgentProvider] = allCases

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        case .hermes: "Hermes"
        case .cursor: "Cursor"
        case .terminal: "Terminal"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .claude: Theme.claude
        case .codex: Theme.codex
        case .gemini: Theme.gemini
        case .opencode: Theme.opencode
        case .grok: Theme.grok
        case .hermes: Theme.hermes
        case .cursor: Theme.cursor
        case .terminal: Theme.terminal
        }
    }

    /// Command executed (via `exec`, invisible to the user) when a session starts.
    var launchCommand: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .grok: "grok"
        case .hermes: "hermes"
        // The agent CLI, not the editor's `cursor` command.
        case .cursor: "cursor-agent"
        case .terminal: nil  // plain login shell
        }
    }

    /// The provider's own browser-login flow, run inside a login terminal.
    var loginCommand: String? {
        switch self {
        case .claude: "claude /login"
        case .codex: "codex login"
        // The Gemini CLI runs its own sign-in on first start, and Uncoil has
        // no verified non-interactive command to drive it. Offering a login
        // terminal that types a guessed command would be worse than not
        // offering one.
        case .gemini: nil
        // Verified against the CLI's own help: `providers login` is the
        // documented sign-in, and it drives a browser flow in a terminal.
        case .opencode: "opencode providers login"
        // `grok login` is its own documented subcommand.
        case .grok: "grok login"
        // `hermes login` still exists but prints "Deprecated" and points at
        // three other commands; `hermes setup` is the interactive sign-in it
        // names, and it is what a login terminal should run.
        case .hermes: "hermes setup"
        case .cursor: "cursor-agent login"
        case .terminal: nil
        }
    }

    /// Whether Uncoil runs an agent in this session, or just a shell.
    ///
    /// The distinction was made ad hoc — twenty-odd `provider == .terminal`
    /// comparisons, each deciding for itself — and the places that forgot it
    /// are what put "Claude is waiting for your input" and an MCP badge on a
    /// plain terminal. A terminal session has no agent, so it has no agent
    /// status, no hooks and no control plane.
    var isAgent: Bool {
        switch self {
        case .claude, .codex, .gemini, .opencode, .grok, .cursor, .hermes: true
        case .terminal: false
        }
    }

    /// Whether this provider reports what it is doing through Uncoil's hooks.
    ///
    /// Only Claude Code does. Codex reports through its own app-server events
    /// and Gemini reports nothing at all, so neither can be the answer to
    /// "which session did this hook event come from" — and a provider that
    /// never binds a session id would otherwise be the standing fallback for
    /// every event nobody claimed.
    var reportsStatusThroughHooks: Bool {
        switch self {
        case .claude: true
        // Hermes has a hook system of the same shape — `on_session_start`,
        // `pre_tool_call`, a JSON payload on stdin carrying `session_id` — but
        // Uncoil's hook bridge speaks Claude Code's wire format only. Until it
        // speaks Hermes' too, claiming this would bind sessions to events that
        // never arrive.
        case .codex, .gemini, .opencode, .grok, .cursor, .hermes, .terminal: false
        }
    }

    /// Whether Uncoil actually registers its MCP server for this provider.
    ///
    /// Registration is provider-specific — `--mcp-config` for Claude Code,
    /// `-c mcp_servers.uncoil.*` for Codex, `OPENCODE_CONFIG_CONTENT` for
    /// OpenCode — so it is not enough for a session to be an agent's. Gemini
    /// has no verified per-session equivalent yet, and handing a session the
    /// control socket in its environment while nothing serves it would
    /// advertise a control plane that is not there: the agent would read the
    /// variables, find no tools, and the failure would look like a broken
    /// socket rather than a missing feature.
    ///
    /// OpenCode's mechanism was verified against the installed CLI before it
    /// was claimed here: `opencode debug config` shows the inline content
    /// *merged* over the user's own file, so the server arrives without any
    /// write to `~/.config/opencode`.
    var wiresControlPlane: Bool {
        switch self {
        case .claude, .codex, .opencode: true
        // Grok registers MCP servers only in its own config.toml, and the one
        // entry Uncoil would write carries a session id — which would be the
        // same stale id for every session, so every tool call would arrive
        // from a caller the app cannot find. Verified against the CLI: there
        // is no per-session equivalent of `--mcp-config`, and `GROK_HOME`
        // redirects the whole home (credentials included) rather than one file.
        // Cursor is the same story: `CURSOR_CONFIG_DIR` moves the whole
        // config root, credentials included, so a per-session copy would
        // start every session logged out.
        // Hermes is the same shape as Grok here, with one difference worth
        // recording: it interpolates `${VAR}` in an MCP entry's values from
        // the process environment, so a single config.yaml entry could pick up
        // a per-session id. That is a real path to a control plane, but it
        // needs a persistent write to the user's config, so it is not
        // something a session launch may do on its own.
        case .grok, .cursor, .gemini, .hermes, .terminal: false
        }
    }

    /// How much of a project's extension selection this provider can actually
    /// be held to when a session starts.
    ///
    /// A project says which MCP servers and skills belong to it; whether that
    /// can be *enforced* is a fact about each CLI, and the answer differs per
    /// half. Every entry here was checked against the installed CLI's own
    /// `--help` and config, because a scoping claim that quietly does nothing
    /// is worse than admitting the gap: the user would trim a list, watch the
    /// agent load everything anyway, and have no way to tell which of the two
    /// was lying.
    var extensionScoping: ExtensionScopingSupport {
        switch self {
        // Codex answers both halves from its own config: `mcp_servers.<name>`
        // and each `[[skills.config]]` entry carry an `enabled` flag, and `-c`
        // overrides either without touching `~/.codex/config.toml`.
        case .codex: .strict
        // Claude Code scopes MCP exactly — `--mcp-config` names the servers and
        // `--strict-mcp-config` ignores every other source — but has no
        // per-session skill selection. `--setting-sources project,local` would
        // drop the user's skills, and with them the hooks Uncoil installs into
        // `~/.claude/settings.json`, so the session would go dark in the UI to
        // buy a shorter skill list. OpenCode is `mcpOnly` for the opposite
        // reason: `OPENCODE_CONFIG_CONTENT` scopes its servers, and it reads no
        // skills at all, so there is no second half to answer for.
        case .claude, .opencode: .mcpOnly
        // No per-session mechanism at all — the same finding, and the same
        // evidence, as `wiresControlPlane` above. Grok and Cursor register MCP
        // servers only in their own config files, Hermes needs a persistent
        // write to pick one up, and Gemini has nothing verified.
        case .gemini, .grok, .cursor, .hermes, .terminal: .none
        }
    }

    /// Whether the CLI updates itself through its own subcommand rather than
    /// through a package manager.
    ///
    /// These four install outside any package manager's tree — into
    /// `~/.local/share`, `~/.grok`, `~/.opencode` — and each documents an
    /// `update` (or `upgrade`) subcommand of its own.
    var hasBuiltInUpdater: Bool {
        switch self {
        // `hermes update` is its own documented updater; the CLI installs
        // outside any package manager's tree.
        case .claude, .cursor, .grok, .opencode, .hermes: true
        case .codex, .gemini, .terminal: false
        }
    }

    /// Whether relaunching this provider with a stored session id brings the
    /// conversation back rather than starting a fresh one.
    ///
    /// The single source of truth for both the resume flag on the launch
    /// command and whether a session may be hibernated: hibernating kills the
    /// process, so a provider that cannot resume would wake up having lost the
    /// conversation — which is not hibernation, it is a restart.
    ///
    /// Gemini has no verified resume flag, and guessing one is a launch failure
    /// rather than a cosmetic bug. A plain shell has no conversation at all.
    /// OpenCode documents `--session <id>` in its own `--help`.
    var resumesConversation: Bool {
        switch self {
        // Grok documents both `--resume <id>` and `--session-id`.
        // Hermes documents `--resume <session_id>` and `-c/--continue`.
        case .claude, .codex, .opencode, .grok, .cursor, .hermes: true
        case .gemini, .terminal: false
        }
    }

    /// Default for the Shift+Enter → literal-newline behavior. Claude Code and
    /// the Codex TUI both accept a backslash+CR for an in-prompt newline (this
    /// is what `claude /terminal-setup` configures in iTerm/VSCode), so it is on
    /// by default for both; a plain terminal keeps Enter meaning submit.
    var defaultShiftEnterNewline: Bool {
        switch self {
        case .claude, .codex: true
        // Unverified for the Gemini CLI: backslash+CR is what Claude Code and
        // the Codex TUI document, and sending it to a prompt that does not
        // understand it would put a stray backslash in the message. Off until
        // it is checked; the setting is there for anyone who has.
        case .gemini: false
        // Unverified for OpenCode's TUI, same rule as Gemini.
        case .opencode: false
        // Unverified for Grok's TUI, same rule.
        case .grok: false
        case .cursor: false
        // Unverified for Hermes' REPL and its TUI alike, same rule.
        case .hermes: false
        case .terminal: false
        }
    }
}

enum AgentWorkingMode: String, Codable, CaseIterable, Identifiable {
    case providerDefault
    case auto
    case plan
    case manual
    case acceptEdits
    case dangerouslySkipPermissions
    case askForApproval
    case approveForMe
    case fullAccess
    case dontAsk
    case onRequest
    case readOnly

    var id: String { rawValue }

    static func options(for provider: AgentProvider) -> [AgentWorkingMode] {
        switch provider {
        case .claude:
            [.providerDefault, .manual, .acceptEdits, .plan, .auto, .dangerouslySkipPermissions]
        // Codex's own two axes, in the pairs its `/approvals` screen offers.
        // `providerDefault` is the one that was missing and the one that
        // matters most: without it every launch carried `--sandbox` and
        // `--ask-for-approval`, so whatever the user had set in
        // `~/.codex/config.toml` — or chosen inside the TUI — was overruled
        // every time, and there was no way to ask Uncoil to stop.
        case .codex:
            [.providerDefault, .readOnly, .askForApproval, .approveForMe, .fullAccess]
        // No modes offered: the Gemini CLI's approval flags are not verified
        // here, and Uncoil's rule is that it adds no flag it was not asked
        // for. An unverified flag on a real CLI is a launch failure.
        case .gemini:
            [.providerDefault]
        // `--auto` is documented in OpenCode's own `--help`, so it is offered;
        // nothing beyond it is, for the same reason Gemini offers nothing.
        case .opencode:
            [.providerDefault, .auto]
        // Read straight off `--permission-mode`'s own possible values:
        // default, acceptEdits, auto, dontAsk, bypassPermissions, plan.
        case .grok:
            [.providerDefault, .plan, .acceptEdits, .auto, .dontAsk, .dangerouslySkipPermissions]
        // `--mode` lists plan and ask; `--auto-review` and `--force` are its
        // two documented booleans. Nothing else is offered.
        case .cursor:
            [.providerDefault, .plan, .readOnly, .auto, .dangerouslySkipPermissions]
        // `--yolo` ("bypass all dangerous command approval prompts") is the one
        // approval flag Hermes' own `--help` documents. `--safe-mode` is a
        // troubleshooting switch that disables customisations, not an approval
        // level, so it is not offered as one.
        case .hermes:
            [.providerDefault, .dangerouslySkipPermissions]
        case .terminal:
            [.providerDefault]
        }
    }

    func label(for provider: AgentProvider) -> String {
        switch self {
        case .providerDefault: "Provider default"
        case .auto: "Auto"
        case .plan: "Plan"
        case .manual: "Manual"
        case .acceptEdits: "Accept Edits"
        case .dangerouslySkipPermissions: "Dangerously Skip Permissions"
        case .askForApproval: "Ask for Approval"
        case .approveForMe: "Approve for Me"
        case .fullAccess: "Full Access"
        case .dontAsk: "Don't Ask"
        case .onRequest: "On Request"
        case .readOnly: "Read Only"
        }
    }

    func detail(for provider: AgentProvider) -> String {
        switch (provider, self) {
        case (_, .providerDefault):
            "The CLI starts with its own default behaviour."
        case (.claude, .auto):
            "Claude manages the permissions it needs based on context."
        case (.claude, .plan):
            "Claude starts in planning mode, before implementing anything."
        case (.claude, .manual):
            "Claude starts with manual review for every action."
        case (.claude, .acceptEdits):
            "File edits are accepted automatically."
        case (.claude, .dangerouslySkipPermissions):
            "Claude starts with every permission check bypassed."
        case (.codex, .readOnly):
            "Codex can read the project but not write to it, and asks before running anything."
        case (.codex, .askForApproval):
            "Codex may write inside the project, and asks before anything beyond it."
        case (.codex, .approveForMe):
            "Codex runs without asking for approval, inside the project's bounds."
        case (.codex, .fullAccess):
            "Codex runs without approval prompts or sandbox limits."
        case (.hermes, .dangerouslySkipPermissions):
            "Hermes runs without asking to approve dangerous commands."
        default:
            "The CLI starts with its own default behaviour."
        }
    }

    /// The mode for a process Uncoil runs on its own, with nobody watching.
    ///
    /// Only for the short-lived run that produces a handover: it resumes a
    /// conversation, prints JSON and exits, and an approval prompt there would
    /// hang against a terminal nobody can see. A session the *user* works in —
    /// including the one that takes the work over — starts in the provider's
    /// default mode, because it is doing their ordinary work and should ask
    /// before acting.
    ///
    /// Worth knowing what each gives up: Claude's skips every permission check,
    /// Codex's drops the workspace sandbox as well.
    static func unattended(for provider: AgentProvider) -> AgentWorkingMode {
        switch provider {
        case .claude: .dangerouslySkipPermissions
        case .codex: .fullAccess
        case .opencode: .auto
        case .grok: .dangerouslySkipPermissions
        case .cursor: .dangerouslySkipPermissions
        case .hermes: .dangerouslySkipPermissions
        // Gemini's approval flags are unverified, and Uncoil adds no flag it
        // has not checked: an invented one is a launch failure, not a
        // permissive session.
        case .gemini, .terminal: .providerDefault
        }
    }

    func launchArguments(for provider: AgentProvider) -> [String] {
        switch (provider, self) {
        case (_, .providerDefault):
            []
        case (.claude, .auto):
            ["--permission-mode", "auto"]
        case (.claude, .plan):
            ["--permission-mode", "plan"]
        case (.claude, .manual):
            ["--permission-mode", "manual"]
        case (.claude, .acceptEdits):
            ["--permission-mode", "acceptEdits"]
        case (.claude, .dangerouslySkipPermissions):
            ["--dangerously-skip-permissions"]
        // Read straight off `codex --help`: `--sandbox` takes read-only,
        // workspace-write or danger-full-access, and `--ask-for-approval`
        // takes on-request or never. Each pair below was launched against the
        // installed CLI before it was offered here.
        case (.codex, .readOnly):
            ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        case (.codex, .askForApproval):
            ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case (.codex, .approveForMe):
            ["--sandbox", "workspace-write", "--ask-for-approval", "never"]
        case (.codex, .fullAccess):
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        // The only approval flag OpenCode documents: "auto-approve permissions
        // that are not explicitly denied".
        case (.opencode, .auto):
            ["--auto"]
        case (.grok, .plan):
            ["--permission-mode", "plan"]
        case (.grok, .acceptEdits):
            ["--permission-mode", "acceptEdits"]
        case (.grok, .auto):
            ["--permission-mode", "auto"]
        case (.grok, .dontAsk):
            ["--permission-mode", "dontAsk"]
        case (.grok, .dangerouslySkipPermissions):
            ["--permission-mode", "bypassPermissions"]
        case (.cursor, .plan):
            ["--mode", "plan"]
        case (.cursor, .readOnly):
            ["--mode", "ask"]
        case (.cursor, .auto):
            ["--auto-review"]
        case (.cursor, .dangerouslySkipPermissions):
            ["--force"]
        case (.hermes, .dangerouslySkipPermissions):
            ["--yolo"]
        default:
            []
        }
    }

    /// Maps another provider's vocabulary onto this one's, for a mode carried
    /// over from a dispatch or a preset.
    ///
    /// `providerDefault` is never mapped onto anything: it means "add no
    /// flags", and turning it into a real mode is what made Uncoil overrule
    /// the user's own CLI configuration on every launch. `readOnly` is not
    /// mapped either — it used to become Codex's workspace-write, which is to
    /// say the one mode that promises not to write was the one that could.
    func normalized(for provider: AgentProvider) -> AgentWorkingMode {
        switch (provider, self) {
        case (.claude, .dontAsk):
            .manual
        case (.codex, .onRequest):
            .askForApproval
        case (.codex, .auto):
            .approveForMe
        default:
            self
        }
    }
}

// MARK: - Per-provider behavior

/// User-tunable per-provider terminal behavior. All fields optional so a value
/// written by an older build decodes, and an unset field falls back to the
/// provider's built-in default (`AgentProvider.defaultShiftEnterNewline`).
struct ProviderBehavior: Codable, Equatable {
    /// When true, Shift+Enter (and Option+Enter) sends a literal newline
    /// (backslash + carriage return) to the agent instead of submitting.
    var shiftEnterNewline: Bool?
    var workingMode: AgentWorkingMode?
}

// MARK: - Account profile

/// Metadata only — credentials always stay with the provider's own login flow.
struct AccountProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var provider: AgentProvider
    var name: String
    /// Subdirectory under profiles/<provider>/ holding an isolated config
    /// root (CLAUDE_CONFIG_DIR). `nil` = the provider's default (~/.claude).
    var directoryName: String?

    init(id: UUID = UUID(), provider: AgentProvider, name: String, directoryName: String? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.directoryName = directoryName
    }

    func configDirectory(profilesRoot: URL) -> URL? {
        guard let directoryName else { return nil }
        return profilesRoot
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Environment variable that points the provider CLI at this profile's
    /// isolated config root.
    var isolationEnvironmentKey: String? {
        switch provider {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        // No verified variable for an isolated Gemini config root, so Uncoil
        // does not claim to isolate one: profiles for it would share the
        // CLI's own home and quietly overwrite each other.
        case .gemini: nil
        // `OPENCODE_CONFIG_DIR` looks like the variable for this and is not:
        // set to a fresh directory, `opencode debug paths` still reports
        // ~/.config/opencode. Claiming isolation off a variable the CLI
        // ignores would let two profiles quietly share one config.
        case .opencode: nil
        // Verified: `GROK_HOME=<dir> grok mcp add …` wrote into that directory
        // and left ~/.grok untouched, so it really does move the config root.
        case .grok: "GROK_HOME"
        // Verified: with `CURSOR_CONFIG_DIR` set, `cursor-agent status` wrote
        // its `cli-config.json` into that directory instead of ~/.cursor.
        case .cursor: "CURSOR_CONFIG_DIR"
        // Verified against the CLI's own source: `HERMES_HOME` is resolved
        // before anything else is read and relocates the entire home —
        // config.yaml, .env, auth.json and the session store together — which
        // is exactly what an isolated account profile needs.
        case .hermes: "HERMES_HOME"
        case .terminal: nil
        }
    }
}

// MARK: - Project

struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    /// Tabler icon name; nil = default folder icon.
    var iconName: String?
    /// Accent color as 0xRRGGBB; nil = neutral.
    var colorHex: UInt32?
    /// Kept at the top of the sidebar. Optional so older documents decode.
    var isPinned: Bool?
    /// Manual sidebar order; nil = never moved by hand.
    var sortIndex: Double?
    /// The folder Uncoil owns for one-off sessions. Optional so older documents
    /// decode; nil and false both mean an ordinary project.
    ///
    /// A one-off session belongs to a project like any other — see
    /// `ScratchWorkspace` — and this is the one bit that says which project
    /// that is.
    var isScratch: Bool?

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

    var isScratchWorkspace: Bool { isScratch == true }

    @MainActor
    var accentColor: Color {
        colorHex.map { Color(hex: $0) } ?? Theme.textDim
    }

    init(id: UUID = UUID(), name: String, rootPath: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}

struct SessionGroup: Identifiable, Codable, Equatable {
    let id: UUID
    let projectID: UUID
    var name: String
    var createdAt: Date
    var sortIndex: Double?

    init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        createdAt: Date = .now,
        sortIndex: Double? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }
}

// MARK: - Session

enum AgentSessionStatus: String, Codable {
    /// Nobody has said yet what this session is doing.
    ///
    /// Statuses live in memory and agents live in the daemon, so every session
    /// restored at launch is in this state until the daemon answers for it.
    /// It used to read as `terminated`, which meant the app spent the first
    /// moment of every launch telling the user that their running agents had
    /// closed — and said the same thing forever if the daemon never connected.
    /// Not knowing is not the same as knowing it is over.
    case unknown
    case idle
    case thinking
    case running
    case waitingForPermission
    case waitingForInput
    case completed
    /// Stopped mid-flight with SIGSTOP: still in memory, using no CPU, and one
    /// signal away from carrying on exactly where it was.
    case suspended
    /// The process is gone; the conversation comes back on wake through the
    /// provider's own resume.
    case hibernated
    case terminated

    var label: String {
        switch self {
        case .unknown: String(localized: "Checking…")
        case .idle: String(localized: "Ready")
        case .thinking: String(localized: "Thinking")
        case .running: String(localized: "Running")
        case .waitingForPermission: String(localized: "Waiting for permission")
        case .waitingForInput: String(localized: "Waiting for a reply")
        case .completed: String(localized: "Done")
        case .suspended: String(localized: "Paused")
        case .hibernated: String(localized: "Asleep")
        case .terminated: String(localized: "Closed")
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .waitingForPermission: Theme.claude
        case .waitingForInput: Theme.warn
        case .thinking: Color(hex: 0xB56CD6)
        case .running: Theme.ok
        case .completed: Theme.highlight
        case .idle: Theme.textDim
        // Deliberately not the "closed" grey: a sleeping session is coming
        // back, and reading it as dead is the whole confusion to avoid.
        case .suspended, .hibernated: Theme.textDim
        case .terminated: Theme.textFaint
        // Not the closed grey either: it is the colour of a question, and the
        // answer arrives within a second of the daemon replying.
        case .unknown: Theme.textDim
        }
    }

    /// Whether the agent has stopped and is waiting on the human. These are the
    /// states that post a notification, and the ones a sidebar row keeps
    /// pulsing for until they are dealt with.
    var needsAttention: Bool {
        switch self {
        case .waitingForPermission, .waitingForInput: true
        case .idle, .thinking, .running, .completed, .terminated, .unknown: false
        // Asleep on purpose. Nothing to answer, so nothing to nag about.
        case .suspended, .hibernated: false
        }
    }

    /// Higher value = more urgent in sidebar/menu ordering.
    var attentionPriority: Int {
        switch self {
        case .waitingForPermission: 5
        case .waitingForInput: 4
        case .running: 3
        case .thinking: 3
        case .completed: 2
        case .idle: 1
        case .suspended, .hibernated: 0
        case .terminated, .unknown: 0
        }
    }

    /// Whether Uncoil knows this session to be alive, as opposed to knowing it
    /// is over or not knowing at all. Every "is it running" question in the app
    /// asks this rather than comparing against `terminated`, because the two
    /// were the same value until `unknown` existed and the comparison read a
    /// missing answer as a closed session.
    var isKnownLive: Bool {
        switch self {
        case .unknown, .terminated: false
        case .idle, .thinking, .running, .waitingForPermission, .waitingForInput,
             .completed, .suspended, .hibernated: true
        }
    }
}

enum CodexAuthenticationState: Equatable {
    case unknown
    case authenticated(String?)
    case required
    case error(String)
}

enum CodexApprovalKind: String, Equatable {
    case command
    case fileChange
    case permissions
}

struct CodexApprovalRequest: Identifiable, Equatable {
    let id: String
    let sessionID: UUID
    let requestID: JSONValue
    let kind: CodexApprovalKind
    let title: String
    let detail: String?
    let permissions: JSONValue?
    let availableDecisions: [String]
}

/// Persisted record of a session. Survives app restarts; the live terminal
/// does not (yet), so a reopened record starts as `.terminated`.
struct SessionRecord: Identifiable, Codable, Equatable {
    static let currentMetadataVersion = 2

    let id: UUID
    let projectID: UUID
    var provider: AgentProvider
    var accountID: UUID?
    var title: String
    var createdAt: Date
    var lastActivityAt: Date
    var providerSessionID: String?
    /// Pinned sessions sort to the top of their project.
    var isPinned: Bool?
    /// Manual drag-order within the project; nil = never manually ordered.
    var sortIndex: Double?
    /// When set, the session runs inside this worktree instead of the
    /// project root.
    var worktreePath: String?
    /// Control-plane parentage: the session that spawned this one (for the
    /// relationship calculator). Optional & backward-compatible.
    var parentSessionID: UUID?
    /// The session this one took over from when its account ran low.
    ///
    /// Separate from `parentSessionID` because it is a different relation: a
    /// child is work delegated downwards and running alongside its parent, a
    /// handoff is the same work continuing after the previous agent stopped.
    /// Folding the two together would nest a successor under a session it
    /// replaced.
    var handoffFromSessionID: UUID?
    /// Control-plane capability grants for this session. `nil` = the default
    /// grant set (see PolicyEngine.defaultGrants). Backward-compatible.
    var capabilities: [String]?
    /// Extra CLI arguments from the launching preset (control-plane children).
    /// Appended after the provider's default arguments. Backward-compatible.
    var extraArguments: [String]?
    /// Model / effort / working-mode the session was dispatched with. nil = the
    /// provider's defaults. Backward-compatible.
    var launchSelection: AgentLaunchSelection?
    var groupID: UUID?
    /// Asleep, and which way. nil = awake. Distinct from `endedAt`: a sleeping
    /// session is coming back, a closed one is not, and collapsing the two is
    /// how a hibernated session would read as dead.
    var sleepMode: SessionSleepMode?
    var sleptAt: Date?
    var endedAt: Date?
    var exitCode: Int32?
    var restartCount: Int?
    var metadataVersion: Int?

    init(
        id: UUID = UUID(),
        projectID: UUID,
        provider: AgentProvider,
        accountID: UUID?,
        title: String,
        worktreePath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.provider = provider
        self.accountID = accountID
        self.title = title
        self.worktreePath = worktreePath
        self.createdAt = createdAt
        self.lastActivityAt = createdAt
        self.metadataVersion = Self.currentMetadataVersion
    }

    func workingDirectory(in project: Project) -> String {
        worktreePath ?? project.rootPath
    }

    /// Per-session artifact root under Application Support/Uncoil. Created
    /// lazily by callers that write into it.
    func artifactRoot(dataDirectory: URL) -> URL {
        dataDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Sidebar/dashboard title: the provider prefix ("claude: ") is redundant
    /// next to the provider mark, so it is stripped for display — and so are
    /// Markdown's inline marks, because a title taken from the first prompt
    /// arrives with whatever the user wrote, `**` included.
    var displayTitle: String {
        for provider in AgentProvider.allCases {
            let prefix = "\(provider.rawValue): "
            if title.hasPrefix(prefix) {
                return MarkdownInline.plain(String(title.dropFirst(prefix.count)))
            }
        }
        return MarkdownInline.plain(title)
    }

    /// Default titles get replaced by the first real prompt.
    var hasPlaceholderTitle: Bool {
        // ": yeni oturum" is the pre-localization default; sessions created by
        // an older build keep that title on disk and would otherwise never get
        // renamed by their first prompt.
        title.hasSuffix(": new session") || title.hasSuffix(": yeni oturum")
            || title == "terminal"
    }
}

// MARK: - Preferred editor

enum PreferredEditor: String, Codable, CaseIterable, Identifiable {
    case vscode
    case zed
    case cursor
    case sublime
    case textedit
    case xcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .cursor: "Cursor"
        case .sublime: "Sublime Text"
        case .textedit: "TextEdit"
        case .xcode: "Xcode"
        }
    }

    var bundleID: String {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .zed: "dev.zed.Zed"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .sublime: "com.sublimetext.4"
        case .textedit: "com.apple.TextEdit"
        case .xcode: "com.apple.dt.Xcode"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var installed: [PreferredEditor] {
        allCases.filter(\.isInstalled)
    }

    /// Whether handing this app a folder does anything useful. TextEdit is a
    /// text editor, not a code editor: given a directory it just refuses, so it
    /// is left out of the "open the project" menu rather than offered and then
    /// failing silently.
    var opensDirectories: Bool {
        self != .textedit
    }

    /// Installed apps that can open a project directory.
    static var directoryCapable: [PreferredEditor] {
        installed.filter(\.opensDirectories)
    }

    /// The app's real icon from disk, for the session control cluster.
    ///
    /// Which rendering this is — light, dark or tinted — is macOS's decision,
    /// not ours: the system's icon style is one setting for the whole machine
    /// (System Settings › Appearance › Icon & widget style), and it is what the
    /// Dock follows too. Asking for the icon here already gets the answer that
    /// setting gives, so Uncoil never picks a variant of its own; drawing one
    /// under a named appearance was tried and changes nothing.
    var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }


    func open(_ fileURL: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(fileURL)
            return
        }
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
