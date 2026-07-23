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

/// Persisted record of a session. Survives app restarts; the live terminal
/// does not (yet), so a reopened record starts as `.terminated`.
struct SessionRecord: Identifiable, Codable, Equatable {
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
