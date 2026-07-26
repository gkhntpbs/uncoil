import Foundation

/// Git plumbing for managed extensions: one bare mirror per repository, and an
/// immutable checkout per commit. Never runs `git pull` in a directory an agent
/// is reading — updates always land in a fresh revision directory first.
struct ExtensionMirror {
    let layout: ExtensionStoreLayout
    /// Overridable so tests can point at a local path instead of a remote.
    var gitPath = "/usr/bin/git"

    struct Failure: LocalizedError, Equatable {
        let command: String
        let message: String
        var errorDescription: String? {
            message.isEmpty ? "git \(command) failed" : message
        }
    }

    // MARK: - Mirror lifecycle

    func mirrorPath(for repository: String) -> URL {
        layout.mirror(forRepository: repository)
    }

    func hasMirror(for repository: String) -> Bool {
        FileManager.default.fileExists(atPath: mirrorPath(for: repository).path)
    }

    /// Clones the repository as a bare mirror, or fetches into the existing one.
    /// Two skills from the same repo share this single mirror.
    func ensureMirror(repository: String, remote: String) throws -> URL {
        try FileManager.default.createDirectory(at: layout.mirrors, withIntermediateDirectories: true)
        let path = mirrorPath(for: repository)
        if hasMirror(for: repository) {
            try fetch(repository: repository)
            return path
        }
        _ = try run(["clone", "--mirror", remote, path.path])
        return path
    }

    func fetch(repository: String) throws {
        _ = try run([
            "--git-dir", mirrorPath(for: repository).path,
            "fetch", "--prune", "--tags", "origin", "+refs/heads/*:refs/heads/*",
        ])
    }

    // MARK: - Resolving

    /// Commit a tracking mode currently points at.
    func resolve(
        _ tracking: ExtensionSource.TrackingMode,
        repository: String
    ) throws -> String {
        switch tracking {
        case .pinnedCommit(let sha):
            // Verify it exists rather than trusting the stored value.
            return try revParse(sha, repository: repository)
        case .tag(let tag):
            return try revParse("refs/tags/\(tag)", repository: repository)
        case .branch(let branch):
            return try revParse("refs/heads/\(branch)", repository: repository)
        }
    }

    func revParse(_ ref: String, repository: String) throws -> String {
        let output = try run([
            "--git-dir", mirrorPath(for: repository).path, "rev-parse", "\(ref)^{commit}",
        ])
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 7 else {
            throw Failure(command: "rev-parse", message: String(localized: "\(ref) could not be resolved"))
        }
        return sha
    }

    /// Number of commits `to` is ahead of `from`, for "3 commits behind".
    func commitCount(from: String?, to: String, repository: String) -> Int {
        guard let from, from != to else { return from == to ? 0 : 1 }
        guard let output = try? run([
            "--git-dir", mirrorPath(for: repository).path,
            "rev-list", "--count", "\(from)..\(to)",
        ]) else { return 0 }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Files that differ between two commits, optionally limited to a subpath.
    func changedFiles(
        from: String,
        to: String,
        repository: String,
        subpath: String? = nil
    ) -> [String] {
        var arguments = [
            "--git-dir", mirrorPath(for: repository).path,
            "diff", "--name-only", "\(from)..\(to)",
        ]
        if let subpath, !subpath.isEmpty {
            arguments.append(contentsOf: ["--", subpath])
        }
        guard let output = try? run(arguments) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Commit subjects between two commits, used as a changelog when the repo
    /// has no CHANGELOG file.
    func commitSubjects(from: String?, to: String, repository: String) -> [String] {
        var range = to
        if let from, from != to { range = "\(from)..\(to)" }
        guard let output = try? run([
            "--git-dir", mirrorPath(for: repository).path,
            "log", "--pretty=format:%s", "-20", range,
        ]) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func fileContents(path: String, at sha: String, repository: String) -> String? {
        try? run([
            "--git-dir", mirrorPath(for: repository).path, "show", "\(sha):\(path)",
        ])
    }

    // MARK: - Revisions

    /// Checks a commit out into `revisions/<id>` via `git archive`, so the
    /// result is a plain directory with no git metadata an agent could confuse
    /// for its own repository. Extracting into a temp directory first means an
    /// interrupted checkout never leaves a half-populated revision behind.
    @discardableResult
    func materializeRevision(
        repository: String,
        sha: String,
        subpath: String? = nil,
        revisionID: String? = nil
    ) throws -> URL {
        let id = revisionID ?? Self.revisionID(repository: repository, sha: sha, subpath: subpath)
        let destination = layout.revision(id)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try FileManager.default.createDirectory(at: layout.revisions, withIntermediateDirectories: true)
        let staging = layout.revisions
            .appendingPathComponent(".staging-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var arguments = [
                "--git-dir", mirrorPath(for: repository).path,
                "archive", "--format=tar", sha,
            ]
            if let subpath, !subpath.isEmpty {
                arguments.append(subpath)
            }
            let tar = layout.revisions.appendingPathComponent(".staging-\(id).tar")
            let data = try runData(arguments)
            try data.write(to: tar, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tar) }
            try untar(tar, into: staging)

            // `git archive <sha> <subpath>` keeps the subpath prefix; the
            // revision should hold the extension's own files at its root.
            var contentRoot = staging
            if let subpath, !subpath.isEmpty {
                contentRoot = staging.appendingPathComponent(subpath, isDirectory: true)
                guard FileManager.default.fileExists(atPath: contentRoot.path) else {
                    throw Failure(command: "archive", message: String(localized: "\(subpath) is not in this commit"))
                }
            }
            try FileManager.default.moveItem(at: contentRoot, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
        return destination
    }

    /// Deletes revision directories that nothing points at. The active and
    /// previous revisions are always kept so a rollback stays possible.
    @discardableResult
    func collectGarbage(keeping keep: Set<String>) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: layout.revisions, includingPropertiesForKeys: nil, options: []
        ) else { return [] }
        var removed: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            // Leftover staging from an interrupted checkout is always garbage.
            let isStaging = name.hasPrefix(".staging-")
            guard isStaging || !keep.contains(name) else { continue }
            guard isStaging || !name.hasPrefix(".") else { continue }
            try? FileManager.default.removeItem(at: entry)
            removed.append(name)
        }
        return removed.sorted()
    }

    /// Stable revision directory name. Includes the subpath so two skills from
    /// one repository at one commit get their own revisions.
    static func revisionID(repository: String, sha: String, subpath: String?) -> String {
        let base = ExtensionStoreLayout.slug(repository)
        let short = String(sha.prefix(12))
        guard let subpath, !subpath.isEmpty else { return "\(base)-\(short)" }
        return "\(base)-\(ExtensionStoreLayout.slug(subpath))-\(short)"
    }

    // MARK: - Process helpers

    private func untar(_ tar: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", tar.path, "-C", directory.path]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(
                command: "tar",
                message: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        String(decoding: try runData(arguments), as: UTF8.self)
    }

    private func runData(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        // Never let a repo's config or a credential helper prompt block us.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_ASKPASS"] = "true"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw Failure(command: arguments.first ?? "", message: error.localizedDescription)
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(
                command: arguments.first ?? "",
                message: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outputData
    }
}
