import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the Tests screen offscreen. Set `UNCOIL_TESTS_SAMPLE_DIR` to write
/// the PNG.
///
/// The two cards are the whole point of the layout: one suite whose output was
/// parsed and one whose was not. The second must not read as "everything
/// passed" when all that is known is an exit code.
@MainActor
final class TestsViewRenderTests: XCTestCase {
    private var directory: URL!
    private var project: Project!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-testsview-\(UUID().uuidString)", isDirectory: true)
        let repo = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        project = Project(name: "repo", rootPath: repo.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheTestsScreenRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["UNCOIL_TESTS_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_TESTS_SAMPLE_DIR to write the Tests screen sample")
        }
        try TestConfigFile.save([
            TestSuiteConfiguration(
                id: "unit", name: "Unit tests", command: "swift test",
                framework: .swift, isDefault: true
            ),
            TestSuiteConfiguration(
                id: "e2e", name: "End-to-end", command: "./run-e2e.sh", framework: .unknown
            ),
        ], projectRoot: project.rootURL)

        let registry = TestRegistry.shared
        registry.dataDirectory = directory
        TestRegistry.saveRecord(
            TestRunRecord(
                id: "a", suiteID: "unit",
                startedAt: Date(timeIntervalSinceNow: -95),
                finishedAt: Date(timeIntervalSinceNow: -90),
                exitCode: 1,
                summary: TestRunSummary(passed: 128, failed: 2, skipped: 1, isDetailed: true),
                cases: [
                    TestCaseResult(
                        suite: "SidebarChildSessionTests",
                        name: "testACycleLosesNoSession", outcome: .failed
                    ),
                    TestCaseResult(
                        suite: "DockerStatusTests",
                        name: "testEmptyOutputIsNoContainers", outcome: .failed
                    ),
                ],
                logTail: "XCTAssertEqual failed: (\"2\") is not equal to (\"3\")"
            ),
            directory: registry.resultsDirectory(projectID: project.id)
        )
        TestRegistry.saveRecord(
            TestRunRecord(
                id: "b", suiteID: "e2e",
                startedAt: Date(timeIntervalSinceNow: -400),
                finishedAt: Date(timeIntervalSinceNow: -380),
                exitCode: 0,
                summary: TestRunSummary(isDetailed: false),
                cases: [], logTail: "done\n"
            ),
            directory: registry.resultsDirectory(projectID: project.id)
        )
        registry.loadPersistedResults(project: project)

        let host = NSHostingView(
            rootView: ProjectTestsView(project: project)
                .padding(16)
                .frame(width: 760, alignment: .leading)
                .background(Theme.bg)
        )
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        host.layoutSubtreeIfNeeded()
        // The screen loads its suites in a `.task`, which does not run in a
        // bare hosting view; a turn of the run loop lets the render settle.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("tests.png"))
    }
}
