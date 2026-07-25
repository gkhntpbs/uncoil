import CryptoKit
import Foundation

/// On-disk layout of the central extension store.
///
/// ```text
/// ~/.uncoil/extensions/
/// ├── mirrors/        one bare git mirror per repository
/// ├── revisions/      immutable checkout per commit
/// ├── active/skills/  the skill each agent's symlinks point at
/// ├── locks/          skill-lock.json / extensions.lock.json
/// ├── scans/          scan output kept for diffing
/// └── audit/          append-only audit log
/// ```
struct ExtensionStoreLayout: Equatable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The real store, under the user's home rather than Application Support:
    /// agents outside Uncoil have to be able to find these paths too.
    static func `default`() -> ExtensionStoreLayout {
        ExtensionStoreLayout(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".uncoil/extensions", isDirectory: true)
        )
    }

    var mirrors: URL { root.appendingPathComponent("mirrors", isDirectory: true) }
    var revisions: URL { root.appendingPathComponent("revisions", isDirectory: true) }
    var active: URL { root.appendingPathComponent("active", isDirectory: true) }
    var activeSkills: URL { active.appendingPathComponent("skills", isDirectory: true) }
    var locks: URL { root.appendingPathComponent("locks", isDirectory: true) }
    var scans: URL { root.appendingPathComponent("scans", isDirectory: true) }
    var audit: URL { root.appendingPathComponent("audit", isDirectory: true) }
    /// Snapshots taken before a step that would overwrite files Uncoil did not
    /// write — adopting an external install, for instance.
    var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }

    var allDirectories: [URL] {
        [mirrors, revisions, activeSkills, locks, scans, audit, backups]
    }

    func ensure() throws {
        for directory in allDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func mirror(forRepository repository: String) -> URL {
        mirrors.appendingPathComponent("\(Self.slug(repository)).git", isDirectory: true)
    }

    func revision(_ id: String) -> URL {
        revisions.appendingPathComponent(id, isDirectory: true)
    }

    func activeSkill(_ name: String) -> URL {
        activeSkills.appendingPathComponent(name, isDirectory: true)
    }

    /// Filesystem-safe name for a repository ("owner/repo" → "owner-repo"), so
    /// two skills from one repo share a single mirror.
    static func slug(_ repository: String) -> String {
        let allowed = repository.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "." ? character : "-"
        }
        return String(allowed).lowercased()
    }
}

/// What Uncoil found where an agent's per-skill symlink should be.
enum SkillLinkStatus: Equatable {
    /// Symlink present and pointing at the expected active skill.
    case linked
    /// Nothing there at all.
    case missing
    /// Symlink present but its target no longer exists.
    case broken(target: String)
    /// Symlink present, pointing somewhere else — changed outside Uncoil.
    case wrongTarget(String)
    /// A real file or directory the user owns. Never overwritten.
    case foreign

    var needsRepair: Bool {
        switch self {
        case .linked, .foreign: false
        case .missing, .broken, .wrongTarget: true
        }
    }

    /// Only Uncoil-created links may be repaired; a user's own folder is left
    /// exactly as it is.
    var isRepairable: Bool {
        switch self {
        case .missing, .broken, .wrongTarget: true
        case .linked, .foreign: false
        }
    }

    var label: String {
        switch self {
        case .linked: "Bağlı"
        case .missing: "Bağlantı yok"
        case .broken: "Kırık bağlantı"
        case .wrongTarget: "Yanlış hedefe bağlı"
        case .foreign: "Kullanıcının kendi skill'i"
        }
    }
}

enum SkillStoreError: LocalizedError, Equatable {
    case notASkill(String)
    case alreadyExists(String)
    case foreignEntry(String)
    case linkFailed(String)

