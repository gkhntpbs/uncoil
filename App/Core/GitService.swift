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

        if let status = run(["-C", repoPath, "status", "--porcelain"]) {
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

    /// Blocking; call from a background task.
    static func remoteURL(repoPath: String) -> String? {
        run(["-C", repoPath, "remote", "get-url", "origin"])
    }

    /// Most recently modified file among uncommitted changes; falls back to
    /// the newest file in the last commit. Blocking; call from background.
    static func lastChangedFile(repoPath: String) -> String? {
        let root = URL(fileURLWithPath: repoPath)
        let changed = run(["-C", repoPath, "status", "--porcelain"])?
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.count > 3 else { return nil }
                return String(line.dropFirst(3))
            } ?? []
        if !changed.isEmpty {
            let newest = changed.max { left, right in
                let leftDate = (try? FileManager.default.attributesOfItem(
                    atPath: root.appendingPathComponent(left).path
                )[.modificationDate] as? Date) ?? .distantPast
                let rightDate = (try? FileManager.default.attributesOfItem(
                    atPath: root.appendingPathComponent(right).path
                )[.modificationDate] as? Date) ?? .distantPast
                return leftDate < rightDate
            }
            if let newest {
                return root.appendingPathComponent(newest).path
            }
        }
        if let committed = run(["-C", repoPath, "log", "-1", "--name-only", "--pretty=format:"])?
            .split(separator: "\n")
            .first {
            return root.appendingPathComponent(String(committed)).path
        }
        return nil
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

    /// Creates `<repo>/.uncoil-worktrees/<slug>` on a fresh `uncoil/<slug>` branch.
    /// Blocking; call from a background task.
    static func createWorktree(repoPath: String, name: String) -> Result<Worktree, GitFailure> {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !slug.isEmpty else { return .failure(GitFailure(message: "Geçerli bir isim gerekli.")) }

        let container = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".uncoil-worktrees", isDirectory: true)
        let destination = container.appendingPathComponent(slug, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failure(GitFailure(message: "\(slug) zaten var."))
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
            return .failure(GitFailure(message: message?.isEmpty == false ? message! : "git worktree add başarısız"))
        }
        return .success(Worktree(path: destination.path, branch: branch, isMain: false))
    }

    private static func run(_ arguments: [String]) -> String? {
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
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : output
    }
}
