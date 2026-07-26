import Foundation

/// What staging found out about a candidate revision before anything switched
/// over to it. A failed stage never changes the active revision.
struct StagedRevision: Equatable {
    var extensionID: String
    var revisionID: String
    var commitSHA: String
    var path: String
    var contentHash: String
    /// Structural problems: missing entrypoint, symlink escape, empty package.
    var structureIssues: [String]
    /// Files carrying the executable bit, handed to the security scanner.
    var executables: [String]
    var findings: [SecurityFinding]
    var smokeTestPassed: Bool

    /// Activation is only allowed when nothing structural failed, no finding is
    /// blocking, and the smoke test passed.
    var isActivatable: Bool {
        structureIssues.isEmpty
            && !findings.contains { $0.severity == .blocked && !$0.isAccepted }
            && smokeTestPassed
    }

    var blockingReason: String? {
        if let issue = structureIssues.first { return issue }
        if let blocked = findings.first(where: { $0.severity == .blocked && !$0.isAccepted }) {
            return blocked.message
        }
        if !smokeTestPassed { return "The smoke test failed." }
        return nil
    }
}

enum ExtensionUpdateError: LocalizedError, Equatable {
    case notManaged(String)
    case staleStage(String)
    case notActivatable(String)
    case diskFull(String)
    case noPreviousRevision(String)

    var errorDescription: String? {
        switch self {
        case .notManaged(let id):
            "\(id) is not a managed git source; it is not checked for updates."
        case .staleStage(let id):
            "The revision prepared for \(id) is no longer valid."
        case .notActivatable(let reason):
            "The revision cannot be enabled: \(reason)"
        case .diskFull(let detail):
            "Out of disk space, stopped safely: \(detail)"
        case .noPreviousRevision(let id):
            "There is no earlier revision of \(id) to fall back to."
        }
    }
}

/// Update pipeline for managed extensions: check → stage → activate, with
/// rollback. The active directory is never mutated in place, so a running agent
/// either sees the old revision or the new one, never a half-updated tree.
@MainActor
struct ExtensionUpdateEngine {
    var mirror: ExtensionMirror
    var store: SkillStore
    /// Injected so the security scan and smoke test can be faked in tests and
    /// swapped for the real scanner later.
    var scan: (URL) -> [SecurityFinding] = { _ in [] }
    var smokeTest: (URL) -> Bool = { _ in true }
    /// Free space required before a checkout is attempted.
    var minimumFreeBytes: Int64 = 64 * 1024 * 1024

    // MARK: - 1. Check

    /// Fetches and reports whether the tracking ref moved. Returns nil when the
    /// installed revision is already current.
    func checkForUpdate(
        _ package: ExtensionPackage,
        remote: String,
        now: Date = .now
    ) throws -> UpdateCandidate? {
        guard case .managedGitHub(let repository, let subpath, let tracking) = package.source else {
            throw ExtensionUpdateError.notManaged(package.id)
        }
        _ = try mirror.ensureMirror(repository: repository, remote: remote)
        let available = try mirror.resolve(tracking, repository: repository)
        let installed = package.activeRevision?.commitSHA
        guard installed != available else { return nil }

        let changed = installed.map {
            mirror.changedFiles(from: $0, to: available, repository: repository, subpath: subpath)
        } ?? []
        return UpdateCandidate(
            extensionID: package.id,
            installedCommitSHA: installed,
            availableCommitSHA: available,
            commitCount: mirror.commitCount(from: installed, to: available, repository: repository),
            changedFiles: changed,
            changelog: changelog(
                repository: repository, subpath: subpath,
                from: installed, to: available
            ),
            fetchedAt: now
        )
    }

    private func changelog(
        repository: String,
        subpath: String?,
        from: String?,
        to: String
    ) -> String? {
        let candidates = ["CHANGELOG.md", "CHANGELOG"].flatMap { name -> [String] in
            guard let subpath, !subpath.isEmpty else { return [name] }
            return ["\(subpath)/\(name)", name]
        }
        for candidate in candidates {
            if let contents = mirror.fileContents(path: candidate, at: to, repository: repository),
               !contents.isEmpty {
                return contents
            }
        }
        let subjects = mirror.commitSubjects(from: from, to: to, repository: repository)
        return subjects.isEmpty ? nil : subjects.map { "· \($0)" }.joined(separator: "\n")
    }

    // MARK: - 2. Stage

    /// Checks the candidate commit out into its own revision directory and runs
    /// every gate. Nothing the agents read is touched.
    func stage(
        _ candidate: UpdateCandidate,
        package: ExtensionPackage
    ) throws -> StagedRevision {
        guard case .managedGitHub(let repository, let subpath, _) = package.source else {
            throw ExtensionUpdateError.notManaged(package.id)
        }
        try requireDiskSpace()
        let revisionID = ExtensionMirror.revisionID(
            repository: repository, sha: candidate.availableCommitSHA, subpath: subpath
        )
        let path = try mirror.materializeRevision(
            repository: repository,
            sha: candidate.availableCommitSHA,
            subpath: subpath,
            revisionID: revisionID
        )
        let structure = Self.structureIssues(at: path, kind: package.kind)
        let executables = Self.executables(at: path)
        return StagedRevision(
            extensionID: package.id,
            revisionID: revisionID,
            commitSHA: candidate.availableCommitSHA,
            path: path.path,
            contentHash: SkillStore.contentHash(of: path),
            structureIssues: structure,
            executables: executables,
            findings: structure.isEmpty ? scan(path) : [],
            smokeTestPassed: structure.isEmpty ? smokeTest(path) : false
        )
    }

