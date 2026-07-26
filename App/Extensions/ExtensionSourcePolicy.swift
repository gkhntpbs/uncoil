import Foundation

/// What Uncoil may do with an extension, decided by where it came from.
///
/// Every source class answers the same questions, so the UI never has to guess
/// and an operation can never be offered for a source that cannot support it —
/// a local folder has no update to check, and a remote server has no local git
/// revision to roll back to.
struct ExtensionSourceCapabilities: Equatable {
    /// Where the version shown to the user comes from.
    enum VersionSource: Equatable {
        case git
        case appBundle
        /// The running server reports it; the repo says nothing about it.
        case server
        case none

        var label: String {
            switch self {
            case .git: String(localized: "Git revision")
            case .appBundle: String(localized: "Uncoil version")
            case .server: String(localized: "Version reported by the server")
            case .none: String(localized: "No version information")
            }
        }
    }

    var canCheckForUpdates = false
    var canUpdate = false
    var canRollback = false
    var canCompareCommits = false
    var canScan = false
    var canRun = false
    var canAssign = false
    /// Uncoil may relink, quarantine or delete the files.
    var canManageFiles = false
    /// Shown read-only: Uncoil did not install it and will not touch it.
    var isReadOnly = false
    /// Offer "Adopt into Uncoil".
    var canAdopt = false
    /// Offer to attach a GitHub source later.
    var canLinkToRepository = false
    var canHealthCheck = false
    var versionSource = VersionSource.none

    static func of(_ source: ExtensionSource) -> ExtensionSourceCapabilities {
        switch source {
        case .managedGitHub:
            ExtensionSourceCapabilities(
                canCheckForUpdates: true, canUpdate: true, canRollback: true,
                canCompareCommits: true, canScan: true, canRun: true, canAssign: true,
                canManageFiles: true, isReadOnly: false, canAdopt: false,
                canLinkToRepository: false, canHealthCheck: true, versionSource: .git
            )
        case .bundled:
            // Ships inside the app: it moves with the app's version, and the
            // user changing it would be silently undone by the next update.
            ExtensionSourceCapabilities(
                canCheckForUpdates: false, canUpdate: false, canRollback: false,
                canCompareCommits: false, canScan: true, canRun: true, canAssign: true,
                canManageFiles: false, isReadOnly: true, canAdopt: false,
                canLinkToRepository: false, canHealthCheck: true, versionSource: .appBundle
            )
        case .local:
            // Runnable and assignable, scanned like anything else, never updated:
            // there is nothing to update from.
            ExtensionSourceCapabilities(
                canCheckForUpdates: false, canUpdate: false, canRollback: false,
                canCompareCommits: false, canScan: true, canRun: true, canAssign: true,
                canManageFiles: false, isReadOnly: false, canAdopt: false,
                canLinkToRepository: true, canHealthCheck: true, versionSource: .none
            )
        case .adopted:
            // The files are Uncoil's copies now: it may relink, quarantine or
            // remove them. There is still nothing to update from — adopting
            // takes over a copy, it does not invent a repository.
            ExtensionSourceCapabilities(
                canCheckForUpdates: false, canUpdate: false, canRollback: false,
                canCompareCommits: false, canScan: true, canRun: true, canAssign: true,
                canManageFiles: true, isReadOnly: false, canAdopt: false,
                canLinkToRepository: true, canHealthCheck: true, versionSource: .none
            )
        case .detectedExternal:
            // Uncoil did not install it, so it is shown and left alone until the
            // user adopts it.
            ExtensionSourceCapabilities(
                canCheckForUpdates: false, canUpdate: false, canRollback: false,
                canCompareCommits: false, canScan: true, canRun: false, canAssign: false,
                canManageFiles: false, isReadOnly: true, canAdopt: true,
                canLinkToRepository: false, canHealthCheck: false, versionSource: .none
            )
        case .remoteMCP:
            // No local files at all: nothing to scan, nothing to roll back, and
            // the version is whatever the server says it is.
            ExtensionSourceCapabilities(
                canCheckForUpdates: false, canUpdate: false, canRollback: false,
                canCompareCommits: false, canScan: false, canRun: true, canAssign: true,
                canManageFiles: false, isReadOnly: true, canAdopt: false,
                canLinkToRepository: false, canHealthCheck: true, versionSource: .server
            )
        }
    }
}

