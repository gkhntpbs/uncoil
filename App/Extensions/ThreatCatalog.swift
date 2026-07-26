import Foundation

/// Bumblebee's threat catalog, versioned separately from the binary.
///
/// The two move independently on purpose: a catalog update should be able to add
/// a rule without shipping a new binary, and a binary update should not silently
/// change which rules ran. Only JSON is taken from the catalog repository —
/// nothing in it is ever executed.
struct ThreatCatalog: Equatable, Codable {
    struct Entry: Equatable, Codable, Identifiable {
        var id: String
        var severity: String
        var title: String
        var pattern: String?
        var references: [String] = []
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var catalogVersion: String
    /// Commit the catalog came from, so a finding is traceable to a rule set.
    var repositoryCommit: String?
    var repository: String?
    var entries: [Entry]
    var installedAt: Date

    var label: String {
        [catalogVersion, repositoryCommit.map { String($0.prefix(12)) }]
            .compactMap { $0 }
            .joined(separator: String(localized: " · "))
    }
}

/// Reads, validates, updates and rolls back the catalog.
struct ThreatCatalogStore {
    enum CatalogError: LocalizedError, Equatable {
        case invalidJSON(String)
        case unsupportedSchema(Int)
        case missingFields([String])
        case executableInCatalog([String])
        case noPreviousCatalog

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail): "Catalog JSON is invalid: \(detail)"
            case .unsupportedSchema(let version):
                "Catalog schema version \(version) is newer than this build of Uncoil."
            case .missingFields(let fields):
                "Catalog fields missing: \(fields.joined(separator: ", "))"
            case .executableInCatalog(let paths):
                "The catalog repo contains executable files; only JSON is taken: "
                    + paths.prefix(3).joined(separator: ", ")
            case .noPreviousCatalog: "No previous catalog to fall back to."
            }
        }
    }

    var directory: URL

    private var currentURL: URL { directory.appendingPathComponent("catalog.json") }
    private var previousURL: URL { directory.appendingPathComponent("catalog-previous.json") }

    // MARK: - Reading

    func current() -> ThreatCatalog? { read(currentURL) }
    func previous() -> ThreatCatalog? { read(previousURL) }

    private func read(_ url: URL) -> ThreatCatalog? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ThreatCatalog.self, from: data)
    }

    // MARK: - Validation

    /// Validates a catalog payload before it is installed. A catalog that does not
    /// validate is not installed at all — a half-understood rule set is worse than
    /// the previous one.
    static func validate(
        _ text: String,
        catalogVersion: String,
        repositoryCommit: String?,
        repository: String?,
        now: Date
    ) throws -> ThreatCatalog {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalidJSON("the root object could not be read")
        }
        let schema = root["schema_version"] as? Int ?? root["schemaVersion"] as? Int ?? 1
        guard schema <= ThreatCatalog.currentSchemaVersion else {
            throw CatalogError.unsupportedSchema(schema)
        }
        guard let rawEntries = root["entries"] as? [[String: Any]] ?? root["rules"] as? [[String: Any]] else {
            throw CatalogError.missingFields(["entries"])
        }
        var entries: [ThreatCatalog.Entry] = []
        var missing: Set<String> = []
        for raw in rawEntries {
            guard let id = raw["id"] as? String else {
                missing.insert("id")
                continue
            }
            guard let severity = raw["severity"] as? String else {
                missing.insert("severity")
                continue
            }
            guard let title = raw["title"] as? String ?? raw["message"] as? String else {
                missing.insert("title")
                continue
            }
            entries.append(ThreatCatalog.Entry(
                id: id,
                severity: severity,
                title: title,
                pattern: raw["pattern"] as? String,
                references: raw["references"] as? [String] ?? []
            ))
        }
        guard missing.isEmpty else { throw CatalogError.missingFields(missing.sorted()) }
        guard !entries.isEmpty else { throw CatalogError.missingFields(["entries"]) }
        return ThreatCatalog(
            schemaVersion: schema,
            catalogVersion: catalogVersion,
            repositoryCommit: repositoryCommit,
            repository: repository,
            entries: entries,
            installedAt: now
        )
    }

    /// Refuses a catalog checkout that carries anything runnable. The catalog is
    /// data; a script in it has no reason to exist and Uncoil will not copy it.
    static func rejectExecutables(in root: URL) throws {
        var offenders: [String] = []
        let scriptSuffixes = [".sh", ".bash", ".zsh", ".py", ".rb", ".js", ".mjs", ".command"]
        for file in FileTree.regularFiles(under: root) {
            if FileManager.default.isExecutableFile(atPath: file.url.path)
                || scriptSuffixes.contains(where: { file.relativePath.hasSuffix($0) }) {
                offenders.append(file.relativePath)
            }
        }
        guard offenders.isEmpty else {
            throw CatalogError.executableInCatalog(offenders.sorted())
        }
    }

    /// The JSON files a catalog update takes, and nothing else.
    static func catalogJSONFiles(in root: URL) -> [String] {
        FileTree.regularFiles(under: root)
            .filter { $0.url.pathExtension == "json" }
            .map(\.relativePath)
            .sorted()
    }

    // MARK: - Installing

    /// Installs a validated catalog, keeping the previous one for a rollback.
    @discardableResult
    func install(_ catalog: ThreatCatalog) throws -> ThreatCatalogUpdate {
        let before = current()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = FileManager.default.contents(atPath: currentURL.path) {
            try data.write(to: previousURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: currentURL, options: .atomic)
        return ThreatCatalogUpdate(from: before, to: catalog)
    }

    /// Puts the previous catalog back.
    @discardableResult
    func rollback() throws -> ThreatCatalog {
        guard let previous = previous() else { throw CatalogError.noPreviousCatalog }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(previous).write(to: currentURL, options: .atomic)
        try? FileManager.default.removeItem(at: previousURL)
        return previous
    }
}

/// What changed between two catalogs, and what should happen next.
struct ThreatCatalogUpdate: Equatable {
    var previousVersion: String?
    var newVersion: String
    var addedRules: [String]
    var removedRules: [String]
    var changedRules: [String]

    init(from previous: ThreatCatalog?, to next: ThreatCatalog) {
        previousVersion = previous?.catalogVersion
        newVersion = next.catalogVersion
        let before = Dictionary(
            (previous?.entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let after = Dictionary(
            next.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        addedRules = Set(after.keys).subtracting(before.keys).sorted()
        removedRules = Set(before.keys).subtracting(after.keys).sorted()
        changedRules = Set(before.keys).intersection(after.keys)
            .filter { before[$0] != after[$0] }
            .sorted()
    }

    var isEmpty: Bool {
        addedRules.isEmpty && removedRules.isEmpty && changedRules.isEmpty
    }

    /// A new rule set means the last scan was run against the old one, so a scan
    /// is due — that is the whole reason to update a catalog.
    var shouldRescan: Bool { !isEmpty }

    var summary: String {
        guard !isEmpty else { return String(localized: "No rule change") }
        var parts: [String] = []
        if !addedRules.isEmpty { parts.append(String(localized: "+\(addedRules.count) rules")) }
        if !removedRules.isEmpty { parts.append(String(localized: "-\(removedRules.count) rules")) }
        if !changedRules.isEmpty { parts.append(String(localized: "\(changedRules.count) rules changed")) }
        return parts.joined(separator: String(localized: " · "))
    }
}
