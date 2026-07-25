import XCTest
@testable import Uncoil

final class TaskFileGitStatusTests: XCTestCase {
    func testEveryDocumentedStateIsRecognised() {
        XCTAssertEqual(
            TaskFileGitStatus.from(porcelainCode: nil, contents: "- [ ] x\n"), .clean
        )
        XCTAssertEqual(
            TaskFileGitStatus.from(porcelainCode: " M", contents: "- [ ] x\n"), .modified
        )
        XCTAssertEqual(
            TaskFileGitStatus.from(porcelainCode: "??", contents: "- [ ] x\n"), .untracked
        )
        XCTAssertEqual(
            TaskFileGitStatus.from(porcelainCode: "!!", contents: "- [ ] x\n"), .ignored
        )
        XCTAssertEqual(
            TaskFileGitStatus.from(
                porcelainCode: " M", contents: "- [ ] x\n", isIgnored: true
            ),
            .ignored
        )
        XCTAssertEqual(
            TaskFileGitStatus.from(
                porcelainCode: nil, contents: "- [ ] x\n", isRepository: false
            ),
            .notTracked
        )
        XCTAssertTrue(TaskFileGitStatus.allLabelsAreNonEmpty)
    }

    func testGitReportedConflictIsAConflict() {
        for code in ["UU", "AA", "DU", "UD", "AU", "UA", "DD"] {
            guard case .conflict = TaskFileGitStatus.from(
                porcelainCode: code, contents: "- [ ] x\n"
            ) else {
                return XCTFail("\(code) should read as a conflict")
            }
        }
    }

    func testMarkersInTheFileAreAConflictEvenWhenGitSaysOtherwise() {
        // git can have been told the conflict is resolved while the markers are
        // still in the file; patching it then would corrupt the user's work.
        let contents = """
        ## A

        <<<<<<< HEAD
        - [ ] bizim görev
        =======
        - [ ] onların görevi
        >>>>>>> feature
        """
        let status = TaskFileGitStatus.from(porcelainCode: " M", contents: contents)
        guard case .conflict(let regions) = status else {
            return XCTFail("markers in the file mean conflict")
        }
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].startLine, 3)
        XCTAssertEqual(regions[0].separatorLine, 5)
        XCTAssertEqual(regions[0].endLine, 7)
        XCTAssertEqual(regions[0].ourLabel, "HEAD")
        XCTAssertEqual(regions[0].theirLabel, "feature")
        XCTAssertEqual(regions[0].lineCount, 5)
    }

    func testEditingIsRefusedOnlyWhileAConflictIsUnresolved() {
        XCTAssertFalse(
            TaskFileGitStatus.from(porcelainCode: "UU", contents: "x").isEditable
        )
        for status: TaskFileGitStatus in [.clean, .modified, .untracked, .ignored, .notTracked] {
            XCTAssertTrue(status.isEditable, status.label)
        }
    }

    func testMultipleConflictRegionsAreFound() {
        let contents = """
        <<<<<<< HEAD
        a
        =======
        b
        >>>>>>> other
        orta
        <<<<<<< HEAD
        c
        =======
        d
        >>>>>>> other
        """
        XCTAssertEqual(TaskFileGitStatus.conflictRegions(in: contents).count, 2)
    }

    func testAnUnterminatedMarkerIsNotReportedAsARegion() {
        // A half-written marker is not a resolved region; reporting it would
        // point the user at a range that does not exist.
        XCTAssertTrue(
            TaskFileGitStatus.conflictRegions(in: "<<<<<<< HEAD\na\n=======\nb\n").isEmpty
        )
    }

    func testCleanFileHasNoConflicts() {
        XCTAssertTrue(TaskFileGitStatus.clean.conflicts.isEmpty)
    }
}

private extension TaskFileGitStatus {
    /// Guards against a state being added without a label.
    static var allLabelsAreNonEmpty: Bool {
        let all: [TaskFileGitStatus] = [
            .clean, .modified, .untracked, .conflict(markers: []), .ignored, .notTracked,
        ]
        return all.allSatisfy { !$0.label.isEmpty }
    }
}

final class TaskGitStatusReaderTests: XCTestCase {
    func testPorcelainOutputIsReadPerPath() {
        let output = """
         M TODO.md
        ?? docs/TODO.md
        !! build/TODO.md
        R  eski/TODO.md -> yeni/TODO.md
        """
        let codes = GitService.parseFileStatuses(output)
        XCTAssertEqual(codes["TODO.md"], " M")
        XCTAssertEqual(codes["docs/TODO.md"], "??")
        XCTAssertEqual(codes["build/TODO.md"], "!!")
        XCTAssertEqual(
            codes["yeni/TODO.md"], "R ",
            "a rename is reported at the path that exists now"
        )
        XCTAssertNil(codes["eski/TODO.md"])
    }

