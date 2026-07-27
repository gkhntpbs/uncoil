import Foundation

// MARK: - Providers

/// Where a catalog entry comes from. One case per remote source, so a new
/// registry is a new case plus a provider — the UI and the install path stay
/// as they are.
enum CatalogProviderID: String, Codable, CaseIterable, Sendable {
    case mcpRegistry
    case gitHub
    /// Dormant: kept as a possible future provider, not in the default path
    /// (its API requires a key Uncoil will not ask the user for).
    case skillsSh

    var label: String {
        switch self {
        case .mcpRegistry: String(localized: "Official MCP Registry")
        case .gitHub: "GitHub"
        case .skillsSh: "skills.sh"
        }
    }
}

/// The sections a catalog can show. The MCP registry has no popularity data,
/// so it only offers `.popular` (plain registry order).
enum CatalogView: String, CaseIterable, Identifiable {
    case featured
    case popular
    case trending
    case recentlyUpdated
    case newest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .featured: String(localized: "Featured")
        case .popular: String(localized: "Popular")
        case .trending: String(localized: "Trending")
        case .recentlyUpdated: String(localized: "Updated")
        case .newest: String(localized: "New")
        }
    }
}

// MARK: - Item

/// One entry of a remote catalog, normalised across providers. Type-specific
/// facts stay in `mcp` / `skill` so nothing is flattened into strings.
struct CatalogItem: Identifiable, Equatable {
    /// Stable across pages and refreshes: provider + canonical name.
    var id: String { "\(provider.rawValue):\(name)" }

    var kind: ExtensionKind
    var provider: CatalogProviderID
    /// Canonical identifier at the provider: reverse-DNS for the MCP registry
    /// ("com.example/server"), "owner/repo/slug" for skills.sh.
    var name: String
    var displayName: String
    var summary: String?
    /// Repository owner or registry namespace.
    var publisher: String?
    /// "owner/repo" when the entry names a GitHub repository.
    var repository: String?
    var repositoryURL: String?
    var version: String?
    var publishedAt: Date?
    var updatedAt: Date?
    /// Install count where the provider actually reports one. Never a star
    /// count — the two are labelled apart.
    var installs: Int?
    /// Repository stars, when the provider is repository-backed.
    var stars: Int?
    /// Install delta a trending view reports.
    var trendDelta: Int?
    var license: String?
    var topics: [String] = []
    /// True for entries the official MCP registry marks as its own record.
    var isOfficial: Bool = false
    /// True when the entry came from Uncoil's curated seed list. Curation is
    /// a discovery signal, not a safety claim.
    var isCurated: Bool = false
    /// active / deprecated / deleted, verbatim from the registry.
    var registryStatus: String?
    var audits: [CatalogAudit] = []
    var mcp: MCPCatalogDetails?
    var skill: SkillCatalogDetails?

    var isDeprecated: Bool {
        registryStatus == "deprecated" || registryStatus == "deleted"
    }

    /// The short name an install would use ("server" out of
    /// "com.example/server", "slug" out of "owner/repo/slug").
    var installName: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}

/// A third-party security audit the provider reports. Catalog inclusion is not
/// proof of safety; these are shown as what they are — someone's review.
struct CatalogAudit: Equatable {
    var provider: String
    /// pass / warn / fail, verbatim.
    var status: String
    var riskLevel: String?
    var summary: String?
    var auditedAt: Date?

    var isFailing: Bool { status.lowercased() == "fail" }
}

// MARK: - MCP specifics

struct MCPCatalogDetails: Equatable {
    var packages: [MCPCatalogPackage] = []
    var remotes: [MCPCatalogRemote] = []

    /// Something Uncoil can actually turn into an agent config entry.
    var hasInstallableForm: Bool {
        remotes.contains { $0.transport != nil }
            || packages.contains { $0.runtime != nil }
    }
}

struct MCPCatalogPackage: Equatable {
    var registryType: String
    var identifier: String
    var version: String?
    var runtimeHint: String?
    var transportType: String?
    var runtimeArguments: [String] = []
    var packageArguments: [String] = []
    var environmentVariables: [CatalogEnvVar] = []