    /// Structural gates: the package has to have its entrypoint, hold files, and
    /// contain no symlink pointing outside itself.
    static func structureIssues(at path: URL, kind: ExtensionKind) -> [String] {
        var issues: [String] = []
        let manager = FileManager.default
        guard manager.fileExists(atPath: path.path) else {
            return ["No revision directory."]
        }
        switch kind {
        case .skill:
            if !manager.fileExists(atPath: path.appendingPathComponent("SKILL.md").path) {
                issues.append("Eksik entrypoint: SKILL.md")
            }
        case .mcpServer:
            let hasManifest = ["package.json", "pyproject.toml", "mcp.json"].contains {
                manager.fileExists(atPath: path.appendingPathComponent($0).path)
            }
            if !hasManifest {
                issues.append("Eksik entrypoint: package.json / pyproject.toml / mcp.json")
            }
        }
        if let escapes = symlinkEscapes(at: path), !escapes.isEmpty {
            issues.append("Symlink pointing outside the package: \(escapes.joined(separator: ", "))")
        }
        if (try? manager.contentsOfDirectory(atPath: path.path))?.isEmpty != false {
            issues.append("The revision is empty.")
        }
        return issues
    }

    /// Symlinks resolving outside the package root — the classic way a package
    /// reaches into `~/.ssh` while looking innocent.
    nonisolated static func symlinkEscapes(at root: URL) -> [String]? {
        let manager = FileManager.default
        guard let base = CapabilityRouter.realpathString(root.standardizedFileURL.path) else {
            return nil
        }
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return [] }
        var escapes: [String] = []
        for case let url as URL in enumerator {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
                  let target = try? manager.destinationOfSymbolicLink(atPath: url.path) else {
                continue
            }
            let resolved = target.hasPrefix("/")
                ? URL(fileURLWithPath: target).standardizedFileURL.path
                : url.deletingLastPathComponent()
                    .appendingPathComponent(target).standardizedFileURL.path
            let canonical = CapabilityRouter.realpathString(resolved) ?? resolved
            if canonical != base, !canonical.hasPrefix(base + "/") {
                escapes.append(url.lastPathComponent)
            }
        }
        return escapes.sorted()
    }

    static func executables(at root: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  manager.isExecutableFile(atPath: url.path) else { continue }
            let path = url.standardizedFileURL.path
            result.append(path.hasPrefix(base) ? String(path.dropFirst(base.count + 1)) : path)
        }
        return result.sorted()
    }

    // MARK: - 3. Activate

    /// Swaps the active pointer to the staged revision in one symlink
    /// replacement, keeping the old one as `previousRevision` for rollback.
    /// A running MCP process is left alone: it picks the new revision up when it
    /// next starts.
    func activate(
        _ staged: StagedRevision,
        package: ExtensionPackage,
        skillName: String,
        now: Date = .now
    ) throws -> ExtensionPackage {
        guard staged.isActivatable else {
            throw ExtensionUpdateError.notActivatable(staged.blockingReason ?? "bilinmeyen sebep")
        }
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw ExtensionUpdateError.staleStage(staged.extensionID)
        }
        var updated = package
        try store.activate(revisionID: staged.revisionID, name: skillName)
        updated.previousRevision = package.activeRevision
        updated.activeRevision = InstalledRevision(
            id: staged.revisionID,
            commitSHA: staged.commitSHA,
            contentHash: staged.contentHash,
            path: staged.path,
            installedAt: now
        )
        updated.hasLocalModification = false
        updated.state = .active
        return updated
    }

    // MARK: - 4. Rollback

    /// Returns to the previous revision. If the swap fails the old pointer is
    /// kept, so a failed rollback never leaves the extension unusable.
    func rollback(
        _ package: ExtensionPackage,
        skillName: String
    ) throws -> (package: ExtensionPackage, health: HealthCheckResult) {
        guard let previous = package.previousRevision else {
            throw ExtensionUpdateError.noPreviousRevision(package.id)
        }
        guard FileManager.default.fileExists(atPath: previous.path) else {
            throw ExtensionUpdateError.staleStage(previous.id)
        }
        var updated = package
        try store.activate(revisionID: previous.id, name: skillName)
        updated.activeRevision = previous
        updated.previousRevision = package.activeRevision
        let status = store.activeStatus(name: skillName, expectedRevisionID: previous.id)
        return (
            updated,
            HealthCheckResult(
                id: "rollback.\(package.id)",
                name: "Link after rollback",
                outcome: status == .linked ? .ok : .failure,
                detail: status.label,
                remedy: status == .linked ? nil : String(localized: "Repair the connection with Repair."),
                checkedAt: .now
            )
        )
    }

    // MARK: - Interruptions

    /// Clears half-finished checkouts and revisions nothing points at. Safe to
    /// run at launch: it is how an update interrupted by a quit gets cleaned up
    /// without touching the active or previous revision.
    @discardableResult
    func recoverAfterInterruption(packages: [ExtensionPackage]) -> [String] {
        var keep: Set<String> = []
        for package in packages {
            if let active = package.activeRevision { keep.insert(active.id) }
            if let previous = package.previousRevision { keep.insert(previous.id) }
        }
        return mirror.collectGarbage(keeping: keep)
    }

    private func requireDiskSpace() throws {
        let values = try? mirror.layout.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= minimumFreeBytes else {
            throw ExtensionUpdateError.diskFull("\(available / 1_048_576) MB free")
        }
    }
}
