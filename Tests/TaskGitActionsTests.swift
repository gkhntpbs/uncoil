import XCTest
@testable import Uncoil

/// Records every command handed to the injected runner, so a test can assert
/// the exact argument list a real `git`/`gh` call would have received.
private final class RecordingRunner {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    /// Scripted responses, consumed in order per-(executable+subcommand); a
    /// missing script falls back to success with empty output.
    var responses: [String: (status: Int32, stdout: String, stderr: String)] = [:]

    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        calls.append(Call(executable: executable, arguments: arguments))
        let key = ([executable] + arguments).joined(separator: " ")
        if let exact = responses[key] { return exact }
        // Match by executable + first argument (subcommand) so a test doesn't
        // have to script the full "-C <path>" prefix every time.
        for (pattern, response) in responses where key.hasPrefix(pattern) {
            return response
        }
        return (0, "", "")
    }

    var runner: TaskGitActions.Runner { { self.run($0, $1) } }
}

final class TaskGitActionsTests: XCTestCase {
    private func task(_ line: String = "- [ ] daemon heartbeat ekle\n") -> ProjectTask {
        TodoParser.parse(line, path: "/repo/TODO.md").tasks[0]
    }

    // MARK: - Commit message derivation

    func testDefaultCommitMessageUsesTaskTextPrefixedWithTask() {
        let message = TaskGitActions.defaultCommitMessage(for: task("- [ ] daemon heartbeat ekle\n"))
        XCTAssertEqual(message, "task: daemon heartbeat ekle")
    }

    func testDefaultCommitMessageTruncatesToSixtyCharacters() {
        let longText = String(repeating: "a", count: 100)
        let message = TaskGitActions.defaultCommitMessage(for: task("- [ ] \(longText)\n"))
        XCTAssertTrue(message.hasPrefix("task: "))
        let body = String(message.dropFirst("task: ".count))
        XCTAssertEqual(body.count, 60)
        XCTAssertEqual(body, String(longText.prefix(60)))
    }

    func testDefaultCommitMessageCollapsesNewlinesFromMultilineTaskText() {
        let multiline = TodoParser.parse(
            "- [ ] birinci satır\n  ikinci satır\n", path: "/repo/TODO.md"
        ).tasks[0]
        let message = TaskGitActions.defaultCommitMessage(for: multiline)
        XCTAssertFalse(message.contains("\n"))
    }

    // MARK: - Branch naming

    func testSuggestedBranchNameIsKebabCasePrefixedWithTask() {
        let name = TaskGitActions.suggestedBranchName(task: task("- [ ] daemon heartbeat ekle\n"))
        XCTAssertEqual(name, "task/daemon-heartbeat-ekle")
    }

    func testSuggestedBranchNameIsBoundedToFortyCharacters() {
        let words = Array(repeating: "word", count: 20).joined(separator: " ")
        let name = TaskGitActions.suggestedBranchName(task: task("- [ ] \(words)\n"))
        XCTAssertLessThanOrEqual(name.count, 40)
        XCTAssertTrue(name.hasPrefix("task/"))
    }

    func testSuggestedBranchNameFallsBackToFingerprintForPunctuationOnlyText() {
        let name = TaskGitActions.suggestedBranchName(task: task("- [ ] ??? !!!\n"))
        XCTAssertTrue(name.hasPrefix("task/task-"))
    }

    // MARK: - Commit refusal

    func testCommitRefusesAnEmptyFileList() throws {
        let recorder = RecordingRunner()
        let actions = TaskGitActions(runner: recorder.runner)
        XCTAssertThrowsError(
            try actions.commit(task: task(), files: [], repoRoot: "/repo")
        ) { error in
            XCTAssertEqual(error as? TaskGitActions.GitActionError, .noFilesSelected)
        }
        XCTAssertTrue(recorder.calls.isEmpty, "must not shell out at all when there is nothing to commit")
    }