    func testEachSourceGetsItsOwnStatus() {
        let statuses = TaskGitStatusReader.statuses(
            codes: ["TODO.md": " M", "build/TODO.md": "!!", "b/TODO.md": "UU"],
            relativePaths: [
                "TODO.md": "/repo/TODO.md",
                "build/TODO.md": "/repo/build/TODO.md",
                "b/TODO.md": "/repo/b/TODO.md",
                "c/TODO.md": "/repo/c/TODO.md",
            ],
            contentsByPath: [
                "/repo/TODO.md": "- [ ] a\n",
                "/repo/build/TODO.md": "- [ ] b\n",
                "/repo/b/TODO.md": "- [ ] c\n",
                "/repo/c/TODO.md": "- [ ] d\n",
            ],
            isRepository: true
        )
        XCTAssertEqual(statuses["/repo/TODO.md"], .modified)
        XCTAssertEqual(statuses["/repo/build/TODO.md"], .ignored)
        XCTAssertEqual(statuses["/repo/b/TODO.md"], .conflict(markers: []))
        XCTAssertEqual(
            statuses["/repo/c/TODO.md"], .clean,
            "git saying nothing about a file means it is clean"
        )
    }

    func testOutsideARepositoryNothingIsTracked() {
        let statuses = TaskGitStatusReader.statuses(
            codes: [:],
            relativePaths: ["TODO.md": "/tmp/TODO.md"],
            contentsByPath: ["/tmp/TODO.md": "- [ ] a\n"],
            isRepository: false
        )
        XCTAssertEqual(statuses["/tmp/TODO.md"], .notTracked)
    }

    func testRelativePathsAreTakenFromTheRepoRoot() {
        XCTAssertEqual(
            TaskGitStatusReader.relativePath(of: "/repo/docs/TODO.md", under: "/repo"),
            "docs/TODO.md"
        )
        XCTAssertEqual(
            TaskGitStatusReader.relativePath(of: "/repo/docs/TODO.md", under: "/repo/"),
            "docs/TODO.md"
        )
        XCTAssertEqual(
            TaskGitStatusReader.relativePath(of: "/other/TODO.md", under: "/repo"),
            "/other/TODO.md",
            "a file outside the repo keeps its absolute path"
        )
    }

    func testAStatusIsReadFromARealRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-git-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try git(["init", "-q"])
        let todo = root.appendingPathComponent("TODO.md")
        try "- [ ] görev\n".write(to: todo, atomically: true, encoding: .utf8)

        let untracked = TaskGitStatusReader.statuses(
            repoRoot: root.path, contentsByPath: [todo.path: "- [ ] görev\n"]
        )
        XCTAssertEqual(untracked[todo.path], .untracked)

        try git(["add", "TODO.md"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "ilk"])
        XCTAssertEqual(
            TaskGitStatusReader.statuses(
                repoRoot: root.path, contentsByPath: [todo.path: "- [ ] görev\n"]
            )[todo.path],
            .clean
        )

        try "- [x] görev\n".write(to: todo, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            TaskGitStatusReader.statuses(
                repoRoot: root.path, contentsByPath: [todo.path: "- [x] görev\n"]
            )[todo.path],
            .modified
        )

        // Regression: porcelain writes " M path" for modified-but-unstaged, and
        // trimming the command output ate that leading space, so the first
        // entry's path came back one character short ("ODO.md").
        let snapshot = GitService.snapshot(repoPath: root.path)
        XCTAssertEqual(snapshot.changedFiles.map(\.path), ["TODO.md"])
        XCTAssertEqual(snapshot.changedFiles.first?.status, "M")
    }
}

final class TaskConflictTrackerTests: XCTestCase {
    private let path = "/repo/TODO.md"

    func testAConflictAppearingAndClearingIsReportedOnce() {
        var tracker = TaskConflictTracker()
        XCTAssertTrue(tracker.apply([path: .clean]).isEmpty)

        XCTAssertEqual(
            tracker.apply([path: .conflict(markers: [])]), [.becameConflicted(path: path)]
        )
        XCTAssertTrue(
            tracker.apply([path: .conflict(markers: [])]).isEmpty,
            "a conflict that is still there is not news"
        )

        XCTAssertEqual(tracker.apply([path: .modified]), [.resolved(path: path)])
        XCTAssertTrue(tracker.apply([path: .modified]).isEmpty)
        XCTAssertFalse(tracker.isConflicted(path))
    }

    func testAFileThatDisappearsStopsBeingAConflict() {
        var tracker = TaskConflictTracker()
        _ = tracker.apply([path: .conflict(markers: [])])
        XCTAssertEqual(tracker.apply([:]), [.resolved(path: path)])
        XCTAssertTrue(tracker.conflicted.isEmpty)
    }

