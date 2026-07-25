import Foundation

// MARK: - Agent identity

/// Every agent the Extensions system can manage — a superset of the providers
/// Uncoil itself runs, because skills and MCP servers are shared with agents
/// Uncoil never launches.
enum ExtensionAgentID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case geminiCLI
    case cursor
    case amp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        case .cursor: "Cursor"
        case .amp: "Amp"
        }
    }

    /// The session provider Uncoil launches for this agent, when it has one.
    var provider: AgentProvider? {
        switch self {
        case .claudeCode: .claude
        case .codex: .codex
        case .geminiCLI, .cursor, .amp: nil
        }
    }

    /// Agents with an adapter today; the rest are listed but not managed.
    ///
    /// Gemini CLI, Cursor and Amp are managed through the shared JSON adapter:
    /// their MCP servers are read and written, but neither skills nor
    /// authentication are, so they are not equals of Claude Code and Codex.
    static var supported: [ExtensionAgentID] {
        [.claudeCode, .codex, .geminiCLI, .cursor, .amp]
    }

    /// Agents Uncoil can also launch a session for.
    static var launchable: [ExtensionAgentID] { allCases.filter { $0.provider != nil } }
}

/// A concrete agent install found on disk.
struct AgentInstallation: Identifiable, Equatable, Codable {
    let agent: ExtensionAgentID
    /// Absolute path of the CLI binary.
    var binaryPath: String
    /// The agent's configuration root (`~/.claude`, `~/.codex`, …).
    var configDirectory: String
    /// Where per-skill symlinks belong, when the agent reads skills at all.
    var skillsDirectory: String?
    /// The file holding this agent's MCP server definitions.
    var mcpConfigPath: String?
    var version: String?
    /// nil = not determined (checking a login can be expensive).
    var isAuthenticated: Bool?
    var detectedAt: Date

    /// Stable across rescans: one install per (agent, binary).
    var id: String { "\(agent.rawValue):\(binaryPath)" }
}

/// A named way of running an installation — isolated config root, model and
/// working-mode defaults. Maps onto Uncoil's account profiles for the agents
/// it launches itself.
struct AgentProfile: Identifiable, Equatable, Codable {
    let id: UUID
    var agent: ExtensionAgentID
    var name: String
    /// Overrides the installation's config root when set (CLAUDE_CONFIG_DIR,
    /// CODEX_HOME).
    var configDirectory: String?
    var model: String?
    var workingMode: AgentWorkingMode?
    var isDefault: Bool

    init(
        id: UUID = UUID(),
        agent: ExtensionAgentID,
        name: String,
        configDirectory: String? = nil,
        model: String? = nil,
        workingMode: AgentWorkingMode? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.agent = agent
        self.name = name
        self.configDirectory = configDirectory
        self.model = model
        self.workingMode = workingMode
        self.isDefault = isDefault
    }
}

/// What an adapter can actually do, so the UI never offers an action the agent
/// does not support.
struct AgentProviderCapabilities: Equatable, Codable {
    var readsSkillsFromDirectory = false
    /// Skills can be linked one-by-one (rather than only as a whole folder).
    var supportsPerSkillSymlinks = false
    var supportsStdioMCP = false
    var supportsHTTPMCP = false
    /// MCP servers can be scoped to a single project.
    var supportsProjectScopedMCP = false
    /// Config changes are picked up without restarting a running agent.
    var reloadsConfigWithoutRestart = false
    /// The config file format round-trips comments and unknown keys.
    var preservesUnknownConfigKeys = false
    var reportsAuthenticationState = false

    static let none = AgentProviderCapabilities()
}

// MARK: - Sources

/// Where an extension came from, which decides what Uncoil may do with it.
enum ExtensionSource: Equatable, Codable {
    /// Tracked git repository Uncoil mirrors and updates.
    case managedGitHub(repository: String, subpath: String?, tracking: TrackingMode)
    /// Shipped inside Uncoil.app; updated with the app.
    case bundled(identifier: String)
    /// Added by hand from a local folder: runnable and assignable, never updated.
    case local(path: String)
    /// Installed outside Uncoil; read-only until adopted.
    case detectedExternal(path: String)
    /// Remote MCP endpoint: no local git, version comes from the server.
    case remoteMCP(url: String, transport: MCPTransport)

    enum TrackingMode: Equatable, Codable {
        case pinnedCommit(String)
        case tag(String)
        case branch(String)

        var label: String {
            switch self {
            case .pinnedCommit(let sha): "commit \(String(sha.prefix(7)))"
            case .tag(let tag): "tag \(tag)"
            case .branch(let branch): "branch \(branch)"
            }
        }
    }

