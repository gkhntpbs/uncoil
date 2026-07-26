import Foundation

/// One thing a backup can carry.
enum BackupContent: String, CaseIterable, Codable, Identifiable {
    case settings
    case projects
    case sessions
    case sessionGroups
    case presets
    case agentAssignments
    case extensionRegistry
    case extensionSources
    case permissionDecisions
    case extensionLocks
    /// Whole conversations. Off unless the user asks: they are the largest and
    /// most personal thing Uncoil holds.
    case transcripts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .settings: String(localized: "Uncoil settings")
        case .projects: String(localized: "Project list")
        case .sessions: String(localized: "Session metadata")
        case .sessionGroups: String(localized: "Session groups")
        case .presets: String(localized: "Presets")
        case .agentAssignments: String(localized: "Agent assignments")
        case .extensionRegistry: String(localized: "Extension registry")
        case .extensionSources: String(localized: "Skill/MCP source records")
        case .permissionDecisions: String(localized: "Permission decisions")
        case .extensionLocks: String(localized: "Extension lock files")
        case .transcripts: String(localized: "Transcripts")
        }
    }

    /// Everything that is included unless the user says otherwise.
    static var defaults: [BackupContent] {
        allCases.filter { $0 != .transcripts }
    }

    var isOptIn: Bool { self == .transcripts }

    var schema: UncoilSchema? {
        switch self {
        case .projects: .projects
        case .sessions: .sessions
        case .sessionGroups: .sessionGroups
        case .presets: .presets
        case .permissionDecisions: .permissionPolicy
        case .extensionRegistry, .extensionSources: .extensionRegistry
        case .settings, .agentAssignments, .extensionLocks, .transcripts: nil
        }
    }
}

/// A backup of Uncoil's own state.
///
/// Secrets are never in it. Values live in the Keychain and are referenced by
/// key name; a backup carries the reference, so restoring on another machine asks
/// for the secret again instead of quietly moving it.
struct UncoilBackup: Codable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable, Identifiable {
        /// Every content this one file answers for: the extension registry holds
        /// the packages, their sources and the agent assignments at once, and the
        /// file goes in the backup once.
        var contents: [BackupContent]
        /// Path relative to the data directory, so restore knows where it goes.
        var relativePath: String
        var schemaVersion: Int?
        /// The file exactly as it was, as text.
        var payload: String

        var id: String { relativePath }
    }

    var version = UncoilBackup.currentVersion
    var createdAt: Date
    var appVersion: String
    var schemaVersions: [String: Int]
    var entries: [Entry]
    var includesTranscripts: Bool

    func entries(for content: BackupContent) -> [Entry] {
        entries.filter { $0.contents.contains(content) }
    }
}

/// Builds and restores backups.
///
/// Restore is all-or-nothing: everything is written to a staging directory and
/// swapped in one step, so a failure half-way leaves the current state intact.
struct BackupService {
    /// Keys whose values must never appear in an export, whatever put them there.
    ///
    /// Specific on purpose: a bare "key" matches ordinary fields like a
    /// permission's own key, and dropping those would quietly cost the user real
    /// state to protect nothing.
    static let secretKeyPatterns = [
        "token", "secret", "password", "passphrase", "credential",
        "api_key", "apikey", "api-key", "access_key", "private_key", "client_secret",
    ]

    enum RestoreProblem: Equatable, Error {
        case unreadableBackup(String)
        case unsupportedBackupVersion(Int)
        case unknownSchema(String, version: Int)
        case missingExtensionSource(name: String, detail: String)
        case reinstallableFromCommit(name: String, repository: String, commit: String)
        case manualExtensionFilesMissing(name: String, path: String)
        case agentConfigWouldChange(agent: String, detail: String)

        var isFatal: Bool {
            switch self {
            case .unreadableBackup, .unsupportedBackupVersion, .unknownSchema: true
            case .missingExtensionSource, .reinstallableFromCommit,
                 .manualExtensionFilesMissing, .agentConfigWouldChange:
                false
            }
        }

        var message: String {
            switch self {
            case .unreadableBackup(let detail): "The backup could not be read: \(detail)"
            case .unsupportedBackupVersion(let version):
                "The backup's version \(version) is newer than this build of Uncoil; nothing was restored."
            case .unknownSchema(let name, let version):
                "\(name)'s schema version \(version) cannot be read."
            case .missingExtensionSource(let name, let detail):
                "\(name)'s source is missing: \(detail)"
            case .reinstallableFromCommit(let name, let repository, let commit):
                "\(name) can be reinstalled from \(repository) at commit \(String(commit.prefix(12)))."
            case .manualExtensionFilesMissing(let name, let path):
                "\(name) was added by hand and its files are gone: \(path)"
            case .agentConfigWouldChange(let agent, let detail):
                "\(agent)'s config will change: \(detail)"
            }
        }
    }