    func testSeveralSourcesAreTrackedIndependently() {
        var tracker = TaskConflictTracker()
        let other = "/repo/docs/TODO.md"
        _ = tracker.apply([path: .conflict(markers: []), other: .clean])
        XCTAssertEqual(
            tracker.apply([path: .conflict(markers: []), other: .conflict(markers: [])]),
            [.becameConflicted(path: other)]
        )
        XCTAssertEqual(tracker.conflicted, [path, other])
    }
}

final class TaskDiffAuditTests: XCTestCase {
    private func document(_ raw: String) -> TaskDocument {
        TodoParser.parse(raw, path: "/repo/TODO.md")
    }

    private let file = """
    # Aşama 1

    ## Todo

    - [ ] ilk görev
      açıklama
    - [ ] ikinci görev

    Son paragraf.
    """

    // MARK: - Edits that stay inside their block

    func testACheckboxEditPassesTheAudit() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        let after = try TodoEditor.apply([TodoEditor.togglePatch(for: task)], to: before)
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .checkbox,
                allowedLines: TaskDiffAudit.allowedLines(for: task)
            ).isEmpty
        )
    }

    func testATitleEditPassesTheAudit() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ikinci görev" })
        let patch = try XCTUnwrap(TodoEditor.renamePatch(for: task, to: "yeni metin"))
        let after = try TodoEditor.apply([patch], to: before)
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .title,
                allowedLines: TaskDiffAudit.allowedLines(for: task)
            ).isEmpty
        )
    }

    func testADescriptionEditPassesTheAudit() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        let patch = try XCTUnwrap(
            TodoEditor.descriptionPatch(for: task, to: "yeni açıklama")
        )
        let after = try TodoEditor.apply([patch], to: before)
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .description,
                allowedLines: TaskDiffAudit.allowedLines(for: task)
            ).isEmpty
        )
    }

    func testAMoveAndADeletePassTheAudit() throws {
        let before = """
        ## Todo

        - [ ] taşınacak
          açıklaması

        ## Done

        - [x] bitmiş
        """
        let parsed = document(before)
        let task = try XCTUnwrap(parsed.tasks.first { $0.text == "taşınacak" })

        let moved = try TodoEditor.apply(
            try TodoEditor.movePatches(task: task, to: ["Done"], in: parsed), to: before
        )
        let moveFindings = TaskDiffAudit.verify(
            before: before, after: moved, expectation: .move,
            allowedLines: TaskDiffAudit.allowedLines(for: task)
        )
        XCTAssertTrue(moveFindings.isEmpty, "\(moveFindings.map(\.message))")

        let block = TodoEditor.blockWithDescendants(of: task, in: parsed)
        let deleted = try TodoEditor.apply(
            [.init(range: block.range, replacement: "", summary: "sil")], to: before
        )
        let deleteFindings = TaskDiffAudit.verify(
            before: before, after: deleted, expectation: .delete,
            allowedLines: TaskDiffAudit.allowedLines(for: task)
        )
        XCTAssertTrue(deleteFindings.isEmpty, "\(deleteFindings.map(\.message))")
    }

    // MARK: - Edits that must be reported

    func testChangingALineOutsideTheBlockIsReported() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        // A heading rewritten alongside the checkbox.
        let after = before
            .replacingOccurrences(of: "- [ ] ilk görev", with: "- [x] ilk görev")
            .replacingOccurrences(of: "## Todo", with: "## Yapılacak")
        let findings = TaskDiffAudit.verify(
            before: before, after: after, expectation: .checkbox,
            allowedLines: TaskDiffAudit.allowedLines(for: task)
        )
        XCTAssertTrue(findings.contains { finding in
            if case .changedOutsideBlock = finding.kind { return true }
            return false
        })
        XCTAssertTrue(findings[0].message.contains("dışında"))
    }

    func testAWholeFileRewriteIsReportedAsAnError() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        // What a regenerating writer would produce: same tasks, everything else
        // reflowed.
        let after = """
        # Aşama 1
        ## Todo
        * [x] ilk görev
        * [ ] ikinci görev
        Son paragraf yeniden yazıldı.
        """
        let findings = TaskDiffAudit.verify(
            before: before, after: after, expectation: .checkbox,
            allowedLines: TaskDiffAudit.allowedLines(for: task)
        )
        XCTAssertTrue(findings.contains { finding in
            if case .wholeFileRewritten = finding.kind { return true }
            return false
        })
    }

    func testACheckboxEditThatChangesTheLineCountIsReported() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        let after = before.replacingOccurrences(
            of: "- [ ] ilk görev", with: "- [x] ilk görev\n  fazladan satır"
        )
        let findings = TaskDiffAudit.verify(
            before: before, after: after, expectation: .checkbox,
            allowedLines: TaskDiffAudit.allowedLines(for: task)
        )
        XCTAssertTrue(findings.contains { finding in
            if case .unexpectedLineCountChange = finding.kind { return true }
            return false
        })
    }

    func testADescriptionEditMayChangeTheLineCount() throws {
        let before = file
        let task = try XCTUnwrap(document(before).tasks.first { $0.text == "ilk görev" })
        let after = before.replacingOccurrences(
            of: "  açıklama", with: "  açıklama\n  ikinci satır"
        )
        XCTAssertFalse(
            TaskDiffAudit.verify(
                before: before, after: after, expectation: .description,
                allowedLines: TaskDiffAudit.allowedLines(for: task)
            ).contains { finding in
                if case .unexpectedLineCountChange = finding.kind { return true }
                return false
            }
        )
    }

    func testAnIdenticalFileHasNothingToReport() {
        XCTAssertTrue(
            TaskDiffAudit.verify(
                before: file, after: file, expectation: .checkbox, allowedLines: [1]
            ).isEmpty
        )
    }

    func testAllowedLinesCoverTheWholeBlockIncludingDescription() throws {
        let task = try XCTUnwrap(document(file).tasks.first { $0.text == "ilk görev" })
        let allowed = TaskDiffAudit.allowedLines(for: task)
        XCTAssertEqual(allowed.count, 2, "the task line and its description line")
        XCTAssertTrue(allowed.contains(task.lineRange.startLine))
    }

    func testEveryExpectationHasALabelAndAClearLineCountRule() {
        for expectation: TaskDiffAudit.Expectation in [
            .checkbox, .title, .description, .move, .delete,
        ] {
            XCTAssertFalse(expectation.label.isEmpty)
        }
        XCTAssertFalse(TaskDiffAudit.Expectation.checkbox.mayChangeLineCount)
        XCTAssertFalse(TaskDiffAudit.Expectation.title.mayChangeLineCount)
        XCTAssertTrue(TaskDiffAudit.Expectation.description.mayChangeLineCount)
        XCTAssertTrue(TaskDiffAudit.Expectation.move.mayChangeLineCount)
        XCTAssertTrue(TaskDiffAudit.Expectation.delete.mayChangeLineCount)
    }
}

