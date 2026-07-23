import SwiftUI

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
    case running
    case waitingForPermission
    case waitingForInput
    case completed
    case terminated

    var label: String {
        switch self {
        case .idle: "Boşta"
        case .running: "Çalışıyor"
        case .waitingForPermission: "İzin bekliyor"
        case .waitingForInput: "Yanıt bekliyor"
        case .completed: "Tamamlandı"
        case .terminated: "Kapandı"
        }
    }

    var color: Color {
        switch self {
        case .waitingForPermission: Theme.claude
        case .waitingForInput: Theme.warn
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
    /// When set, the session runs inside this worktree instead of the
    /// project root.
    var worktreePath: String?

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

    /// Default titles get replaced by the first real prompt.
    var hasPlaceholderTitle: Bool {
        title.hasSuffix(": yeni oturum") || title == "terminal"
    }
}