    /// Managed sources are the only ones Uncoil updates or rolls back.
    var isManaged: Bool {
        switch self {
        case .managedGitHub: true
        case .bundled, .local, .detectedExternal, .remoteMCP: false
        }
    }

    /// Uncoil owns the files (may relink, quarantine, remove).
    var isOwnedByUncoil: Bool {
        switch self {
        case .managedGitHub, .bundled: true
        case .local, .detectedExternal, .remoteMCP: false
        }
    }

    /// Shown verbatim in the UI so "Unmanaged" is never implied silently.
    var label: String {
        switch self {
        case .managedGitHub(let repository, _, let tracking):
            "\(repository) · \(tracking.label)"
        case .bundled:
            "Uncoil ile gelen"
        case .local:
            "Unmanaged (yerel)"
        case .detectedExternal:
            "Unmanaged (dışarıda kurulmuş)"
        case .remoteMCP(let url, _):
            "Remote MCP · \(url)"
        }
    }
}

enum MCPTransport: String, Codable, Equatable, CaseIterable {
    case stdio
    case http

    var label: String {
        switch self {
        case .stdio: "STDIO"
        case .http: "HTTP"
        }
    }
}

// MARK: - Packages

enum ExtensionKind: String, Codable, Equatable, CaseIterable {
    case skill
    case mcpServer

    var label: String {
        switch self {
        case .skill: "Skill"
        case .mcpServer: "MCP Server"
        }
    }
}

enum ExtensionState: String, Codable, Equatable {
    case active
    case disabled
    case quarantined
    case broken

    var label: String {
        switch self {
        case .active: "Etkin"
        case .disabled: "Kapalı"
        case .quarantined: "Karantinada"
        case .broken: "Bozuk"
        }
    }
}

/// One managed unit: a skill or an MCP server, with its source, the revision
/// currently active, and the last thing Uncoil learned about its health.
struct ExtensionPackage: Identifiable, Equatable, Codable {
    let id: String
    var kind: ExtensionKind
    var name: String
    var summary: String?
    var source: ExtensionSource
    var state: ExtensionState
    var activeRevision: InstalledRevision?
    var previousRevision: InstalledRevision?
    var lastFetchedAt: Date?
    var lastScannedAt: Date?
    /// True when the active files no longer match the revision's content hash.
    var hasLocalModification: Bool

    init(
        id: String,
        kind: ExtensionKind,
        name: String,
        summary: String? = nil,
        source: ExtensionSource,
        state: ExtensionState = .active,
        activeRevision: InstalledRevision? = nil,
        previousRevision: InstalledRevision? = nil,
        lastFetchedAt: Date? = nil,
        lastScannedAt: Date? = nil,
        hasLocalModification: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.summary = summary
        self.source = source
        self.state = state
        self.activeRevision = activeRevision
        self.previousRevision = previousRevision
        self.lastFetchedAt = lastFetchedAt
        self.lastScannedAt = lastScannedAt
        self.hasLocalModification = hasLocalModification
    }

    /// Update checks only make sense for managed git sources.
    var supportsUpdateCheck: Bool { source.isManaged }
}

/// Skill-specific detail read from the package's own files.
struct SkillPackage: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var description: String?
    /// Path of `SKILL.md` relative to the package root.
    var entrypoint: String
    var scripts: [String]
    var assets: [String]
    var dependencies: [String]
    /// Files carrying the executable bit — the security scanner's first input.
    var executables: [String]

    init(
        id: String,
        name: String,
        description: String? = nil,
        entrypoint: String = "SKILL.md",
        scripts: [String] = [],
        assets: [String] = [],
        dependencies: [String] = [],
        executables: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.entrypoint = entrypoint
        self.scripts = scripts
        self.assets = assets
        self.dependencies = dependencies
        self.executables = executables
    }
}

