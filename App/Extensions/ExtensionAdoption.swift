import Foundation

/// Taking over an extension that was installed outside Uncoil.
///
/// Nothing is adopted on its own. The plan shows what would change and where the
/// backup goes; only then can the files be copied into Uncoil's store. An
/// external install the user never asked Uncoil to manage stays exactly as it is.
///
/// For a skill, adopting also collects the copies: the files move into the store
/// once, and each agent directory that held its own copy is backed up and
/// replaced with a symlink into that single copy. Without that step the agent
/// would keep reading its own folder and the adoption would show up nowhere.
@MainActor
struct ExtensionAdoptionService {
    struct FileChange: Equatable, Identifiable {
        enum Kind: String, Equatable {
            /// Only in the external install: adopting brings it in.
            case added
            /// In both, with different content: adopting overwrites Uncoil's copy.
            case modified
            /// Only in Uncoil's store: adopting would leave it behind.
            case removed
            case unchanged
        }

        var path: String
        var kind: Kind

        var id: String { path }
    }

    struct Plan: Equatable {
        var name: String
        var kind: ExtensionKind
        var externalPath: String
        /// Where Uncoil would put the files.
        var destinationPath: String
        var changes: [FileChange]
        /// Where the current state is copied first. Adoption without this is
        /// refused: it is what makes the step reversible.
        var backupPath: String?
        /// Findings from scanning the external files before adopting them.
        var findings: [SecurityFinding]
        /// Agent directories holding their own real copy of this skill. Adopting
        /// backs each one up and leaves a symlink into the store in its place.
        var agentCopies: [AgentCopy] = []
        /// For an MCP server there are no files to collect: what is taken over is
        /// the definition, which is written into the store as JSON.
        var definition: MCPServerDefinition?

        var changedFiles: [FileChange] {
            changes.filter { $0.kind != .unchanged }
        }

        var blocksAdoption: [SecurityFinding] {
            findings.filter { $0.severity == .blocked }
        }

        var isAdoptable: Bool { backupPath != nil && blocksAdoption.isEmpty }

        var summary: String {
            let counts = Dictionary(grouping: changedFiles, by: \.kind)
                .mapValues(\.count)
            var parts: [String] = []
            if let added = counts[.added] { parts.append("\(added) new") }
            if let modified = counts[.modified] { parts.append("\(modified) changed") }
            if let removed = counts[.removed] { parts.append("\(removed) kaybolan") }
            return parts.isEmpty ? "No file difference" : parts.joined(separator: ", ")
        }
    }

    /// One agent's own copy of a skill, and where it lives.
    struct AgentCopy: Equatable, Identifiable {
        var agent: ExtensionAgentID
        /// The agent's skills directory.
        var directory: String
        /// `directory/<name>` — the folder that becomes a symlink.
        var path: String

        var id: String { "\(agent.rawValue):\(path)" }
    }

    var layout: ExtensionStoreLayout
    var store: SkillStore

    init(layout: ExtensionStoreLayout, store: SkillStore? = nil) {
        self.layout = layout
        self.store = store ?? SkillStore(layout: layout)
    }