extension ExtensionSource {
    var capabilities: ExtensionSourceCapabilities { .of(self) }

    /// Turns a local folder into a managed GitHub source, keeping nothing from
    /// the old one but the fact that the user asked for it.
    func linkedToRepository(
        _ repository: String,
        subpath: String? = nil,
        tracking: TrackingMode = .branch("main")
    ) -> ExtensionSource? {
        guard capabilities.canLinkToRepository else { return nil }
        return .managedGitHub(repository: repository, subpath: subpath, tracking: tracking)
    }
}

/// The extensions shipped inside `Uncoil.app`.
///
/// The manifest is built at release time and carries a hash per file, so a
/// bundled extension that no longer matches what shipped is reported instead of
/// being run. That is the whole of "bundle signature validation" that Uncoil can
/// honestly do on its own resources: the app's own code signature covers the
/// bundle, and this covers the files inside it.
struct BundledExtensionCatalog {
    struct Entry: Equatable, Codable {
        var identifier: String
        var name: String
        var kind: ExtensionKind
        /// Path inside the bundle's resources.
        var relativePath: String
        /// SHA-256 of the file, or of the directory listing for a folder.
        var sha256: String
        var summary: String?
    }

    struct Manifest: Equatable, Codable {
        /// App version the manifest was built for.
        var appVersion: String
        var entries: [Entry]
    }

    enum Verification: Equatable {
        case verified
        case missing(String)
        case modified(String, expected: String, found: String)

        var isVerified: Bool { self == .verified }

        var message: String {
            switch self {
            case .verified: "Verified"
            case .missing(let path): "No such file: \(path)"
            case .modified(let path, _, _):
                "\(path) differs from what shipped in the bundle; it must not be run."
            }
        }
    }

    /// Resources root; overridable so tests need no app bundle.
    var resourcesDirectory: URL
    var appVersion: String

    static let manifestName = "bundled-extensions.json"

    func loadManifest() -> Manifest? {
        let url = resourcesDirectory.appendingPathComponent(Self.manifestName)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Whether the bundled set matches the running app. A manifest from another
    /// version means the app was updated and these files came with it.
    func isCurrent(_ manifest: Manifest) -> Bool {
        manifest.appVersion == appVersion
    }

    func verify(_ entry: Entry) -> Verification {
        let url = resourcesDirectory.appendingPathComponent(entry.relativePath)
        guard let digest = Self.digest(at: url) else {
            return .missing(entry.relativePath)
        }
        guard digest == entry.sha256 else {
            return .modified(entry.relativePath, expected: entry.sha256, found: digest)
        }
        return .verified
    }

    /// Packages for the entries that verified, marked bundled so the rest of the
    /// app treats them as read-only.
    func packages(now: Date = .now) -> (packages: [ExtensionPackage], failures: [Verification]) {
        guard let manifest = loadManifest() else { return ([], []) }
        var packages: [ExtensionPackage] = []
        var failures: [Verification] = []
        for entry in manifest.entries {
            let verification = verify(entry)
            guard verification.isVerified else {
                failures.append(verification)
                continue
            }
            packages.append(ExtensionPackage(
                id: "bundled:\(entry.identifier)",
                kind: entry.kind,
                name: entry.name,
                summary: entry.summary,
                source: .bundled(identifier: entry.identifier),
                state: .active,
                lastFetchedAt: now
            ))
        }
        return (packages, failures)
    }

    /// SHA-256 of a file, or of a directory's sorted `name:hash` listing.
    static func digest(at url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return AgentAdapterSupport.hash(String(decoding: data, as: UTF8.self))
        }
        guard let children = try? FileManager.default
            .contentsOfDirectory(atPath: url.path).sorted() else { return nil }
        let listing = children.compactMap { child -> String? in
            guard let hash = digest(at: url.appendingPathComponent(child)) else { return nil }
            return "\(child):\(hash)"
        }
        return AgentAdapterSupport.hash(listing.joined(separator: "\n"))
    }
}
