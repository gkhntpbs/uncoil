import Foundation

/// Minimal read-only Git inspection for the sidebar (branch + dirty state).
enum GitInfo {
    struct Snapshot: Equatable {
        var branch: String?
        var isDirty: Bool
    }

    /// Runs `git` synchronously with a short timeout; call from a background task.
    static func snapshot(forRepoAt path: String) -> Snapshot {
        let branch = run(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        let status = run(["-C", path, "status", "--porcelain", "-uno"])
        return Snapshot(
            branch: branch?.isEmpty == false ? branch : nil,
            isDirty: status?.isEmpty == false
        )
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
