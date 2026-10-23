import Foundation

/// The evidence an Auto run checks work against. Only what the project
/// itself declares is run — its `.uncoil/tests.json` default suite, or the
/// one suite Uncoil detects — never a command an agent proposed: an agent's
/// commands run in its own session, under its own approvals.
enum AutoVerification {
    static let outputTailLimit = 4_000

    /// The suite to run in `directory`: the declared default, or the only
    /// detected one. Several detected and none chosen ⇒ none; guessing which
    /// suite the user meant would make a verdict out of the wrong evidence.
    static func suites(in directory: String) -> [AutoSuiteSpec] {
        let root = URL(fileURLWithPath: directory)
        let declared = TestConfigFile.load(projectRoot: root).suites
        let candidates = declared.isEmpty
            ? TestDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
            : declared
        guard let suite = TestConfigFile.defaultSuite(candidates) else { return [] }
        let cwd = suite.cwd == "." || suite.cwd.isEmpty ? directory : root.appendingPathComponent(suite.cwd).path
        return [AutoSuiteSpec(name: suite.name, command: suite.command, directory: cwd)]
    }

    /// Runs the suite in a login shell, the way the user would, and keeps
    /// the end of its output. Blocking.
    static func run(_ suite: AutoSuiteSpec, timeout: TimeInterval) -> AutoVerificationRecord.Suite {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", suite.command]
        process.currentDirectoryURL = URL(fileURLWithPath: suite.directory)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let buffer = TailBuffer(limit: outputTailLimit * 4)
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return .init(name: suite.name, command: suite.command, exitCode: nil, timedOut: false,
                         outputTail: "Could not start: \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let timedOut = finished.wait(timeout: .now() + max(1, timeout)) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        output.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: buffer.data, as: UTF8.self)
        return .init(
            name: suite.name, command: suite.command,
            exitCode: timedOut ? nil : process.terminationStatus,
            timedOut: timedOut,
            outputTail: String(text.suffix(outputTailLimit)))
    }

    /// Paths `git status` reports in `directory`; empty outside a repository.
    static func changedFiles(in directory: String) -> [String] {
        let result = ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["-C", directory, "status", "--porcelain"], timeout: 30)
        guard result.launched, result.exitCode == 0 else { return [] }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let path = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
    }

    /// Collects a process's output, keeping only the end once it grows past
    /// `limit`. Locked: the pipe's handler runs on its own queue.
    private final class TailBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            storage.append(data)
            if storage.count > limit { storage = storage.suffix(limit) }
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

extension GitService {
    /// Removes a worktree Uncoil created, and its branch when the branch
    /// holds nothing the main line does not. Never forced: a worktree with
    /// changes in it stays. Blocking.
    @discardableResult
    static func removeWorktree(repoPath: String, path: String) -> Bool {
        let branch = ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 15)
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["-C", repoPath, "worktree", "remove", path], timeout: 30)
        guard removed.launched, removed.exitCode == 0 else { return false }
        if branch.hasPrefix("uncoil/") {
            // -d, not -D: a branch with commits of its own is kept.
            _ = ProcessRunner.run(
                executable: "/usr/bin/git", arguments: ["-C", repoPath, "branch", "-d", branch], timeout: 15)
        }
        return true
    }
}