    /// The local command that runs this package, or nil when Uncoil does not
    /// know how to run this registry type.
    var runtime: (command: String, arguments: [String])? {
        let pinned = version.map { "\(identifier)@\($0)" } ?? identifier
        switch registryType {
        case "npm":
            let head = runtimeArguments.isEmpty ? ["-y"] : runtimeArguments
            return (runtimeHint ?? "npx", head + [pinned] + packageArguments)
        case "pypi":
            let pinnedPy = version.map { "\(identifier)==\($0)" } ?? identifier
            return (runtimeHint ?? "uvx", runtimeArguments + [pinnedPy] + packageArguments)
        case "oci":
            let image = identifier.contains(":") ? identifier
                : (version.map { "\(identifier):\($0)" } ?? identifier)
            return ("docker", ["run", "-i", "--rm"] + runtimeArguments + [image] + packageArguments)
        default:
            return nil
        }
    }

    var label: String {
        "\(registryType) · \(identifier)\(version.map { " \($0)" } ?? "")"
    }
}

/// One environment variable an MCP package declares. Only names and metadata —
/// secret values never enter the catalog layer.
struct CatalogEnvVar: Equatable, Identifiable {
    var name: String
    var summary: String?
    var isRequired = false
    var isSecret = false
    var defaultValue: String?

    var id: String { name }

    /// Secret by its own declaration or by the name looking like one.
    @MainActor
    var isEffectivelySecret: Bool {
        isSecret || AgentAdapterSupport.isSecretKey(name)
    }
}

struct MCPCatalogRemote: Equatable {
    /// streamable-http / sse, verbatim.
    var type: String
    var url: String

    /// Uncoil's config model only knows stdio and HTTP; SSE endpoints are
    /// spoken over HTTP too.
    var transport: MCPTransport? {
        switch type {
        case "streamable-http", "sse", "http": .http
        default: nil
        }
    }

    var label: String { "\(type) · \(url)" }
}

/// One published version of an MCP registry server, for the release history.
struct CatalogVersionEntry: Equatable, Identifiable {
    var version: String
    var publishedAt: Date?
    var isLatest: Bool
    var status: String?

    var id: String { version }
}

// MARK: - Skill specifics

struct SkillCatalogDetails: Equatable {
    /// "owner/repo" of the repository the skill lives in.
    var source: String
    var slug: String
    /// Content hash the provider reports for the current files, when it has one.
    var contentHash: String?
    /// The exact commit the files were read at, for repository-backed skills.
    var commitSHA: String?
    /// Path of the skill inside the repository. Empty for a root-level skill.
    var directory: String = ""
    var defaultBranch: String?
    /// Every valid skill found in the repository — a repo is not assumed to
    /// be a single skill. Present after a detail fetch.
    var availableSkills: [SkillLocation] = []
    /// Full file set of the selected skill, present only after a detail fetch.
    var files: [SkillCatalogFile]?

    /// What an install pins to and what the update check compares against.
    var pinRef: String? { commitSHA ?? contentHash }

    struct SkillLocation: Equatable, Identifiable {
        /// "" for the repository root.
        var directory: String
        var slug: String

        var id: String { directory.isEmpty ? "/" : directory }

        var label: String {
            directory.isEmpty ? String(localized: "\(slug) (repository root)") : directory
        }
    }
}

struct SkillCatalogFile: Equatable, Identifiable {
    var path: String
    var contents: String
    /// Set when the file is not UTF-8 text; staging writes these bytes
    /// verbatim so assets survive the trip.
    var binaryContents: Data?

    var id: String { path }

    var byteCount: Int { binaryContents?.count ?? contents.utf8.count }
}

// MARK: - Pages and queries

struct CatalogPage: Equatable {
    var items: [CatalogItem]
    /// Opaque cursor for the next page; nil when this was the last one.
    var nextCursor: String?
    /// True when the data came from the disk cache because the network failed.
    var isFromCache = false
}

struct CatalogQuery: Equatable {
    var search = ""
    var view: CatalogView = .popular
    var cursor: String?
}

// MARK: - Installed state

/// How a catalog entry relates to what is already on this machine.
enum CatalogInstalledState: Equatable {
    case notInstalled
    case installed
    case updateAvailable
    /// Nothing on this machine can run it (no installable form, or no agent
    /// that supports its transport).
    case incompatible(String)

    var label: String? {
        switch self {
        case .notInstalled: nil
        case .installed: String(localized: "Installed")
        case .updateAvailable: String(localized: "Update")
        case .incompatible: String(localized: "Incompatible")
        }
    }
}

/// GitHub facts used to enrich a detail view. Secondary information only: the
/// catalog works without it.
struct CatalogRepoFacts: Equatable {
    var stars: Int?
    var forks: Int?
    var license: String?
    var pushedAt: Date?
    var archived: Bool?
    var defaultBranch: String?
}

// MARK: - Shared date parsing

enum CatalogDates {
    /// The registries mix fractional and whole-second ISO8601; both are read.
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