final class GitMergeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try write("satır bir\n", to: "file.txt")
        try git(["add", "."])
        try commit("ilk")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func git(_ arguments: [String], at path: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path ?? root.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    private func commit(_ message: String, at path: String? = nil) throws {
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", message], at: path)
    }

    private func write(_ contents: String, to name: String, at directory: URL? = nil) throws {
        try contents.write(
            to: (directory ?? root).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    func testAnApprovedMergeBringsTheBranchIn() throws {
        let worktree = root.appendingPathComponent(".uncoil-worktrees/task", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "uncoil/task", worktree.path])
        try write("satır iki\n", to: "file.txt", at: worktree)
        try git(["add", "."], at: worktree.path)
        try commit("görev işi", at: worktree.path)

        let result = GitService.merge(
            repoPath: root.path, branch: "uncoil/task", message: "Merge task: görev"
        )
        guard case .success(let commit) = result else {
            return XCTFail("merge should succeed: \(result)")
        }
        XCTAssertNotNil(commit)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8),
            "satır iki\n"
        )
    }

    func testAConflictingMergeIsAbortedAndLeavesNoHalfMergedTree() throws {
        let worktree = root.appendingPathComponent(".uncoil-worktrees/task", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "uncoil/task", worktree.path])
        try write("dal tarafı\n", to: "file.txt", at: worktree)
        try git(["add", "."], at: worktree.path)
        try commit("dal", at: worktree.path)

        // The same line changed on main: the merge cannot succeed.
        try write("ana taraf\n", to: "file.txt")
        try git(["add", "."])
        try commit("ana")

        let result = GitService.merge(
            repoPath: root.path, branch: "uncoil/task", message: "Merge task: görev"
        )
        guard case .failure(let error) = result else {
            return XCTFail("a conflicting merge must fail: \(result)")
        }
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8),
            "ana taraf\n",
            "the tree is left exactly as it was"
        )
        XCTAssertTrue(
            GitService.conflictedFiles(repoPath: root.path).isEmpty,
            "the failed merge was aborted, not left open"
        )
    }

    func testMergingOutsideARepositoryIsRefused() {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-not-a-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        guard case .failure = GitService.merge(
            repoPath: outside.path, branch: "x", message: "m"
        ) else {
            return XCTFail("a non-repository must be refused")
        }
    }

    func testTheDiffIsBoundedAndReportsWhatItDropped() throws {
        try write((1...600).map { "satır \($0)" }.joined(separator: "\n"), to: "file.txt")
        let diff = GitService.diff(repoPath: root.path, maxLines: 50)
        XCTAssertTrue(diff.contains("satır daha"), "a cap is reported, never silent")
        XCTAssertLessThan(diff.split(separator: "\n").count, 60)
    }
}
