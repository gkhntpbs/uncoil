import XCTest
@testable import Uncoil

private final class FakeHandle: RunProcessHandle {
    let pid: Int32
    private(set) var running = true
    var isRunning: Bool { running }
    init(pid: Int32) { self.pid = pid }
    func stopRunning() { running = false }
    func terminate() { running = false }
    func forceKill() { running = false }
    func sendInput(_ data: Data) {}
}

/// Emits the scripted output, then exits with the scripted code.
@MainActor
private final class FakeLauncher: RunProcessLaunching {
    var output = ""
    var exitCode: Int32 = 0
    var shouldThrow = false
    private(set) var launchedCommands: [String] = []
    private(set) var launchedCwds: [URL] = []

    struct LaunchFailed: Error {}

    func launch(
        command: String,
        cwd: URL,
        env: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> RunProcessHandle {
        if shouldThrow { throw LaunchFailed() }
        launchedCommands.append(command)
        launchedCwds.append(cwd)
        let handle = FakeHandle(pid: 4242)
        let text = output
        let code = exitCode
        Task { @MainActor in
            onOutput(text)
            handle.stopRunning()
            onExit(code)
        }
        return handle
    }
}

@MainActor
final class TestRegistryTests: XCTestCase {
    private var tempDir: URL!
    private var project: Project!
    private var registry: TestRegistry!
    private var launcher: FakeLauncher!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-testreg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("repo"), withIntermediateDirectories: true
        )
        project = Project(name: "repo", rootPath: tempDir.appendingPathComponent("repo").path)
        registry = TestRegistry()
        launcher = FakeLauncher()
        registry.launcher = launcher
        registry.dataDirectory = tempDir
        registry.reportFailure = nil
        registry.clearFailure = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func suite(
        _ framework: TestFramework = .swift, id: String = "unit"
    ) -> TestSuiteConfiguration {
        TestSuiteConfiguration(id: id, command: "swift test", framework: framework)
    }

    func testAGreenRunIsRecordedWithItsCounts() async throws {
        launcher.output = """
        Test Case '-[Suite testOne]' passed (0.001 seconds).
        Test Case '-[Suite testTwo]' passed (0.002 seconds).
        """
        let result = await registry.run(project: project, suite: suite())
        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.summary.passed, 2)
        XCTAssertTrue(record.summary.didPass)
        XCTAssertEqual(registry.state(project: project, suiteID: "unit").latest, record)
        XCTAssertFalse(registry.state(project: project, suiteID: "unit").isRunning)
    }

    func testAFailingRunKeepsItsFailedCases() async throws {
        launcher.exitCode = 1
        launcher.output = """
        Test Case '-[Suite testOne]' passed (0.001 seconds).
        Test Case '-[Suite testTwo]' failed (0.002 seconds).
        """
        let result = await registry.run(project: project, suite: suite())
        let record = try XCTUnwrap(result)
        XCTAssertFalse(record.summary.didPass)
        XCTAssertEqual(record.failedCases.map(\.name), ["testTwo"])
    }

    /// The exit code arrives through a callback, not off the handle. If the
    /// wait gave up as soon as the process was gone, a failing suite would be
    /// recorded with no code at all — and so as a pass.
    func testTheExitCodeIsNotLostToTheRaceWithTheProcessEnding() async throws {
        launcher.exitCode = 74
        launcher.output = "output nobody parses"
        let result = await registry.run(project: project, suite: suite(.unknown))
        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.exitCode, 74)
        XCTAssertFalse(record.summary.didPass)
    }

    /// A suite of a thousand tests must have all of them parsed, not just what
    /// survived the capped tail shown on screen.
    func testEveryTestIsParsedEvenWhenTheOutputExceedsTheDisplayedTail() async throws {
        let lines = (0..<2000).map {
            "Test Case '-[Suite test\($0)]' passed (0.001 seconds)."
        }
        launcher.output = lines.joined(separator: "\n")
        let result = await registry.run(project: project, suite: suite())
        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.summary.passed, 2000)
    }

    func testTheResultSurvivesTheRegistry() async throws {
        launcher.output = "Test Case '-[Suite testOne]' passed (0.001 seconds)."
        _ = await registry.run(project: project, suite: suite())

        let fresh = TestRegistry()
        fresh.dataDirectory = tempDir
        try TestConfigFile.save([suite()], projectRoot: project.rootURL)
        fresh.loadPersistedResults(project: project)
        XCTAssertEqual(fresh.state(project: project, suiteID: "unit").latest?.summary.passed, 1)
    }

    func testALauncherFailureIsNotRecordedAsAResult() async {
        launcher.shouldThrow = true
        let record = await registry.run(project: project, suite: suite())
        XCTAssertNil(record)
        XCTAssertFalse(registry.state(project: project, suiteID: "unit").isRunning)
        XCTAssertNil(registry.state(project: project, suiteID: "unit").latest)
    }

    func testTheSuiteRunsInItsOwnWorkingDirectory() async throws {
        let subdirectory = project.rootURL.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        var nested = suite(.go)
        nested.cwd = "backend"
        _ = await registry.run(project: project, suite: nested)
        XCTAssertEqual(launcher.launchedCwds.first?.lastPathComponent, "backend")
    }

    /// A `cwd` that is not there means the command would run somewhere it was
    /// never meant to; refusing beats reporting a failure it did not have.
    func testAMissingWorkingDirectoryIsRefusedRatherThanRunAtTheRoot() async {
        var nested = suite()
        nested.cwd = "does-not-exist"
        let record = await registry.run(project: project, suite: nested)
        XCTAssertNil(record)
        XCTAssertTrue(launcher.launchedCommands.isEmpty)
    }

    /// The Attention Center row has to go away when the suite goes green, or a
    /// fixed failure keeps asking to be looked at.
    func testAFixedSuiteClearsItsAttentionRow() async {
        var reported = 0
        var cleared = 0
        registry.reportFailure = { _, _, _ in reported += 1 }
        registry.clearFailure = { _, _ in cleared += 1 }

        launcher.exitCode = 1
        launcher.output = "Test Case '-[Suite testOne]' failed (0.001 seconds)."
        _ = await registry.run(project: project, suite: suite())
        XCTAssertEqual(reported, 1)

        launcher.exitCode = 0
        launcher.output = "Test Case '-[Suite testOne]' passed (0.001 seconds)."
        _ = await registry.run(project: project, suite: suite())
        XCTAssertEqual(cleared, 1)
    }

    /// The id reaches the filesystem. One that could climb out of the results
    /// directory must not.
    func testASuiteIdCannotEscapeTheResultsDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/results")
        let url = TestRegistry.recordURL(suiteID: "../../etc/passwd", directory: directory)
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        XCTAssertFalse(url.path.contains(".."))
    }
}
