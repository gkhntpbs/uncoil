import SwiftUI
import AppKit

// MARK: - Provider

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
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
        case .terminal: "Terminal"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .claude: Theme.claude
        case .codex: Theme.codex
        case .terminal: Theme.terminal
        }
    }

    /// Command executed (via `exec`, invisible to the user) when a session starts.
    var launchCommand: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .terminal: nil  // plain login shell
        }
    }

    /// The provider's own browser-login flow, run inside a login terminal.
    var loginCommand: String? {
        switch self {
        case .claude: "claude /login"
        case .codex: "codex login"
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
        case .claude, .codex: true
        case .terminal: false
        }
    }

    /// Default for the Shift+Enter → literal-newline behavior. Claude Code and
    /// the Codex TUI both accept a backslash+CR for an in-prompt newline (this
    /// is what `claude /terminal-setup` configures in iTerm/VSCode), so it is on
    /// by default for both; a plain terminal keeps Enter meaning submit.
    var defaultShiftEnterNewline: Bool {
        switch self {
        case .claude, .codex: true
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
            [.manual, .acceptEdits, .plan, .auto, .dangerouslySkipPermissions]
        case .codex:
            [.askForApproval, .approveForMe, .fullAccess]
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
        case (.codex, .askForApproval):
            "Codex asks you to approve actions when it needs to."
        case (.codex, .approveForMe):
            "Codex runs without asking for approval inside the workspace bounds."
        case (.codex, .fullAccess):
            "Codex runs without approval prompts or sandbox limits."
        default:
            "The CLI starts with its own default behaviour."
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
        case (.codex, .askForApproval):
            ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case (.codex, .approveForMe):
            ["--sandbox", "workspace-write", "--ask-for-approval", "never"]
        case (.codex, .fullAccess):
            ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        default:
            []
        }
    }

    func normalized(for provider: AgentProvider) -> AgentWorkingMode {
        switch (provider, self) {
        case (.claude, .providerDefault), (.claude, .dontAsk):
            .manual
        case (.codex, .providerDefault), (.codex, .onRequest), (.codex, .readOnly):
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

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

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
    case idle
    case thinking
    case running
    case waitingForPermission
    case waitingForInput
    case completed
    case terminated

    var label: String {
        switch self {
        case .idle: String(localized: "Ready")
        case .thinking: String(localized: "Thinking")
        case .running: String(localized: "Running")
        case .waitingForPermission: String(localized: "Waiting for permission")
        case .waitingForInput: String(localized: "Waiting for a reply")
        case .completed: String(localized: "Done")
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
        case .terminated: Theme.textFaint
        }
    }

    /// Whether the agent has stopped and is waiting on the human. These are the
    /// states that post a notification, and the ones a sidebar row keeps
    /// pulsing for until they are dealt with.
    var needsAttention: Bool {
        switch self {
        case .waitingForPermission, .waitingForInput: true
        case .idle, .thinking, .running, .completed, .terminated: false
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
        case .terminated: 0
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
