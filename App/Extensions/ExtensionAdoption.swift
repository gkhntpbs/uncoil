import Foundation

/// Taking over an extension that was installed outside Uncoil.
///
/// Nothing is adopted on its own. The plan shows what would change and where the
/// backup goes; only then can the files be copied into Uncoil's store. An
/// external install the user never asked Uncoil to manage stays exactly as it is.
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
            if let added = counts[.added] { parts.append("\(added) yeni") }
            if let modified = counts[.modified] { parts.append("\(modified) değişen") }
            if let removed = counts[.removed] { parts.append("\(removed) kaybolan") }
            return parts.isEmpty ? "Dosya farkı yok" : parts.joined(separator: ", ")
        }
    }

    var layout: ExtensionStoreLayout

    /// Compares the external install with what Uncoil has, copies the current
    /// state to a backup, and returns the plan. Writes nothing else.
    func plan(
        name: String,
        kind: ExtensionKind,
        externalPath: String,
        findings: [SecurityFinding] = [],
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
            findings: findings
        )
    }

    /// Performs the adoption the plan describes. Refused when the plan has no
    /// backup or a blocking finding — the user is told, not surprised.
    func adopt(_ plan: Plan, now: Date = .now) throws -> ExtensionPackage {
        guard plan.isAdoptable else {
            throw AgentAdapterError.unsupportedChange(
                plan.blocksAdoption.isEmpty
                    ? "Yedek alınamadı; sahiplenme yapılmadı."
                    : "Güvenlik bulgusu sahiplenmeyi engelliyor: "
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
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: plan.externalPath), to: destination
        )
        return ExtensionPackage(
            id: "adopted:\(plan.name)",
            kind: plan.kind,
            name: plan.name,
            summary: "Uncoil dışında kurulmuşken sahiplenildi",
            // Adopting does not invent a repository: it becomes a local source,
            // and the user can attach a GitHub source afterwards.
            source: .local(path: destination.path),
            state: .active,
            lastFetchedAt: now
        )
    }

    /// Puts back what the plan's backup captured.
    func rollback(_ plan: Plan) throws {
        guard let backupPath = plan.backupPath else {
            throw AgentAdapterError.unsupportedChange("Geri alınacak yedek yok.")
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
