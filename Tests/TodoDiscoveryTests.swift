import XCTest
@testable import Uncoil

final class TodoDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTodoScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ relativePath: String, _ contents: String = "- [ ] görev\n") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func find(_ rules: TodoDiscovery.Rules = .default) -> [TodoDiscovery.Found] {
        // Ignored paths are passed explicitly so the tests do not depend on the
        // temp directory being a git repository.
        TodoDiscovery.find(projectRoot: root.path, rules: rules, ignoredPaths: [])
    }

    func testFindsRootAndNestedTodoFiles() throws {
        try write("TODO.md")
        try write("App/Feature/TODO.md")
        try write("docs/TODO.md")

        let found = find()
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.first?.displayPath, "TODO.md")
        XCTAssertTrue(found.first?.isRoot ?? false)
        XCTAssertEqual(
            found.dropFirst().map(\.displayPath),
            ["App/Feature/TODO.md", "docs/TODO.md"],
            "the project's own TODO comes first, then the rest alphabetically"
        )
    }

    func testSkipsGeneratedAndDependencyDirectories() throws {
        try write("TODO.md")
        for directory in [".git", "node_modules", "build", ".build", "DerivedData", "Pods", "vendor"] {
            try write("\(directory)/TODO.md")
        }
        try write("App/node_modules/deep/TODO.md")

        XCTAssertEqual(find().map(\.displayPath), ["TODO.md"])
    }

    func testUserCanExcludeAndIncludeDirectories() throws {
        try write("TODO.md")
        try write("docs/TODO.md")
        try write("build/TODO.md")

        var rules = TodoDiscovery.Rules.default
        rules.excludedDirectories = ["docs"]
        XCTAssertEqual(find(rules).map(\.displayPath), ["TODO.md"])

        rules = .default
        rules.includedDirectories = ["build"]
        XCTAssertEqual(
            Set(find(rules).map(\.displayPath)),
            ["TODO.md", "build/TODO.md", "docs/TODO.md"],
            "an explicit include beats the default exclusion"
        )
    }

    func testUserCanExcludeASpecificPath() throws {
        try write("TODO.md")
        try write("docs/TODO.md")
        var rules = TodoDiscovery.Rules.default
        rules.excludedPaths = ["docs/TODO.md"]
        XCTAssertEqual(find(rules).map(\.displayPath), ["TODO.md"])
    }

    func testRecognisesAlternativeFileNames() throws {
        try write("todo.md")
        try write("TODOS.md")
        try write("PLAN.md")
        XCTAssertEqual(Set(find().map(\.displayPath)), ["TODOS.md", "todo.md"])

        var rules = TodoDiscovery.Rules.default
        rules.additionalFileNames = ["PLAN.md"]
        XCTAssertTrue(find(rules).map(\.displayPath).contains("PLAN.md"))
    }

    func testDepthIsBounded() throws {
        try write("a/b/c/d/e/f/g/h/i/TODO.md")
        var rules = TodoDiscovery.Rules.default
        rules.maximumDepth = 3
        XCTAssertTrue(find(rules).isEmpty)
        rules.maximumDepth = 12
        XCTAssertEqual(find(rules).count, 1)
    }

    func testSymlinkedDirectoriesAreNotFollowed() throws {
        try write("TODO.md")
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("- [ ] dışarıda\n".utf8).write(to: outside.appendingPathComponent("TODO.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside
        )
        XCTAssertEqual(find().map(\.displayPath), ["TODO.md"])
    }

    func testMissingProjectRootYieldsNothing() {
        XCTAssertTrue(
            TodoDiscovery.find(projectRoot: "/nope/does/not/exist", ignoredPaths: []).isEmpty
        )
    }

    func testGitIgnoredPathsAreSkippedWhenReported() throws {
        try write("TODO.md")
        try write("generated/TODO.md")
        let found = TodoDiscovery.find(
            projectRoot: root.path, ignoredPaths: ["generated"]
        )
        XCTAssertEqual(found.map(\.displayPath), ["TODO.md"])
    }

    // MARK: - Loading and aggregating

    func testLoadParsesEverySourceAndCountsTasks() throws {
        try write("TODO.md", "- [ ] bir\n- [x] iki\n")
        try write("docs/TODO.md", "- [ ] üç\n")

        let projectID = UUID()
        let loaded = TodoDiscovery.load(
            projectID: projectID, projectRoot: root.path, now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(loaded.count, 2)

        let rootSource = loaded[0].source
        XCTAssertEqual(rootSource.projectID, projectID)
        XCTAssertEqual(rootSource.taskCount, 2)
        XCTAssertEqual(rootSource.openTaskCount, 1)
        XCTAssertTrue(rootSource.isRoot)
        XCTAssertFalse(rootSource.contentHash.isEmpty)

        XCTAssertFalse(loaded[1].source.isRoot)
        XCTAssertEqual(loaded[1].document.tasks.map(\.text), ["üç"])
    }

    func testAggregateViewSpansEverySource() throws {
        try write("TODO.md", "- [ ] bir\n")
        try write("docs/TODO.md", "- [ ] iki\n")
        let aggregate = TodoDiscovery.aggregate(
            TodoDiscovery.load(projectID: UUID(), projectRoot: root.path)
        )
        XCTAssertEqual(aggregate.map(\.text), ["bir", "iki"])
        XCTAssertEqual(Set(aggregate.map(\.sourcePath)).count, 2)
    }

    // MARK: - Cheap checks and incremental scans

    func testHasSourcesAnswersWithoutAFullWalk() throws {
        XCTAssertFalse(TodoDiscovery.hasSources(projectRoot: root.path))
        try write("docs/TODO.md")
        XCTAssertTrue(TodoDiscovery.hasSources(projectRoot: root.path))
        XCTAssertFalse(TodoDiscovery.hasSources(projectRoot: "/nope/does/not/exist"))
    }

    func testFirstMatchOnlyStopsAtTheFirstSource() throws {
        try write("TODO.md")
        try write("docs/TODO.md")
        let found = TodoDiscovery.find(
            projectRoot: root.path, ignoredPaths: [], firstMatchOnly: true
        )
        XCTAssertEqual(found.count, 1)
    }

    func testScanReusesCachedSourcesForUntouchedFiles() throws {
        try write("TODO.md", "- [ ] bir\n")
        let projectID = UUID()
        let first = TodoDiscovery.scan(
            projectID: projectID, projectRoot: root.path, now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(first.reusedPaths.isEmpty)

        var cache: [String: TodoDiscovery.CachedSource] = [:]
        for entry in first.entries {
            guard let stamp = first.stamps[entry.source.path] else { continue }
            cache[entry.source.path] = TodoDiscovery.CachedSource(
                stamp: stamp, source: entry.source, document: entry.document
            )
        }
        let second = TodoDiscovery.scan(
            projectID: projectID,
            projectRoot: root.path,
            now: Date(timeIntervalSince1970: 100),
            cache: cache
        )
        XCTAssertEqual(second.reusedPaths, Set(cache.keys))
        // Reused means never re-read: the read timestamp is the original one.
        XCTAssertEqual(second.entries.first?.source.lastReadAt, Date(timeIntervalSince1970: 0))
    }

    func testScanRereadsAFileWhoseStampMoved() throws {
        try write("TODO.md", "- [ ] bir\n")
        let projectID = UUID()
        let first = TodoDiscovery.scan(projectID: projectID, projectRoot: root.path)
        var cache: [String: TodoDiscovery.CachedSource] = [:]
        for entry in first.entries {
            guard let stamp = first.stamps[entry.source.path] else { continue }
            cache[entry.source.path] = TodoDiscovery.CachedSource(
                stamp: stamp, source: entry.source, document: entry.document
            )
        }
        try write("TODO.md", "- [ ] bir\n- [ ] iki\n")
        let second = TodoDiscovery.scan(
            projectID: projectID, projectRoot: root.path, cache: cache
        )
        XCTAssertTrue(second.reusedPaths.isEmpty)
        XCTAssertEqual(second.entries.first?.document.tasks.count, 2)
    }

    func testRelativePathFallsBackToTheFileNameOutsideTheRoot() {
        XCTAssertEqual(
            TodoDiscovery.relativePath(
                of: URL(fileURLWithPath: "/elsewhere/TODO.md"),
                from: URL(fileURLWithPath: "/project")
            ),
            "TODO.md"
        )
    }
}

final class PortableTaskIDTests: XCTestCase {
    func testIDIsAPlainHTMLComment() {
        let comment = PortableTaskID.comment(for: "abc123")
        XCTAssertEqual(comment, "<!-- uncoil:task:abc123 -->")
        XCTAssertTrue(comment.hasPrefix("<!--"), "invisible in rendered Markdown")
    }

    func testParsesAnIDOutOfATaskBlock() {
        let block = """
        - [ ] görev
          <!-- uncoil:task:abc123 -->
          açıklama
        """
        XCTAssertEqual(PortableTaskID.parse(inBlock: block), "abc123")
        XCTAssertTrue(PortableTaskID.hasID(inBlock: block))
    }

    func testABlockWithoutAnIDIsFine() {
        let block = "- [ ] görev\n  açıklama\n"
        XCTAssertNil(PortableTaskID.parse(inBlock: block))
        XCTAssertFalse(PortableTaskID.hasID(inBlock: block))
    }

    func testOtherCommentsAreIgnored() {
        XCTAssertNil(PortableTaskID.parse(inBlock: "- [ ] görev\n  <!-- başka yorum -->\n"))
    }

    func testIDLineIsIndentedToStayInsideTheTaskBlock() {
        let line = PortableTaskID.line(for: "abc", indent: "  ")
        XCTAssertTrue(line.hasPrefix("    "), "indented past the task marker")
        XCTAssertTrue(line.contains("uncoil:task:abc"))
    }

    func testAnIDInsideABlockSurvivesAParseRoundTrip() {
        let raw = """
        ## A

        - [ ] görev
          <!-- uncoil:task:abc123 -->

        - [x] diğer
        """
        let document = TodoParser.parse(raw, path: "/p/TODO.md")
        XCTAssertEqual(document.render(), raw)
        XCTAssertEqual(document.tasks.count, 2)
        XCTAssertEqual(
            PortableTaskID.parse(inBlock: document.tasks[0].rawBlock),
            "abc123",
            "the id travels with the task's own block"
        )
    }
}
