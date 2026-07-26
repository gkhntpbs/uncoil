import Foundation

/// Per-task git shortcuts for the Tasks board: commit exactly the files a task
/// touched, and open a PR for them. Deliberately narrow — this is not a general
/// git client, it is "the agent just finished, get its work onto a branch".
///
/// Every process call goes through an injectable runner so tests never shell
/// out to real git or `gh`, matching the pattern `GitService`/`GitHubService`
/// already use elsewhere.
struct TaskGitActions {
    /// Runs a command and returns (exit code, stdout, stderr). Swapped out in
    /// tests to assert the exact argument lists without touching a real repo.
    typealias Runner = (_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String)

    enum GitActionError: LocalizedError, Equatable {
        case noFilesSelected
        case mergeInProgress
        case rebaseInProgress
        case commitFailed(String)
        case ghNotInstalled
        case ghNotAuthenticated
        case pushFailed(String)
        case pullRequestFailed(String)
        case malformedPullRequestURL

        var errorDescription: String? {
            switch self {
            case .noFilesSelected:
                "Pick at least one file to commit."
            case .mergeInProgress:
                "A merge is in progress — resolve that first."
            case .rebaseInProgress:
                "A rebase is in progress — resolve that first."
            case .commitFailed(let detail):
                "Commit failed: \(detail)"
            case .ghNotInstalled:
                "GitHub CLI (gh) is not installed."
            case .ghNotAuthenticated:
                "Not signed in to the GitHub CLI — run `gh auth login`."
            case .pushFailed(let detail):
                "Push failed: \(detail)"
            case .pullRequestFailed(let detail):
                "The pull request could not be created: \(detail)"
            case .malformedPullRequestURL:
                "gh returned an unexpected response."
            }
        }
    }

    var runner: Runner

    init(runner: @escaping Runner = TaskGitActions.processRunner) {
        self.runner = runner
    }

    // MARK: - Status

    /// Porcelain paths for the repo, reusing `GitService`'s own parsing so this
    /// stays consistent with what the rest of the app calls "changed".
    func changedFiles(repoRoot: String) -> [String] {
        GitService.fileStatuses(repoPath: repoRoot, relativePaths: allTrackedAndUntrackedPaths(repoRoot: repoRoot))
            .keys
            .sorted()
    }

