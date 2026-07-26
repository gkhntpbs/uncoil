import Foundation

/// Read-only Git inspection for the project dashboard.
enum GitService {
    struct ChangedFile: Identifiable, Equatable {
        var id: String { path }
        let status: String   // "M", "A", "??", …
        let path: String
    }

    struct Commit: Identifiable, Equatable {
        var id: String { hash }
        let hash: String
        let subject: String
        let relativeDate: String
    }

    struct Snapshot: Equatable {
        var isRepo = false
        var branch: String?
        var changedFiles: [ChangedFile] = []
        var recentCommits: [Commit] = []
    }

    /// Blocking; call from a background task.
    static func snapshot(repoPath: String) -> Snapshot {
        guard run(["-C", repoPath, "rev-parse", "--git-dir"]) != nil else {
            return Snapshot()
        }
        var snapshot = Snapshot(isRepo: true)
        snapshot.branch = run(["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"])

        // Not trimmed: porcelain codes start with a space for "modified, not
        // staged", and trimming the output would eat it — leaving the first
        // entry's path one character short.
        if let status = run(["-C", repoPath, "status", "--porcelain"], trimming: false) {
            snapshot.changedFiles = status
                .split(separator: "\n")
                .prefix(100)
                .compactMap { line in
                    guard line.count > 3 else { return nil }
                    let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
                    let path = String(line.dropFirst(3))
                    return ChangedFile(status: code.isEmpty ? "?" : code, path: path)
                }
        }

        if let log = run([
            "-C", repoPath, "log", "-6", "--pretty=format:%h%x09%s%x09%cr",
        ]) {
            snapshot.recentCommits = log
                .split(separator: "\n")
                .compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3 else { return nil }
                    return Commit(
                        hash: String(parts[0]),
                        subject: String(parts[1]),
                        relativeDate: String(parts[2])
                    )
                }
        }
        return snapshot
    }

    /// Paths with an unresolved merge conflict (`git diff --diff-filter=U`),
    /// which is what the Attention Center reports. Blocking; call from a
    /// background task.
    /// Just the checked-out branch — one `git` call rather than the four a full
    /// snapshot costs, for the places that only name where the work is landing.
    /// Blocking; call from a background task.
    static func currentBranch(repoPath: String) -> String? {
        guard let branch = run(["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]),
              !branch.isEmpty
        else { return nil }
        return branch
    }

    static func conflictedFiles(repoPath: String) -> [String] {
        guard let output = run([
            "-C", repoPath, "diff", "--name-only", "--diff-filter=U",
        ]) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Blocking; call from a background task.
    static func remoteURL(repoPath: String) -> String? {
        run(["-C", repoPath, "remote", "get-url", "origin"])
    }

    // MARK: - Per-file status

    /// Porcelain codes for the given paths, keyed by repo-relative path.
    ///
    /// One `git status` call for all of them, scoped by pathspec: asking for the
    /// whole repo with `--ignored` can walk an entire `node_modules`. Blocking;
    /// call from a background task.
    static func fileStatuses(repoPath: String, relativePaths: [String]) -> [String: String] {
        guard !relativePaths.isEmpty else { return [:] }
        // core.quotePath=false keeps non-ASCII paths readable instead of escaped.
        guard let output = run(
            ["-c", "core.quotePath=false", "-C", repoPath,
             "status", "--porcelain", "--ignored", "--"] + relativePaths,
            trimming: false
        ) else { return [:] }
        return parseFileStatuses(output)
    }

    /// Pure half of `fileStatuses`.
    static func parseFileStatuses(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") where line.count > 3 {
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            // "R  old -> new": the new path is the one that exists now.
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            result[path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = code
        }
        return result
    }

    static func isRepository(_ path: String) -> Bool {
        run(["-C", path, "rev-parse", "--git-dir"]) != nil
    }

    // MARK: - Worktrees

    struct Worktree: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let branch: String?
        let isMain: Bool
    }

    /// Blocking; call from a background task.
    static func worktrees(repoPath: String) -> [Worktree] {
        guard let output = run(["-C", repoPath, "worktree", "list", "--porcelain"]) else {
            return []
        }
        return parseWorktrees(output, mainPath: repoPath)
    }

    static func parseWorktrees(_ porcelain: String, mainPath: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var branch: String?

        func flush() {
            if let p = path {
                let normalizedMain = URL(fileURLWithPath: mainPath).standardizedFileURL.path
                let normalized = URL(fileURLWithPath: p).standardizedFileURL.path
                result.append(Worktree(path: p, branch: branch, isMain: normalized == normalizedMain))
            }
            path = nil
            branch = nil
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                branch = nil
            }
        }
        flush()
        return result
    }

    struct GitFailure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Branches

    /// A local branch, and whether this checkout can move onto it.
    ///
    /// Git allows a branch in only one worktree at a time, so a project with a
    /// task worktree open has branches it cannot check out. Reporting that up
    /// front is better than letting the switch fail with git's own wording.
    struct Branch: Identifiable, Equatable {
        let name: String
        let isCurrent: Bool
        /// The other worktree holding it, when one does.
        let heldBy: String?
        var id: String { name }
        var isSwitchable: Bool { !isCurrent && heldBy == nil }
    }

    /// Local branches, current first, then alphabetically. Blocking; call from a
    /// background task.
    static func branches(repoPath: String) -> [Branch] {
        guard let output = run([
            "-C", repoPath, "for-each-ref", "--format=%(refname:short)%09%(HEAD)",
            "refs/heads",
        ]) else { return [] }

        // Which branch each worktree holds, so the ones git would refuse are
        // marked rather than offered.
        var holders: [String: String] = [:]
        let here = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        for worktree in worktrees(repoPath: repoPath) {
            let path = URL(fileURLWithPath: worktree.path).standardizedFileURL.path
            guard path != here, let branch = worktree.branch else { continue }
            holders[branch] = worktree.path
        }

        let parsed: [Branch] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
            let isCurrent = parts.count > 1 && parts[1] == "*"
            return Branch(
                name: name, isCurrent: isCurrent,
                heldBy: isCurrent ? nil : holders[name])
        }
        return parsed.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Checks a branch out in this working tree.
    ///
    /// Nothing is stashed, forced or auto-committed: git refuses when the switch
    /// would lose work, and that refusal is the honest answer to show. Blocking;
    /// call from a background task.
    static func checkout(repoPath: String, branch: String) -> Result<Void, GitFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "checkout", branch]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failure(GitFailure(message: error.localizedDescription))
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitFailure(
                message: message?.isEmpty == false
                    ? message! : String(localized: "git checkout failed")))
        }
        return .success(())
    }

    /// Creates `<repo>/.uncoil-worktrees/<slug>` on a fresh `uncoil/<slug>` branch.
    /// Blocking; call from a background task.
    static func createWorktree(repoPath: String, name: String) -> Result<Worktree, GitFailure> {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !slug.isEmpty else { return .failure(GitFailure(message: String(localized: "A valid name is required."))) }

        let container = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".uncoil-worktrees", isDirectory: true)
        let destination = container.appendingPathComponent(slug, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failure(GitFailure(message: String(localized: "\(slug) already exists.")))
        }

        let branch = "uncoil/\(slug)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", "-b", branch, destination.path]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failure(GitFailure(message: error.localizedDescription))
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitFailure(message: message?.isEmpty == false ? message! : String(localized: "git worktree add failed")))
        }
        return .success(Worktree(path: destination.path, branch: branch, isMain: false))
    }

    /// `trimming: false` keeps leading whitespace, which porcelain output needs.
    /// Diff of a worktree against the branch it will merge into. Bounded, so a
    /// huge change does not hand the UI a megabyte of text. Blocking.
    static func diff(repoPath: String, against base: String = "HEAD", maxLines: Int = 400) -> String {
        guard let output = run(
            ["-C", repoPath, "diff", "--no-color", base], trimming: false
        ) else { return "" }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return output }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n… \(lines.count - maxLines) more lines (open in your editor for all of it)"
    }

    /// Merges `branch` into the checkout at `repoPath`.
    ///
    /// Only ever called from the merge screen after the user approves: nothing in
    /// Uncoil merges on an agent's word. `--no-ff` keeps the task's work visible
    /// as its own commit, and a failed merge is aborted so the tree is left
    /// exactly as it was.
    static func merge(
        repoPath: String,
        branch: String,
        message: String
    ) -> Result<String?, GitFailure> {
        guard isRepository(repoPath) else {
            return .failure(GitFailure(message: String(localized: "\(repoPath) is not a git repository.")))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "merge", "--no-ff", "-m", message, branch]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        guard (try? process.run()) != nil else {
            return .failure(GitFailure(message: String(localized: "git could not be run.")))
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Leave no half-merged tree behind.
            _ = run(["-C", repoPath, "merge", "--abort"])
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitFailure(
                message: detail?.isEmpty == false ? detail! : String(localized: "git merge failed.")
            ))
        }
        return .success(run(["-C", repoPath, "rev-parse", "--short", "HEAD"]))
    }

    private static func run(_ arguments: [String], trimming: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return trimming
            ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            : String(raw.reversed().drop { $0 == "\n" }.reversed())
    }
}