    /// Compares the external install with what Uncoil has, copies the current
    /// state to a backup, and returns the plan. Writes nothing else.
    func plan(
        name: String,
        kind: ExtensionKind,
        externalPath: String,
        findings: [SecurityFinding] = [],
        installations: [AgentInstallation] = [],
        now: Date = .now
    ) throws -> Plan {
        let external = URL(fileURLWithPath: externalPath)
        guard FileManager.default.fileExists(atPath: external.path) else {
            throw AgentAdapterError.configUnreadable(externalPath)
        }
        let destination = layout.revisions
            .appendingPathComponent("adopted", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let changes = Self.compare(external: external, existing: destination)

        // The backup is of whatever is there now — including "nothing", which is
        // recorded as an empty directory so a rollback can delete what we added.
        let backup = layout.backups
            .appendingPathComponent("adopt-\(name)-\(Int(now.timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: backup.appendingPathComponent("previous"))
            try FileManager.default.copyItem(
                at: destination, to: backup.appendingPathComponent("previous")
            )
        }

        return Plan(
            name: name,
            kind: kind,
            externalPath: external.path,
            destinationPath: destination.path,
            changes: changes,
            backupPath: backup.path,
            findings: findings,
            agentCopies: kind == .skill
                ? Self.agentCopies(of: name, installations: installations)
                : []
        )
    }

    /// The plan for an MCP server, which has no files on disk: what is adopted is
    /// the definition the agent configs declare. Secret VALUES never travel — the
    /// definition carries only the names of the variables the server needs.
    func planDefinition(
        _ definition: MCPServerDefinition,
        agents: [ExtensionAgentID] = [],
        findings: [SecurityFinding] = [],
        now: Date = .now
    ) throws -> Plan {
        let destination = layout.revisions
            .appendingPathComponent("adopted", isDirectory: true)
            .appendingPathComponent(definition.name, isDirectory: true)
        let backup = layout.backups.appendingPathComponent(
            "adopt-\(definition.name)-\(Int(now.timeIntervalSince1970))", isDirectory: true
        )
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: backup.appendingPathComponent("previous"))
            try FileManager.default.copyItem(
                at: destination, to: backup.appendingPathComponent("previous")
            )
        }
        return Plan(
            name: definition.name,
            kind: .mcpServer,
            externalPath: definition.displayTarget,
            destinationPath: destination.path,
            changes: [FileChange(path: Self.definitionFileName, kind: .added)],
            backupPath: backup.path,
            findings: findings,
            agentCopies: agents.map {
                AgentCopy(agent: $0, directory: "", path: definition.displayTarget)
            },
            definition: definition
        )
    }

    static let definitionFileName = "server.json"

    /// Agent directories that hold a real folder (not one of our symlinks) for
    /// this skill: exactly the copies adopting would collect into one.
    static func agentCopies(
        of name: String,
        installations: [AgentInstallation]
    ) -> [AgentCopy] {
        installations.compactMap { installation in
            guard let directory = installation.skillsDirectory else { return nil }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path)
            guard let type = attributes?[.type] as? FileAttributeType,
                  type == .typeDirectory else { return nil }
            return AgentCopy(
                agent: installation.agent, directory: directory, path: url.path
            )
        }
    }

    /// Performs the adoption the plan describes. Refused when the plan has no
    /// backup or a blocking finding — the user is told, not surprised.
    func adopt(_ plan: Plan, now: Date = .now) throws -> ExtensionPackage {
        guard plan.isAdoptable else {
            throw AgentAdapterError.unsupportedChange(
                plan.blocksAdoption.isEmpty
                    ? "No backup could be taken; nothing was adopted."
                    : "A security finding blocks adoption: "
                        + plan.blocksAdoption[0].message
            )
        }
        let destination = URL(fileURLWithPath: plan.destinationPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if let definition = plan.definition {
            // An MCP server has no files: the definition itself is what moves
            // into the store, so every agent points at one recorded shape.
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(definition).write(
                to: destination.appendingPathComponent(Self.definitionFileName), options: .atomic
            )
        } else {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: plan.externalPath), to: destination
            )
        }

        var revision: InstalledRevision?
        var collected: [AgentCopy] = []
        if plan.kind == .skill {
            revision = InstalledRevision(
                id: Self.revisionID(for: plan.name),
                commitSHA: nil,
                contentHash: SkillStore.contentHash(of: destination),
                path: destination.path,
                installedAt: now
            )
            // One copy, reachable from everywhere: the store's active pointer and
            // the shared `~/.agents/skills` location.
            try? store.activate(revisionID: Self.revisionID(for: plan.name), name: plan.name)
            _ = try? store.linkCanonical(name: plan.name)
            collected = try takeOverAgentCopies(plan)
        }

        if plan.definition != nil {
            revision = InstalledRevision(
                id: Self.revisionID(for: plan.name),
                commitSHA: nil,
                contentHash: SkillStore.contentHash(of: destination),
                path: destination.path,
                installedAt: now
            )
        }

        return ExtensionPackage(
            id: "adopted:\(plan.name)",
            kind: plan.kind,
            name: plan.name,
            summary: {
                if let definition = plan.definition {
                    return "Sahiplenildi · \(definition.transport.label) · \(definition.displayTarget)"
                }
                return collected.isEmpty
                    ? "Adopted while installed outside Uncoil"
                    : "Sahiplenildi; \(collected.map { $0.agent.displayName }.joined(separator: ", "))"
                        + " now reads the shared copy"
            }(),
            // Adopting does not invent a repository: the files are Uncoil's copy
            // now, and the user can attach a GitHub source afterwards.
            source: .adopted(path: destination.path),
            state: .active,
            activeRevision: revision,
            lastFetchedAt: now
        )
    }

    /// The revision id an adopted skill lives under, inside `revisions/`.
    static func revisionID(for name: String) -> String { "adopted/\(name)" }

    /// Backs up each agent's own folder and replaces it with a symlink into the
    /// store. A copy that cannot be backed up is left untouched rather than
    /// replaced — nothing here may lose the user's files.
    private func takeOverAgentCopies(_ plan: Plan) throws -> [AgentCopy] {
        guard let backupPath = plan.backupPath else { return [] }
        let backupRoot = URL(fileURLWithPath: backupPath)
            .appendingPathComponent("agents", isDirectory: true)
        var collected: [AgentCopy] = []
        for copy in plan.agentCopies {
            let source = URL(fileURLWithPath: copy.path)
            let backup = backupRoot
                .appendingPathComponent(copy.agent.rawValue, isDirectory: true)
                .appendingPathComponent(plan.name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: backup.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: backup)
                try FileManager.default.removeItem(at: source)
                _ = try store.link(
                    name: plan.name,
                    intoAgentDirectory: URL(fileURLWithPath: copy.directory)
                )
                collected.append(copy)
            } catch {
                // Put it back if the link failed after the folder was removed.
                if !FileManager.default.fileExists(atPath: source.path),
                   FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: backup, to: source)
                }
            }
        }
        return collected
    }

    /// Puts back what the plan's backup captured.
    func rollback(_ plan: Plan) throws {
        guard let backupPath = plan.backupPath else {
            throw AgentAdapterError.unsupportedChange("No backup to roll back to.")
        }
        let destination = URL(fileURLWithPath: plan.destinationPath)
        let previous = URL(fileURLWithPath: backupPath).appendingPathComponent("previous")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // No "previous" means there was nothing before: removing what we added is
        // the correct rollback.
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        try FileManager.default.copyItem(at: previous, to: destination)
    }

    /// File-level comparison of two trees. Pure apart from reading the disk.
    static func compare(external: URL, existing: URL) -> [FileChange] {
        let left = listing(external)
        let right = listing(existing)
        var changes: [FileChange] = []
        for (path, hash) in left.sorted(by: { $0.key < $1.key }) {
            if let other = right[path] {
                changes.append(FileChange(path: path, kind: other == hash ? .unchanged : .modified))
            } else {
                changes.append(FileChange(path: path, kind: .added))
            }
        }
        for path in right.keys.sorted() where left[path] == nil {
            changes.append(FileChange(path: path, kind: .removed))
        }
        return changes
    }

    /// Relative path → content hash for every file under `root`.
    static func listing(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        for file in FileTree.regularFiles(under: root) {
            guard let data = FileManager.default.contents(atPath: file.url.path) else { continue }
            result[file.relativePath] = AgentAdapterSupport
                .hash(String(decoding: data, as: UTF8.self))
        }
        return result
    }
}