    /// Every path `git status --porcelain` currently reports, unscoped — used
    /// only to seed `changedFiles`'s pathspec query.
    private func allTrackedAndUntrackedPaths(repoRoot: String) -> [String] {
        let result = runner("/usr/bin/git", ["-C", repoRoot, "status", "--porcelain"])
        guard result.status == 0 else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard line.count > 3 else { return nil }
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") {
                    path = String(path[arrow.upperBound...])
                }
                return path
            }
    }

    // MARK: - Commit

    /// Stages exactly `files` — never `git add -A` — and commits them.
    ///
    /// Refuses when the file list is empty, or when a merge or rebase is in
    /// progress: committing over either would bury the conflict instead of
    /// resolving it. Returns the short commit hash.
    @discardableResult
    func commit(
        task: ProjectTask,
        files: [String],
        repoRoot: String,
        message: String? = nil
    ) throws -> String {
        guard !files.isEmpty else { throw GitActionError.noFilesSelected }
        if isMergeInProgress(repoRoot: repoRoot) { throw GitActionError.mergeInProgress }
        if isRebaseInProgress(repoRoot: repoRoot) { throw GitActionError.rebaseInProgress }

        let addResult = runner("/usr/bin/git", ["-C", repoRoot, "add", "--"] + files)
        guard addResult.status == 0 else {
            throw GitActionError.commitFailed(addResult.stderr.trimmed)
        }

        let commitMessage = message ?? Self.defaultCommitMessage(for: task)
        let commitResult = runner("/usr/bin/git", ["-C", repoRoot, "commit", "-m", commitMessage])
        guard commitResult.status == 0 else {
            throw GitActionError.commitFailed(commitResult.stderr.trimmed.isEmpty
                ? commitResult.stdout.trimmed
                : commitResult.stderr.trimmed)
        }

        let hashResult = runner("/usr/bin/git", ["-C", repoRoot, "rev-parse", "--short", "HEAD"])
        return hashResult.status == 0 ? hashResult.stdout.trimmed : commitMessage
    }

    /// "task: <first 60 chars of task text>", single line, whitespace collapsed
    /// so a multi-line task doesn't turn into a multi-line subject.
    static func defaultCommitMessage(for task: ProjectTask) -> String {
        let collapsed = task.text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let truncated = collapsed.count > 60 ? String(collapsed.prefix(60)) : collapsed
        return "task: \(truncated)"
    }

    private func isMergeInProgress(repoRoot: String) -> Bool {
        FileManager.default.fileExists(atPath: gitDir(repoRoot).appendingPathComponent("MERGE_HEAD").path)
    }

    private func isRebaseInProgress(repoRoot: String) -> Bool {
        let dir = gitDir(repoRoot)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("rebase-merge").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("rebase-apply").path)
    }

    private func gitDir(_ repoRoot: String) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(".git", isDirectory: true)
    }

    // MARK: - Branch naming

    /// "task/<kebab-case-words>", at most 40 characters, deduplicatable by the
    /// caller (append "-2", "-3", …) since this function has no view of what
    /// branches already exist.
    static func suggestedBranchName(task: ProjectTask) -> String {
        let words = TaskFingerprint.normalize(task.text)
            .split(separator: " ")
            .filter { !$0.isEmpty }
        let slug = words.isEmpty ? "task-\(task.fingerprint.strongKey.prefix(8))" : words.joined(separator: "-")
        let prefix = "task/"
        let budget = max(0, 40 - prefix.count)
        return prefix + String(slug.prefix(budget))
    }

    // MARK: - Pull request

    /// Pushes the current branch (creating `branch` from HEAD first if the repo
    /// is still on its default branch) and opens a PR with `gh`. Returns the
    /// PR URL gh reports.
    func createPullRequest(
        task: ProjectTask,
        repoRoot: String,
        branch: String? = nil,
        baseBranch: String = "main"
    ) async throws -> URL {
        guard isGhInstalled() else { throw GitActionError.ghNotInstalled }
        guard isGhAuthenticated() else { throw GitActionError.ghNotAuthenticated }

        let currentBranch = runner("/usr/bin/git", ["-C", repoRoot, "rev-parse", "--abbrev-ref", "HEAD"])
            .stdout.trimmed
        var targetBranch = currentBranch
        if currentBranch.isEmpty || currentBranch == baseBranch {
            let name = branch ?? Self.suggestedBranchName(task: task)
            let checkout = runner("/usr/bin/git", ["-C", repoRoot, "checkout", "-b", name])
            guard checkout.status == 0 else {
                throw GitActionError.pushFailed(checkout.stderr.trimmed)
            }
            targetBranch = name
        }

        let push = runner("/usr/bin/git", ["-C", repoRoot, "push", "-u", "origin", targetBranch])
        guard push.status == 0 else {
            throw GitActionError.pushFailed(push.stderr.trimmed.isEmpty ? push.stdout.trimmed : push.stderr.trimmed)
        }

        let title = String(localized: "task: \(task.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        let prResult = runner("/usr/bin/gh", [
            "pr", "create",
            "-C", repoRoot,
            "--title", title,
            "--body", task.rawBlock,
            "--base", baseBranch,
            "--head", targetBranch,
        ])
        guard prResult.status == 0 else {
            throw GitActionError.pullRequestFailed(
                prResult.stderr.trimmed.isEmpty ? prResult.stdout.trimmed : prResult.stderr.trimmed
            )
        }
        // `gh pr create` prints the PR URL as its last non-empty line.
        guard let urlLine = prResult.stdout
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmed.isEmpty }),
            let url = URL(string: urlLine.trimmed)
        else {
            throw GitActionError.malformedPullRequestURL
        }
        return url
    }

    private func isGhInstalled() -> Bool {
        let result = runner("/usr/bin/env", ["which", "gh"])
        return result.status == 0 && !result.stdout.trimmed.isEmpty
    }

    private func isGhAuthenticated() -> Bool {
        runner("/usr/bin/gh", ["auth", "status"]).status == 0
    }

    // MARK: - Real process runner

    static let processRunner: Runner = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