    func testCommitRefusesDuringAMerge() throws {
        let tempRepo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: tempRepo) }
        FileManager.default.createFile(
            atPath: tempRepo.appendingPathComponent(".git/MERGE_HEAD").path, contents: nil
        )
        let recorder = RecordingRunner()
        let actions = TaskGitActions(runner: recorder.runner)
        XCTAssertThrowsError(
            try actions.commit(task: task(), files: ["a.txt"], repoRoot: tempRepo.path)
        ) { error in
            XCTAssertEqual(error as? TaskGitActions.GitActionError, .mergeInProgress)
        }
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testCommitRefusesDuringARebase() throws {
        let tempRepo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: tempRepo) }
        try FileManager.default.createDirectory(
            at: tempRepo.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true
        )
        let recorder = RecordingRunner()
        let actions = TaskGitActions(runner: recorder.runner)
        XCTAssertThrowsError(
            try actions.commit(task: task(), files: ["a.txt"], repoRoot: tempRepo.path)
        ) { error in
            XCTAssertEqual(error as? TaskGitActions.GitActionError, .rebaseInProgress)
        }
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: - Staged-files-only behaviour

    func testCommitStagesOnlyTheGivenFilesNeverAddDashA() throws {
        let tempRepo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: tempRepo) }
        let recorder = RecordingRunner()
        recorder.responses["/usr/bin/git -C \(tempRepo.path) rev-parse --short HEAD"] =
            (0, "abc1234\n", "")
        let actions = TaskGitActions(runner: recorder.runner)

        let hash = try actions.commit(
            task: task(), files: ["App/Foo.swift", "App/Bar.swift"], repoRoot: tempRepo.path
        )

        XCTAssertEqual(hash, "abc1234")
        XCTAssertEqual(recorder.calls.count, 3)
        XCTAssertEqual(
            recorder.calls[0],
            .init(executable: "/usr/bin/git", arguments: [
                "-C", tempRepo.path, "add", "--", "App/Foo.swift", "App/Bar.swift",
            ])
        )
        XCTAssertFalse(recorder.calls[0].arguments.contains("-A"), "must never git add -A")
        XCTAssertEqual(
            recorder.calls[1],
            .init(executable: "/usr/bin/git", arguments: [
                "-C", tempRepo.path, "commit", "-m", "task: daemon heartbeat ekle",
            ])
        )
    }

    func testCommitFailurePropagatesGitsStderr() throws {
        let tempRepo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: tempRepo) }
        let recorder = RecordingRunner()
        recorder.responses["/usr/bin/git -C \(tempRepo.path) commit"] =
            (1, "", "nothing to commit\n")
        let actions = TaskGitActions(runner: recorder.runner)

        XCTAssertThrowsError(
            try actions.commit(task: task(), files: ["a.txt"], repoRoot: tempRepo.path)
        ) { error in
            guard case .commitFailed(let detail)? = error as? TaskGitActions.GitActionError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(detail, "nothing to commit")
        }
    }

    // MARK: - Pull request refusal

    func testCreatePullRequestRefusesWhenGhIsMissing() async throws {
        let recorder = RecordingRunner()
        recorder.responses["/usr/bin/env which gh"] = (1, "", "")
        let actions = TaskGitActions(runner: recorder.runner)

        do {
            _ = try await actions.createPullRequest(task: task(), repoRoot: "/repo")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskGitActions.GitActionError, .ghNotInstalled)
        }
    }

    func testCreatePullRequestRefusesWhenGhIsNotAuthenticated() async throws {
        let recorder = RecordingRunner()
        recorder.responses["/usr/bin/env which gh"] = (0, "/usr/local/bin/gh\n", "")
        recorder.responses["/usr/bin/gh auth status"] = (1, "", "not logged in")
        let actions = TaskGitActions(runner: recorder.runner)

        do {
            _ = try await actions.createPullRequest(task: task(), repoRoot: "/repo")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskGitActions.GitActionError, .ghNotAuthenticated)
        }
    }

    func testCreatePullRequestReturnsTheURLGhReports() async throws {
        let recorder = RecordingRunner()
        recorder.responses["/usr/bin/env which gh"] = (0, "/usr/local/bin/gh\n", "")
        recorder.responses["/usr/bin/gh auth status"] = (0, "logged in\n", "")
        recorder.responses["/usr/bin/git -C /repo rev-parse --abbrev-ref HEAD"] =
            (0, "task/daemon-heartbeat-ekle\n", "")
        recorder.responses["/usr/bin/git -C /repo push"] = (0, "", "")
        recorder.responses["/usr/bin/gh pr create"] =
            (0, "https://github.com/acme/repo/pull/42\n", "")
        let actions = TaskGitActions(runner: recorder.runner)

        let url = try await actions.createPullRequest(task: task(), repoRoot: "/repo")
        XCTAssertEqual(url, URL(string: "https://github.com/acme/repo/pull/42"))
    }

    // MARK: - Helpers

    private func makeTempRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskGitActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        return dir
    }
}