    var errorDescription: String? {
        switch self {
        case .notASkill(let path):
            "\(path) bir skill değil (SKILL.md yok)."
        case .alreadyExists(let name):
            "\(name) merkezi depoda zaten var."
        case .foreignEntry(let path):
            "\(path) Uncoil'e ait değil; üzerine yazılmadı."
        case .linkFailed(let detail):
            "Symlink oluşturulamadı: \(detail)"
        }
    }
}

/// The central skill store: one physical copy per skill, linked into each
/// agent's own skills directory one symlink at a time.
///
/// Rules it never breaks:
/// - the whole `skills` folder is never replaced by a single symlink
/// - a real file or folder the user created is never overwritten or deleted
/// - unlinking from an agent leaves the central copy intact
@MainActor
struct SkillStore {
    var layout: ExtensionStoreLayout
    /// Shared canonical location every agent can read: `~/.agents/skills`.
    var canonicalRoot: URL

    init(
        layout: ExtensionStoreLayout = .default(),
        canonicalRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills", isDirectory: true)
    ) {
        self.layout = layout
        self.canonicalRoot = canonicalRoot
    }

    // MARK: - Central copy

    /// Copies a skill into an immutable revision directory and links it as the
    /// active copy. The source is left untouched.
    @discardableResult
    func install(
        from source: URL,
        name: String,
        revisionID: String,
        commitSHA: String? = nil,
        now: Date = .now
    ) throws -> InstalledRevision {
        guard Self.isSkillDirectory(source) else {
            throw SkillStoreError.notASkill(source.path)
        }
        try layout.ensure()
        let revision = layout.revision(revisionID)
        if !FileManager.default.fileExists(atPath: revision.path) {
            try FileManager.default.createDirectory(
                at: revision.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: revision)
        }
        try activate(revisionID: revisionID, name: name)
        return InstalledRevision(
            id: revisionID,
            commitSHA: commitSHA,
            contentHash: Self.contentHash(of: revision),
            path: revision.path,
            installedAt: now
        )
    }

    /// Points `active/skills/<name>` at a revision by replacing the symlink,
    /// so a running agent never sees a half-updated directory.
    func activate(revisionID: String, name: String) throws {
        try layout.ensure()
        let link = layout.activeSkill(name)
        let target = layout.revision(revisionID)
        try replaceSymlink(at: link, with: target)
    }

    /// Removes the active pointer. Revisions are kept: garbage collection is a
    /// separate, explicit step.
    func deactivate(name: String) throws {
        let link = layout.activeSkill(name)
        guard isSymlink(link) else {
            if FileManager.default.fileExists(atPath: link.path) {
                throw SkillStoreError.foreignEntry(link.path)
            }
            return
        }
        try FileManager.default.removeItem(at: link)
    }

    // MARK: - Canonical + per-agent links

    /// Links the active copy into `~/.agents/skills/<name>`, the location every
    /// agent can share.
    @discardableResult
    func linkCanonical(name: String) throws -> String {
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        let link = canonicalRoot.appendingPathComponent(name, isDirectory: true)
        try replaceSymlink(at: link, with: layout.activeSkill(name))
        return link.path
    }

    /// One symlink per skill inside the agent's own skills directory. The
    /// directory itself is created if missing but never replaced.
    @discardableResult
    func link(name: String, intoAgentDirectory directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(name, isDirectory: true)
        try replaceSymlink(at: link, with: layout.activeSkill(name))
        return link.path
    }

