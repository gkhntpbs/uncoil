import XCTest
@testable import Uncoil

@MainActor
final class TodoSourceStoreTests: XCTestCase {
    private var root: URL!
    private var store: TodoSourceStore!
    private let projectID = UUID()
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Created first, then resolved: discovery canonicalises the root, the
        // temp directory lives behind the /var → /private/var symlink, and
        // resolution only happens for a path that already exists.
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSourceStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        root = created.resolvingSymlinksInPath()
        var rules = TodoDiscovery.Rules.default
        rules.respectsGitIgnore = false
        store = TodoSourceStore(projectID: projectID, projectRoot: root.path, rules: rules)
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    /// The path the store itself reports for a source. Constructing it from the
    /// test root would not match: an enumerated child comes back under
    /// /private/var while the root normalises to /var.
    private func path(_ relativePath: String) -> String {
        store.sources.first { $0.displayPath == relativePath }?.path
            ?? root.appendingPathComponent(relativePath).path
    }

    private func tick() -> Date {
        clock = clock.addingTimeInterval(10)
        return clock
    }

    // MARK: - Discovery and first scan

    func testFirstScanReportsEverySourceAsAdded() throws {
        try write("TODO.md", "- [ ] bir\n")
        try write("docs/TODO.md", "- [ ] iki\n")

        let changes = store.refresh(now: tick())
        XCTAssertEqual(changes[path("TODO.md")], .added)
        XCTAssertEqual(changes[path("docs/TODO.md")], .added)
        XCTAssertEqual(store.sources.count, 2)
        XCTAssertEqual(store.allTasks.map(\.text), ["bir", "iki"])
        XCTAssertTrue(changes.values.allSatisfy(\.needsBoardRecompute))
    }

    func testUnchangedFileIsReportedAsUnchanged() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        XCTAssertEqual(store.refresh(now: tick())[path("TODO.md")], .unchanged)
    }

    // MARK: - Change classification

    func testTickingACheckboxIsACheckboxOnlyChange() throws {
        try write("TODO.md", "## A\n\n- [ ] bir\n- [ ] iki\n")
        store.refresh(now: tick())
        let before = try XCTUnwrap(store.document(for: path("TODO.md")))
        let target = try XCTUnwrap(before.tasks.first { $0.text == "iki" })

        try write("TODO.md", "## A\n\n- [ ] bir\n- [x] iki\n")
        let change = store.refresh(now: tick())[path("TODO.md")]

        guard case .checkboxesChanged(let ids) = change else {
            return XCTFail("expected a checkbox-only change, got \(String(describing: change))")
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertFalse(
            change?.needsBoardRecompute ?? true,
            "a tick does not need the board recomputed from scratch"
        )
        // The id is the new one, and the task really is done now.
        let after = try XCTUnwrap(store.document(for: path("TODO.md")))
        XCTAssertEqual(after.tasks.first { $0.text == "iki" }?.isDone, true)
        XCTAssertNotEqual(ids.first, target.id, "the block hash moved with the mark")
    }

    func testAddingATaskIsStructural() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        try write("TODO.md", "- [ ] bir\n- [ ] iki\n")
        let change = store.refresh(now: tick())[path("TODO.md")]
        XCTAssertEqual(change, .structureChanged)
        XCTAssertTrue(change?.needsBoardRecompute ?? false)
    }

    func testRewordingATaskIsStructural() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        try write("TODO.md", "- [ ] bir başka\n")
        XCTAssertEqual(store.refresh(now: tick())[path("TODO.md")], .structureChanged)
    }

    func testRenamingAHeadingForcesABoardRecompute() throws {
        try write("TODO.md", "## Eski\n\n- [ ] bir\n")
        store.refresh(now: tick())
        try write("TODO.md", "## Yeni\n\n- [ ] bir\n")
        let change = store.refresh(now: tick())[path("TODO.md")]
        XCTAssertEqual(change, .structureChanged)
        XCTAssertTrue(change?.needsBoardRecompute ?? false)
    }

    func testEditingProseOnlyIsStillReportedAsStructuralRatherThanSilent() throws {
        try write("TODO.md", "Giriş.\n\n- [ ] bir\n")
        store.refresh(now: tick())
        try write("TODO.md", "Başka giriş.\n\n- [ ] bir\n")
        // Nothing about the tasks changed, but the file did — the UI must not be
        // told "unchanged" when the content it renders moved.
        XCTAssertEqual(store.refresh(now: tick())[path("TODO.md")], .structureChanged)
    }

    // MARK: - Missing and restored

    func testDeletedSourceKeepsItsTasksAndIsMarkedMissing() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        try remove("TODO.md")

        let missingAt = tick()
        XCTAssertEqual(store.refresh(now: missingAt)[path("TODO.md")], .missing)
        XCTAssertEqual(store.status(for: path("TODO.md")), .missing(since: missingAt))
        XCTAssertEqual(store.status(for: path("TODO.md")).label, "Source missing")
        XCTAssertEqual(
            store.allTasks.map(\.text), ["bir"],
            "relations are kept: the file may come back"
        )
        XCTAssertEqual(store.sources.count, 1)
    }

    func testMissingSinceDoesNotDriftOnRepeatedScans() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        try remove("TODO.md")
        let first = tick()
        store.refresh(now: first)
        store.refresh(now: tick())
        XCTAssertEqual(store.status(for: path("TODO.md")), .missing(since: first))
    }

    func testRestoredSourceIsReconnected() throws {
        try write("TODO.md", "- [ ] bir\n")
        store.refresh(now: tick())
        try remove("TODO.md")
        store.refresh(now: tick())

        try write("TODO.md", "- [ ] bir\n")
        let change = store.refresh(now: tick())[path("TODO.md")]
        XCTAssertEqual(change, .restored)
        XCTAssertEqual(store.status(for: path("TODO.md")), .present)
        XCTAssertTrue(change?.needsBoardRecompute ?? false)
    }

    func testMovedFileIsRecognisedByItsContent() throws {
        try write("TODO.md", "- [ ] taşınan\n")
        store.refresh(now: tick())
        try remove("TODO.md")
        try write("docs/TODO.md", "- [ ] taşınan\n")

        let changes = store.refresh(now: tick())
        XCTAssertEqual(changes[path("docs/TODO.md")], .moved(from: path("TODO.md")))
        XCTAssertEqual(changes[path("TODO.md")], .missing)
    }

    // MARK: - Relinking tracked state

    func testTrackedTaskSurvivesAnUnrelatedEdit() throws {
        try write("TODO.md", "## A\n\n- [ ] izlenen görev\n")
        store.refresh(now: tick())
        let tracked = try XCTUnwrap(store.allTasks.first)

        try write("TODO.md", "## A\n\n- [ ] izlenen görev\n\n## B\n\n- [ ] yeni\n")
        store.refresh(trackedFingerprints: ["assignment": tracked.fingerprint], now: tick())
        XCTAssertTrue(
            store.needsRelinking.isEmpty,
            "an unchanged task is still found after an edit elsewhere"
        )
    }

    func testTrackedTaskThatVanishedNeedsRelinking() throws {
        try write("TODO.md", "## A\n\n- [ ] izlenen görev\n")
        store.refresh(now: tick())
        let tracked = try XCTUnwrap(store.allTasks.first)

        try write("TODO.md", "## A\n\n- [ ] tamamen farklı bir iş\n")
        store.refresh(trackedFingerprints: ["assignment": tracked.fingerprint], now: tick())
        XCTAssertEqual(store.needsRelinking, ["assignment"])
    }

    func testTrackedTaskInAMissingFileIsNotFlagged() throws {
        try write("TODO.md", "- [ ] izlenen\n")
        store.refresh(now: tick())
        let tracked = try XCTUnwrap(store.allTasks.first)

        try remove("TODO.md")
        store.refresh(trackedFingerprints: ["assignment": tracked.fingerprint], now: tick())
        XCTAssertTrue(
            store.needsRelinking.isEmpty,
            "a file that is expected back does not invalidate its assignments"
        )
    }

    func testTickingACheckboxDoesNotBreakATrackedTask() throws {
        try write("TODO.md", "## A\n\n- [ ] izlenen\n")
        store.refresh(now: tick())
        let tracked = try XCTUnwrap(store.allTasks.first)

        try write("TODO.md", "## A\n\n- [x] izlenen\n")
        store.refresh(trackedFingerprints: ["assignment": tracked.fingerprint], now: tick())
        XCTAssertTrue(store.needsRelinking.isEmpty)
    }
}