    struct RestorePreview: Equatable {
        var backup: UncoilBackup?
        var problems: [RestoreProblem]
        /// What would be written, relative to the data directory.
        var files: [String]

        var isRestorable: Bool {
            backup != nil && !problems.contains { $0.isFatal }
        }

        var fatalProblems: [RestoreProblem] { problems.filter(\.isFatal) }
        var warnings: [RestoreProblem] { problems.filter { !$0.isFatal } }
    }

    var dataDirectory: URL
    var extensionLayout: ExtensionStoreLayout
    var appVersion: String

    // MARK: - Backup

    /// Reads the current state into a backup. Nothing is written.
    func build(
        contents: [BackupContent] = BackupContent.defaults,
        now: Date = .now
    ) -> UncoilBackup {
        var entries: [UncoilBackup.Entry] = []
        var indexByPath: [String: Int] = [:]
        for content in contents {
            for file in files(for: content) {
                if let index = indexByPath[file.relativePath] {
                    entries[index].contents.append(content)
                    continue
                }
                guard let data = FileManager.default.contents(atPath: file.url.path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                guard !Self.looksLikeASecret(text) else { continue }
                indexByPath[file.relativePath] = entries.count
                entries.append(UncoilBackup.Entry(
                    contents: [content],
                    relativePath: file.relativePath,
                    schemaVersion: content.schema.map { schema in
                        Self.declaredVersion(in: text) ?? schema.currentVersion
                    },
                    payload: text
                ))
            }
        }
        return UncoilBackup(
            createdAt: now,
            appVersion: appVersion,
            schemaVersions: UncoilSchema.versions,
            entries: entries,
            includesTranscripts: contents.contains(.transcripts)
        )
    }

    /// Where each kind of content lives.
    func files(for content: BackupContent) -> [(url: URL, relativePath: String)] {
        func data(_ name: String) -> [(URL, String)] {
            [(dataDirectory.appendingPathComponent(name), name)]
        }
        switch content {
        case .settings: return data("settings.json").map { ($0.0, $0.1) }
        case .projects: return data("projects.json").map { ($0.0, $0.1) }
        case .sessions: return data("sessions.json").map { ($0.0, $0.1) }
        case .sessionGroups: return data("session-groups.json").map { ($0.0, $0.1) }
        case .presets: return data("presets.json").map { ($0.0, $0.1) }
        case .permissionDecisions: return data("permissions.json").map { ($0.0, $0.1) }
        case .agentAssignments, .extensionRegistry, .extensionSources:
            let url = extensionLayout.locks.appendingPathComponent("registry.json")
            return [(url, "extensions/locks/registry.json")]
        case .extensionLocks:
            return contents(of: extensionLayout.locks, prefix: "extensions/locks")
        case .transcripts:
            return contents(
                of: dataDirectory.appendingPathComponent("transcripts", isDirectory: true),
                prefix: "transcripts"
            )
        }
    }

    private func contents(
        of directory: URL,
        prefix: String
    ) -> [(url: URL, relativePath: String)] {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: directory.path).sorted() else { return [] }
        return names.map {
            (directory.appendingPathComponent($0), "\(prefix)/\($0)")
        }
    }

    /// A payload that carries a secret value is left out rather than exported.
    static func looksLikeASecret(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        return containsSecretValue(root)
    }

