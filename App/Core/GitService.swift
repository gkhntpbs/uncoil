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