@MainActor
final class TodoSourceWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func testWatcherFiresWhenAWatchedFileIsRewritten() async throws {
        let url = root.appendingPathComponent("TODO.md")
        try Data("- [ ] bir\n".utf8).write(to: url)

        var fired = 0
        let watcher = TodoSourceWatcher(pollInterval: 3600) { fired += 1 }
        watcher.watch(paths: [url.path])
        defer { watcher.stop() }

        // An atomic write replaces the inode, which is the case that kills a
        // naive descriptor watch.
        try Data("- [x] bir\n".utf8).write(to: url, options: .atomic)
        try await waitUntil { fired > 0 }
        XCTAssertGreaterThan(fired, 0)
    }

    func testWatcherKeepsWorkingAfterTheFileIsReplacedTwice() async throws {
        let url = root.appendingPathComponent("TODO.md")
        try Data("- [ ] bir\n".utf8).write(to: url)

        var fired = 0
        let watcher = TodoSourceWatcher(pollInterval: 3600) { fired += 1 }
        watcher.watch(paths: [url.path])
        defer { watcher.stop() }

        try Data("- [x] bir\n".utf8).write(to: url, options: .atomic)
        try await waitUntil { fired > 0 }
        let afterFirst = fired

        try Data("- [ ] bir\n- [ ] iki\n".utf8).write(to: url, options: .atomic)
        try await waitUntil { fired > afterFirst }
        XCTAssertGreaterThan(fired, afterFirst, "the watch re-arms after a replacement")
    }

    func testPollFiresEvenWithoutFilesystemEvents() async throws {
        var fired = 0
        let watcher = TodoSourceWatcher(pollInterval: 0.05) { fired += 1 }
        watcher.start(paths: [])
        defer { watcher.stop() }
        try await waitUntil { fired > 0 }
        XCTAssertGreaterThan(fired, 0)
    }

    func testStoppingSilencesTheWatcher() async throws {
        let url = root.appendingPathComponent("TODO.md")
        try Data("- [ ] bir\n".utf8).write(to: url)
        var fired = 0
        let watcher = TodoSourceWatcher(pollInterval: 0.05) { fired += 1 }
        watcher.start(paths: [url.path])
        try await waitUntil { fired > 0 }
        watcher.stop()
        let afterStop = fired
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fired, afterStop)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