    private static func containsSecretValue(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let lowered = key.lowercased()
                if secretKeyPatterns.contains(where: { lowered.contains($0) }),
                   let text = child as? String, !text.isEmpty, text.count > 8 {
                    return true
                }
                if containsSecretValue(child) { return true }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains { containsSecretValue($0) }
        }
        return false
    }

    static func declaredVersion(in text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["schemaVersion"] as? Int ?? root["version"] as? Int
    }

    // MARK: - Restore

    /// Validates a backup and reports what restoring it would mean. Writes
    /// nothing, so the user reads this first.
    func preview(_ backup: UncoilBackup, installedPackages: [ExtensionPackage] = []) -> RestorePreview {
        var problems: [RestoreProblem] = []
        if backup.version > UncoilBackup.currentVersion {
            problems.append(.unsupportedBackupVersion(backup.version))
        }
        for entry in backup.entries {
            guard let version = entry.schemaVersion else { continue }
            for schema in entry.contents.compactMap(\.schema)
            where !schema.canRead(version: version) {
                problems.append(.unknownSchema(schema.label, version: version))
            }
        }
        problems.append(contentsOf: extensionProblems(in: backup, installed: installedPackages))
        return RestorePreview(
            backup: backup,
            problems: problems,
            files: backup.entries.map(\.relativePath).sorted()
        )
    }

    /// Extensions the backup expects: what can be reinstalled from a commit, and
    /// what cannot be recovered at all.
    func extensionProblems(
        in backup: UncoilBackup,
        installed: [ExtensionPackage]
    ) -> [RestoreProblem] {
        var problems: [RestoreProblem] = []
        for package in expectedPackages(in: backup) {
            let isPresent = installed.contains { $0.id == package.id }
            switch package.source {
            case .managedGitHub(let repository, _, _):
                guard !isPresent else { continue }
                if let commit = package.activeRevision?.commitSHA {
                    problems.append(
                        .reinstallableFromCommit(
                            name: package.name, repository: repository, commit: commit
                        )
                    )
                } else {
                    problems.append(.missingExtensionSource(
                        name: package.name, detail: "No commit recorded for \(repository)"
                    ))
                }
            case .local(let path), .adopted(let path), .detectedExternal(let path):
                if !FileManager.default.fileExists(atPath: path) {
                    problems.append(
                        .manualExtensionFilesMissing(name: package.name, path: path)
                    )
                }
            case .bundled, .remoteMCP:
                continue
            }
        }
        return problems
    }

    /// Packages recorded in the backup's registry payload.
    func expectedPackages(in backup: UncoilBackup) -> [ExtensionPackage] {
        guard let entry = backup.entries(for: .extensionRegistry).first,
              let data = entry.payload.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ExtensionRegistry.Document.self, from: data))?.packages ?? []
    }

    /// Agent config changes the restore implies, for the preview. Restoring does
    /// not write agent configs — it says what would have to change.
    func agentConfigPreview(
        backup: UncoilBackup,
        currentConfigurations: [AgentConfiguration]
    ) -> [RestoreProblem] {
        let expected = Set(
            expectedPackages(in: backup)
                .filter { $0.kind == .mcpServer }
                .map(\.name)
        )
        var problems: [RestoreProblem] = []
        for configuration in currentConfigurations {
            let present = Set(configuration.mcpServers.map(\.name))
            let missing = expected.subtracting(present).sorted()
            guard !missing.isEmpty else { continue }
            problems.append(.agentConfigWouldChange(
                agent: configuration.installation.agent.displayName,
                detail: "eklenecek MCP: \(missing.joined(separator: ", "))"
            ))
        }
        return problems
    }

    /// Applies the backup as one transaction: staged, then swapped. A failure
    /// leaves the current state untouched.
    @discardableResult
    func restore(_ backup: UncoilBackup, now: Date = .now) throws -> [String] {
        let preview = preview(backup)
        guard preview.isRestorable else {
            throw AgentAdapterError.unsupportedChange(
                preview.fatalProblems.first?.message ?? "The backup cannot be restored."
            )
        }
        let staging = dataDirectory
            .appendingPathComponent(".restore-\(Int(now.timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Stage everything first: a payload that cannot be written must not leave
        // half the files replaced.
        for entry in backup.entries {
            let url = staging.appendingPathComponent(entry.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(entry.payload.utf8).write(to: url)
        }

        // Keep the current state so a failure part-way can be undone.
        let rollback = dataDirectory
            .appendingPathComponent(".restore-previous-\(Int(now.timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        var written: [String] = []
        do {
            for entry in backup.entries where !written.contains(entry.relativePath) {
                let destination = destinationURL(for: entry.relativePath)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let saved = rollback.appendingPathComponent(entry.relativePath)
                    try FileManager.default.createDirectory(
                        at: saved.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: destination, to: saved)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let staged = staging.appendingPathComponent(entry.relativePath)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: staged, to: destination)
                written.append(entry.relativePath)
            }
        } catch {
            for relativePath in written {
                let destination = destinationURL(for: relativePath)
                let saved = rollback.appendingPathComponent(relativePath)
                try? FileManager.default.removeItem(at: destination)
                if FileManager.default.fileExists(atPath: saved.path) {
                    try? FileManager.default.copyItem(at: saved, to: destination)
                }
            }
            try? FileManager.default.removeItem(at: rollback)
            throw error
        }
        try? FileManager.default.removeItem(at: rollback)
        return written
    }

    /// Where a relative path from the backup belongs on disk.
    func destinationURL(for relativePath: String) -> URL {
        if relativePath.hasPrefix("extensions/") {
            return extensionLayout.root
                .appendingPathComponent(String(relativePath.dropFirst("extensions/".count)))
        }
        return dataDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Files

    func write(_ backup: UncoilBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(backup).write(to: url, options: .atomic)
    }

    func read(_ url: URL) -> Result<UncoilBackup, RestoreProblem> {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .failure(.unreadableBackup("no file"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let backup = try decoder.decode(UncoilBackup.self, from: data)
            guard backup.version <= UncoilBackup.currentVersion else {
                return .failure(.unsupportedBackupVersion(backup.version))
            }
            return .success(backup)
        } catch {
            return .failure(.unreadableBackup(error.localizedDescription))
        }
    }
}