    /// Removes only the agent's symlink; the central copy and every other
    /// agent's link stay in place.
    func unlink(name: String, fromAgentDirectory directory: URL) throws {
        let link = directory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: link.path) || isSymlink(link) else { return }
        guard isSymlink(link) else {
            throw SkillStoreError.foreignEntry(link.path)
        }
        try FileManager.default.removeItem(at: link)
    }

    // MARK: - Maintenance

    /// Health of the store's own `active/skills/<name>` pointer, which points at
    /// a revision rather than at another link.
    func activeStatus(name: String, expectedRevisionID: String? = nil) -> SkillLinkStatus {
        let link = layout.activeSkill(name)
        guard isSymlink(link) else {
            return FileManager.default.fileExists(atPath: link.path) ? .foreign : .missing
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return .broken(target: "?")
        }
        let resolved = resolve(target, relativeTo: link)
        if let expectedRevisionID, resolved != layout.revision(expectedRevisionID).path {
            return .wrongTarget(resolved)
        }
        guard resolved.hasPrefix(layout.revisions.path) else { return .wrongTarget(resolved) }
        guard FileManager.default.fileExists(atPath: resolved) else {
            return .broken(target: resolved)
        }
        return .linked
    }

    func status(name: String, inAgentDirectory directory: URL) -> SkillLinkStatus {
        let link = directory.appendingPathComponent(name, isDirectory: true)
        guard isSymlink(link) else {
            return FileManager.default.fileExists(atPath: link.path) ? .foreign : .missing
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return .broken(target: "?")
        }
        let resolved = resolve(target, relativeTo: link)
        let expected = layout.activeSkill(name).path
        guard resolved == expected else { return .wrongTarget(resolved) }
        guard FileManager.default.fileExists(atPath: resolved) else {
            return .broken(target: resolved)
        }
        return .linked
    }

    /// Re-points a repairable link. A foreign entry is reported, never touched.
    @discardableResult
    func repair(name: String, inAgentDirectory directory: URL) throws -> SkillLinkStatus {
        let current = status(name: name, inAgentDirectory: directory)
        guard current.isRepairable else { return current }
        _ = try link(name: name, intoAgentDirectory: directory)
        return status(name: name, inAgentDirectory: directory)
    }

    /// Links under `directory` that point into this store but no longer have an
    /// active skill behind them — what to clean up after an uninstall.
    func orphanedLinks(in directory: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return [] }
        return entries.compactMap { entry -> String? in
            guard isSymlink(entry),
                  let target = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: entry.path) else { return nil }
            let resolved = resolve(target, relativeTo: entry)
            guard resolved.hasPrefix(layout.activeSkills.path),
                  !FileManager.default.fileExists(atPath: resolved) else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }

    /// Removes the orphaned links this store created, leaving user files alone.
    @discardableResult
    func removeOrphanedLinks(in directory: URL) -> [String] {
        let orphans = orphanedLinks(in: directory)
        for name in orphans {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name, isDirectory: true)
            )
        }
        return orphans
    }

    /// Skill directories the user maintains by hand — present but not one of
    /// our symlinks. Listed so the UI can show them as unmanaged.
    func unmanagedSkills(in directory: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry -> String? in
            guard !isSymlink(entry), Self.isSkillDirectory(entry) else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }

    /// True when the active files no longer hash to what the revision recorded.
    func hasLocalModification(_ revision: InstalledRevision) -> Bool {
        let url = URL(fileURLWithPath: revision.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return Self.contentHash(of: url) != revision.contentHash
    }

    // MARK: - Primitives

    private func replaceSymlink(at link: URL, with target: URL) throws {
        let manager = FileManager.default
        if isSymlink(link) {
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            // A real directory here belongs to the user.
            throw SkillStoreError.foreignEntry(link.path)
        }
        do {
            try manager.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            throw SkillStoreError.linkFailed(error.localizedDescription)
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func resolve(_ target: String, relativeTo link: URL) -> String {
        target.hasPrefix("/")
            ? URL(fileURLWithPath: target).standardizedFileURL.path
            : link.deletingLastPathComponent()
                .appendingPathComponent(target).standardizedFileURL.path
    }

    static func isSkillDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
    }

    /// Hash over every file's relative path and bytes, so a local edit or an
    /// added file changes the result.
    static func contentHash(of directory: URL) -> String {
        var hasher = SHA256()
        let base = directory.standardizedFileURL.path
        let paths = (FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? [])
            .map(\.standardizedFileURL.path)
            .sorted()
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            hasher.update(data: Data(relative.utf8))
            if let data = FileManager.default.contents(atPath: path) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
