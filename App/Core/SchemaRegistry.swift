import Foundation

/// Every persisted shape Uncoil versions, in one place.
///
/// A store that writes a document without saying which schema it is cannot be
/// migrated later without guessing, and a backup taken from one version has to
/// be readable — or refused with a reason — by another. Both need this list to be
/// the single answer to "what version is this?".
enum UncoilSchema: String, CaseIterable, Codable, Identifiable {
    case projects
    case sessions
    case sessionGroups
    case presets
    case permissionPolicy
    case extensionRegistry
    case auditLog
    case securityFinding
    case runtimeProtocol
    case taskMetadata
    case taskResults
    case orchestrator

    var id: String { rawValue }

    /// Bump when the shape changes in a way an older reader cannot handle.
    var currentVersion: Int {
        switch self {
        case .projects: 1
        case .sessions: SessionRecord.currentMetadataVersion
        case .sessionGroups: 1
        case .presets: 1
        case .permissionPolicy: 1
        case .extensionRegistry: 1
        case .auditLog: 1
        case .securityFinding: 1
        case .runtimeProtocol: RuntimeProtocol.version
        case .taskMetadata: 1
        case .taskResults: 1
        case .orchestrator: 1
        }
    }

    /// File under the data directory, for the schemas that have one of their own.
    var fileName: String? {
        switch self {
        case .projects: "projects.json"
        case .sessions: "sessions.json"
        case .sessionGroups: "session-groups.json"
        case .presets: "presets.json"
        case .permissionPolicy: "permissions.json"
        case .extensionRegistry, .auditLog, .securityFinding, .runtimeProtocol,
             .taskMetadata, .taskResults, .orchestrator:
            // Under the extension store or a project directory, not a single
            // file at the top level.
            nil
        }
    }

    var label: String {
        switch self {
        case .projects: "Project list"
        case .sessions: "Session metadata"
        case .sessionGroups: "Session groups"
        case .presets: "Preset'ler"
        case .permissionPolicy: "Permission decisions"
        case .extensionRegistry: "Extension registry"
        case .auditLog: "Audit log"
        case .securityFinding: "Security finding"
        case .runtimeProtocol: "Runtime protocol"
        case .taskMetadata: "Task metadata"
        case .taskResults: "Task results"
        case .orchestrator: "Orchestrator plan"
        }
    }

    /// A document from the future is refused rather than half-read: an older
    /// build cannot know what a newer shape means.
    func canRead(version: Int) -> Bool {
        version > 0 && version <= currentVersion
    }

    /// Whether reading this version means migrating it forward on save.
    func needsMigration(from version: Int) -> Bool {
        canRead(version: version) && version < currentVersion
    }

    static var versions: [String: Int] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.currentVersion) })
    }
}

/// A document that carries its schema version, for the stores that used to write
/// a bare array.
struct VersionedDocument<Payload: Codable & Equatable>: Codable, Equatable {
    var schemaVersion: Int
    var payload: Payload

    init(schemaVersion: Int, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    /// Decodes either the versioned document or the legacy bare payload, so an
    /// existing installation keeps its data.
    static func decode(
        _ data: Data,
        schema: UncoilSchema,
        decoder: JSONDecoder = JSONDecoder()
    ) -> (payload: Payload, version: Int)? {
        if let document = try? decoder.decode(VersionedDocument<Payload>.self, from: data) {
            guard schema.canRead(version: document.schemaVersion) else { return nil }
            return (document.payload, document.schemaVersion)
        }
        guard let legacy = try? decoder.decode(Payload.self, from: data) else { return nil }
        return (legacy, 1)
    }
}