/// An MCP server as the agent's config declares it. Secret VALUES never live
/// here — only the names of the environment variables to inject.
struct MCPServerDefinition: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var transport: MCPTransport
    /// STDIO: the executable. nil for HTTP servers.
    var command: String?
    var arguments: [String]
    /// HTTP: the endpoint. nil for STDIO servers.
    var url: String?
    /// Environment variable names this server needs; values come from Keychain.
    var environmentKeys: [String]
    /// Non-secret environment values that are safe to keep in config.
    var environment: [String: String]
    var isEnabled: Bool
    var startupTimeoutSeconds: Int?
    /// Tools the server reported at the last successful handshake.
    var reportedTools: [String]
    var serverReportedVersion: String?

    init(
        id: String,
        name: String,
        transport: MCPTransport,
        command: String? = nil,
        arguments: [String] = [],
        url: String? = nil,
        environmentKeys: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true,
        startupTimeoutSeconds: Int? = nil,
        reportedTools: [String] = [],
        serverReportedVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environmentKeys = environmentKeys
        self.environment = environment
        self.isEnabled = isEnabled
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.reportedTools = reportedTools
        self.serverReportedVersion = serverReportedVersion
    }

    /// What the user sees in place of a command: endpoint for remote servers.
    var displayTarget: String {
        switch transport {
        case .stdio:
            ([command].compactMap { $0 } + arguments).joined(separator: " ")
        case .http:
            url ?? ""
        }
    }
}

// MARK: - Bindings

/// Extension → agent assignment. Removing one never deletes the central copy.
struct AgentBinding: Identifiable, Equatable, Codable {
    var extensionID: String
    var agent: ExtensionAgentID
    var isEnabled: Bool
    /// Where the per-skill symlink was created, when the agent uses one.
    var linkPath: String?

    var id: String { "\(extensionID)@\(agent.rawValue)" }

    init(extensionID: String, agent: ExtensionAgentID, isEnabled: Bool = true, linkPath: String? = nil) {
        self.extensionID = extensionID
        self.agent = agent
        self.isEnabled = isEnabled
        self.linkPath = linkPath
    }
}

/// Extension → project assignment. `projectID == nil` means every project.
struct ProjectBinding: Identifiable, Equatable, Codable {
    var extensionID: String
    var projectID: UUID?
    var agent: ExtensionAgentID?
    var isEnabled: Bool

    var id: String {
        "\(extensionID)@\(projectID?.uuidString ?? "global"):\(agent?.rawValue ?? "any")"
    }

    var isGlobal: Bool { projectID == nil }

    init(extensionID: String, projectID: UUID? = nil, agent: ExtensionAgentID? = nil, isEnabled: Bool = true) {
        self.extensionID = extensionID
        self.projectID = projectID
        self.agent = agent
        self.isEnabled = isEnabled
    }
}

// MARK: - Revisions and updates

/// An immutable checkout of one extension at one commit.
struct InstalledRevision: Identifiable, Equatable, Codable {
    /// Commit SHA for git sources; a content hash for local ones. Never the
    /// word "latest" — a version has to be something we can return to.
    let id: String
    var commitSHA: String?
    /// Hash of the revision's files, so local edits are detectable.
    var contentHash: String
    /// Immutable revision directory under ~/.uncoil/extensions/revisions/.
    var path: String
    var installedAt: Date
    var changelog: String?

    init(
        id: String,
        commitSHA: String? = nil,
        contentHash: String,
        path: String,
        installedAt: Date,
        changelog: String? = nil
    ) {
        self.id = id
        self.commitSHA = commitSHA
        self.contentHash = contentHash
        self.path = path
        self.installedAt = installedAt
        self.changelog = changelog
    }
}

/// A newer commit is available for a managed extension.
struct UpdateCandidate: Identifiable, Equatable, Codable {
    var extensionID: String
    var installedCommitSHA: String?
    var availableCommitSHA: String
    /// How many commits the tracking ref moved ahead.
    var commitCount: Int
    var changedFiles: [String]
    var changelog: String?
    var fetchedAt: Date

    var id: String { "\(extensionID):\(availableCommitSHA)" }
}

// MARK: - Health, security, transactions, audit

struct HealthCheckResult: Identifiable, Equatable, Codable {
    enum Outcome: String, Codable, Equatable {
        case ok
        case warning
        case failure
        /// The check does not apply here (remote MCP has no local git).
        case notApplicable

        var label: String {
            switch self {
            case .ok: "Sağlıklı"
            case .warning: "Uyarı"
            case .failure: "Başarısız"
            case .notApplicable: "Kapsam dışı"
            }
        }
    }

    let id: String
    var name: String
    var outcome: Outcome
    var detail: String
    var remedy: String?
    var checkedAt: Date

    var isBlocking: Bool { outcome == .failure }
}

struct SecurityFinding: Identifiable, Equatable, Codable {
    enum Severity: String, Codable, Equatable, CaseIterable, Comparable {
        case info
        case low
        case needsReview
        case high
        case blocked

        var label: String {
            switch self {
            case .info: "Bilgi"
            case .low: "Low Risk"
            case .needsReview: "Needs Review"
            case .high: "High Risk"
            case .blocked: "Blocked"
            }
        }

