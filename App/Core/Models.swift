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
    /// Uncoil's own session: a conversation hosted in the app rather than a
    /// CLI in a terminal — the place to direct a project's agents from.
    case uncoil
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

    var displayName: String { descriptor.displayName }

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
        case .uncoil: Theme.brand
        }
    }

    /// Command executed (via `exec`, invisible to the user) when a session starts.
    var launchCommand: String? { descriptor.launchCommand }

    /// The provider's own browser-login flow, run inside a login terminal.
    var loginCommand: String? { descriptor.loginCommand }

    /// Whether Uncoil runs an agent in this session, or just a shell.
    ///
    /// The distinction was made ad hoc — twenty-odd `provider == .terminal`
    /// comparisons, each deciding for itself — and the places that forgot it
    /// are what put "Claude is waiting for your input" and an MCP badge on a
    /// plain terminal. A terminal session has no agent, so it has no agent
    /// status, no hooks and no control plane.
    var isAgent: Bool { descriptor.isAgent }

    /// Whether this provider reports what it is doing through Uncoil's hooks.
    ///
    /// Only Claude Code does. Codex reports through its own app-server events
    /// and the rest report nothing at all, so neither can be the answer to
    /// "which session did this hook event come from" — and a provider that
    /// never binds a session id would otherwise be the standing fallback for
    /// every event nobody claimed. See `AgentDescriptor.statusSource` for the
    /// other two answers.
    var reportsStatusThroughHooks: Bool { descriptor.statusSource == .hooks }

    /// Whether Uncoil actually registers its MCP server for this provider.
    ///
    /// Registration is provider-specific, so it is not enough for a session to
    /// be an agent's; `AgentDescriptor.controlPlane` records which mechanism
    /// each CLI offers, and `.none` means handing the session a control socket
    /// would advertise a control plane that is not there.
    var wiresControlPlane: Bool { descriptor.controlPlane.isWired }

    /// How much of a project's extension selection this provider can actually
    /// be held to when a session starts.
    var extensionScoping: ExtensionScopingSupport { descriptor.extensionScoping }

    /// Whether the CLI updates itself through its own subcommand rather than
    /// through a package manager.
    var hasBuiltInUpdater: Bool { descriptor.hasBuiltInUpdater }

    /// Whether relaunching this provider with a stored session id brings the
    /// conversation back rather than starting a fresh one.
    ///
    /// The single source of truth for both the resume flag on the launch
    /// command and whether a session may be hibernated: hibernating kills the
    /// process, so a provider that cannot resume would wake up having lost the
    /// conversation — which is not hibernation, it is a restart.
    var resumesConversation: Bool { descriptor.resumesConversation }

    /// Default for the Shift+Enter → literal-newline behavior.
    var defaultShiftEnterNewline: Bool { descriptor.defaultShiftEnterNewline }
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
        provider.descriptor.workingModes
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
            "Codex's automatic reviewer answers approvals, inside the project's bounds."
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
        provider.descriptor.unattendedMode
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
        // Codex's own "Approve for me" (0.160+): approvals are routed to its
        // automatic reviewer inside workspace-write, rather than never asked
        // for at all — which is what `--ask-for-approval never` meant, and
        // not what the mode is called.
        case (.codex, .approveForMe):
            ["--approve-for-me"]
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
        case .terminal, .uncoil: nil
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
    /// The SSH hosts this project's agents are told about, by alias. Optional
    /// so older documents decode; nil and empty both mean none.
    var sshHostAliases: [String]?

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
    /// The agent's own turn is over, but sub-agents it started are still
    /// working — Claude Code's Task/Agent tool, run in the background. The
    /// session is not done, so it neither reads as Ready nor sends "Turn done".
    case waitingForSubagents
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
        case .waitingForSubagents: String(localized: "Sub-agents working")
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
        case .waitingForSubagents: Theme.info
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
        case .idle, .thinking, .running, .waitingForSubagents, .completed, .terminated, .unknown: false
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
        case .thinking, .waitingForSubagents: 3
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
             .waitingForSubagents, .completed, .suspended, .hibernated: true
        }
    }

    /// Who is asking to change a status.
    ///
    /// An *event* is something the agent reported — a hook, a stream message,
    /// PTY output. A *lifecycle* change is Uncoil acting on the session itself:
    /// launching, waking, putting to sleep, closing, or reconciling against the
    /// daemon. The two are not equal, and treating them as equal is what let a
    /// hook arriving after a close bring a dead row back to "Running".
    enum Origin: Equatable {
        case event
        case lifecycle
    }

    /// The legal transitions, in one place instead of in every handler.
    ///
    /// - Ending is always legal: anything may say a session is over.
    /// - Lifecycle may move anywhere — it is the thing that starts and stops
    ///   sessions, and only it may bring one back from closed or asleep.
    /// - An event may not leave `terminated`, `suspended` or `hibernated`. A
    ///   late or stray report from a process that has stopped describes the
    ///   past; only a relaunch or a wake makes the session live again.
    /// - An event may not put a session to sleep or make it unknown; those are
    ///   Uncoil's statements, not the agent's.
    func allowsTransition(to next: AgentSessionStatus, from origin: Origin) -> Bool {
        if next == self || next == .terminated { return true }
        if origin == .lifecycle { return true }
        switch next {
        case .unknown, .suspended, .hibernated: return false
        default: break
        }
        switch self {
        case .terminated, .suspended, .hibernated: return false
        case .unknown, .idle, .thinking, .running, .waitingForPermission,
             .waitingForInput, .waitingForSubagents, .completed: return true
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
    /// For a plain terminal: the command it runs instead of an interactive
    /// shell — `ssh <alias>` for a session opened on a remote host. nil = a
    /// login shell. Backward-compatible.
    var shellCommand: [String]?
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


    /// What to hand this app for a project directory, or nil when it has
    /// nothing useful to do with it.
    ///
    /// Xcode is the one that needs telling: given a bare folder it opens an
    /// empty window, so it gets the workspace, the project or the package
    /// manifest — and is not offered at all for a folder that has none.
    func openTarget(forDirectory directory: URL) -> URL? {
        guard opensDirectories else { return nil }
        guard self == .xcode else { return directory }
        return XcodeProjectLocator.target(in: directory)
    }

    /// Installed apps that can open this particular project directory.
    static func available(forDirectory directory: URL) -> [PreferredEditor] {
        directoryCapable.filter { $0.openTarget(forDirectory: directory) != nil }
    }

    /// Opens a project directory in this app, through `openTarget`.
    func openProject(_ directory: URL) {
        open(openTarget(forDirectory: directory) ?? directory)
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

/// Finds what Xcode should open for a directory: a workspace before a project,
/// a project before a Swift package, and only at the top level — a project
/// buried in a dependency checkout is not this directory's project.
enum XcodeProjectLocator {
    static func target(in directory: URL, fileManager: FileManager = .default) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let sorted = names.sorted()
        for ext in ["xcworkspace", "xcodeproj"] {
            if let name = sorted.first(where: { ($0 as NSString).pathExtension == ext }) {
                return directory.appendingPathComponent(name, isDirectory: true)
            }
        }
        if sorted.contains("Package.swift") {
            return directory.appendingPathComponent("Package.swift")
        }
        return nil
    }
}
