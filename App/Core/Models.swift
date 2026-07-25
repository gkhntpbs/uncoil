import SwiftUI
import AppKit

// MARK: - Provider

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case terminal

    var id: String { rawValue }

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
        case .providerDefault: "Provider varsayılanı"
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
        case .readOnly: "Salt Okunur"
        }
    }

    func detail(for provider: AgentProvider) -> String {
        switch (provider, self) {
        case (_, .providerDefault):
            "CLI kendi varsayılan davranışıyla başlar."
        case (.claude, .auto):
            "Claude gerekli izinleri bağlama göre otomatik yönetir."
        case (.claude, .plan):
            "Claude uygulama yapmadan önce planlama modunda başlar."
        case (.claude, .manual):
            "Claude her işlem için manuel kontrolle başlar."
        case (.claude, .acceptEdits):
            "Dosya düzenlemeleri otomatik kabul edilir."
        case (.claude, .dangerouslySkipPermissions):
            "Claude tüm izin kontrollerini atlayarak başlar."
        case (.codex, .askForApproval):
            "Codex gerektiğinde senden işlem onayı ister."
        case (.codex, .approveForMe):
            "Codex workspace sınırları içinde onay istemeden çalışır."
        case (.codex, .fullAccess):
            "Codex onay ve sandbox kısıtlamaları olmadan çalışır."
        default:
            "CLI kendi varsayılan davranışıyla başlar."
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
        case .idle: "Hazır"
        case .thinking: "Düşünüyor"
        case .running: "Çalışıyor"
        case .waitingForPermission: "İzin bekliyor"
        case .waitingForInput: "Yanıt bekliyor"
        case .completed: "Tamamlandı"
        case .terminated: "Kapandı"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .waitingForPermission: Theme.claude
        case .waitingForInput: Theme.warn
        case .thinking: Color(hex: 0xB56CD6)
        case .running: Theme.ok
        case .completed: Theme.codex
        case .idle: Theme.textDim
        case .terminated: Theme.textFaint
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

    /// Sidebar/dashboard title: the provider prefix ("claude: ") is
    /// redundant next to the provider mark, so it is stripped for display.
    var displayTitle: String {
        for provider in AgentProvider.allCases {
            let prefix = "\(provider.rawValue): "
            if title.hasPrefix(prefix) {
                return String(title.dropFirst(prefix.count))
            }
        }
        return title
    }

    /// Default titles get replaced by the first real prompt.
    var hasPlaceholderTitle: Bool {
        title.hasSuffix(": yeni oturum") || title == "terminal"
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