        private var rank: Int {
            switch self {
            case .info: 0
            case .low: 1
            case .needsReview: 2
            case .high: 3
            case .blocked: 4
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    /// Findings from Bumblebee and from Uncoil's own scanner are never mixed.
    enum Origin: String, Codable, Equatable {
        case uncoil
        case bumblebee

        var label: String {
            switch self {
            case .uncoil: "Uncoil"
            case .bumblebee: "Bumblebee"
            }
        }
    }

    let id: String
    var origin: Origin
    var severity: Severity
    /// Stable rule identifier ("risky-command.sudo", "symlink-escape", …).
    var rule: String
    var message: String
    var extensionID: String?
    var path: String?
    var foundAt: Date
    var isAccepted: Bool

    init(
        id: String,
        origin: Origin,
        severity: Severity,
        rule: String,
        message: String,
        extensionID: String? = nil,
        path: String? = nil,
        foundAt: Date,
        isAccepted: Bool = false
    ) {
        self.id = id
        self.origin = origin
        self.severity = severity
        self.rule = rule
        self.message = message
        self.extensionID = extensionID
        self.path = path
        self.foundAt = foundAt
        self.isAccepted = isAccepted
    }
}

/// One planned agent-config edit, kept as a plan so it can be shown, applied
/// later, and rolled back. Uncoil never edits an agent config in place without
/// one of these.
struct ConfigurationTransaction: Identifiable, Equatable, Codable {
    enum Status: String, Codable, Equatable {
        case planned
        case applied
        case rolledBack
        /// The file changed under us; the plan must be recomputed.
        case staleConfig
        case failed

        var label: String {
            switch self {
            case .planned: "Planlandı"
            case .applied: "Uygulandı"
            case .rolledBack: "Geri alındı"
            case .staleConfig: "Config değişti"
            case .failed: "Başarısız"
            }
        }
    }

    let id: UUID
    var agent: ExtensionAgentID
    var configPath: String
    /// Hash of the config when the plan was made — re-checked before applying.
    var baseHash: String
    /// Unified-diff style preview shown to the user before anything is written.
    var diff: String
    /// The exact file content the plan would write. Held in memory only — it
    /// carries whatever the user's config already contains, so it is never
    /// written to an audit log or export.
    var pendingContent: String?
    /// Copy of the original file, so a rollback needs no agent cooperation.
    var backupPath: String?
    var status: Status
    var createdAt: Date
    var appliedAt: Date?
    var failureReason: String?

    init(
        id: UUID = UUID(),
        agent: ExtensionAgentID,
        configPath: String,
        baseHash: String,
        diff: String,
        pendingContent: String? = nil,
        backupPath: String? = nil,
        status: Status = .planned,
        createdAt: Date = .now,
        appliedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.configPath = configPath
        self.baseHash = baseHash
        self.diff = diff
        self.pendingContent = pendingContent
        self.backupPath = backupPath
        self.status = status
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.failureReason = failureReason
    }

    var isEmpty: Bool { diff.isEmpty }
}

/// Append-only record of everything the Extensions system did.
struct AuditEvent: Identifiable, Equatable, Codable {
    enum Kind: String, Codable, Equatable, CaseIterable {
        case skillInstalled
        case skillRemoved
        case mcpEnabled
        case mcpDisabled
        case assignmentChanged
        case configChanged
        case updateApplied
        case rolledBack
        case findingAccepted
        case scanCompleted
        case quarantined
        case restored

        var label: String {
            switch self {
            case .skillInstalled: "Skill kuruldu"
            case .skillRemoved: "Skill kaldırıldı"
            case .mcpEnabled: "MCP etkinleştirildi"
            case .mcpDisabled: "MCP kapatıldı"
            case .assignmentChanged: "Assignment değişti"
            case .configChanged: "Config değişti"
            case .updateApplied: "Update yapıldı"
            case .rolledBack: "Rollback yapıldı"
            case .findingAccepted: "Security finding kabul edildi"
            case .scanCompleted: "Scan çalıştı"
            case .quarantined: "Karantinaya alındı"
            case .restored: "Geri yüklendi"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var extensionID: String?
    var agent: ExtensionAgentID?
    var detail: String
    var at: Date
    /// Transaction or revision this event can be undone through, when it can.
    var undoToken: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        extensionID: String? = nil,
        agent: ExtensionAgentID? = nil,
        detail: String,
        at: Date = .now,
        undoToken: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.extensionID = extensionID
        self.agent = agent
        self.detail = detail
        self.at = at
        self.undoToken = undoToken
    }

    var isUndoable: Bool { undoToken != nil }
}
