import XCTest
@testable import Uncoil

// MARK: - Fakes

private final class FakeHandle: RunProcessHandle {
    let pid: Int32
    private(set) var running = true
    var isRunning: Bool { running }
    init(pid: Int32) { self.pid = pid }
    func terminate() { running = false }
    func forceKill() { running = false }
    private(set) var inputs: [Data] = []
    func sendInput(_ data: Data) { inputs.append(data) }
}

/// Scripted launcher: each launch pops the next behaviour.
@MainActor
private final class FakeLauncher: RunProcessLaunching {
    enum Behaviour {
        /// Emit these chunks, then stay alive.
        case emitAndStay([String])
        /// Emit chunks, then exit with the code.
        case emitAndExit([String], Int32)
        /// Fail to launch at all.
        case throwError
    }

    var script: [Behaviour] = []
    private(set) var launchedCommands: [String] = []
    private(set) var launchedCwds: [URL] = []
    var stops: [(FakeHandle, @MainActor (Int32) -> Void)] = []
    private var nextPid: Int32 = 1000

    struct LaunchFailed: Error {}

    func launch(
        command: String,
        cwd: URL,
        env: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> RunProcessHandle {
        launchedCommands.append(command)
        launchedCwds.append(cwd)
        let behaviour = script.isEmpty ? Behaviour.emitAndStay([]) : script.removeFirst()
        nextPid += 1
        let handle = FakeHandle(pid: nextPid)
        switch behaviour {
        case .throwError:
            throw LaunchFailed()
        case .emitAndStay(let chunks):
            Task { @MainActor in for chunk in chunks { onOutput(chunk) } }
        case .emitAndExit(let chunks, let code):
            Task { @MainActor in
                for chunk in chunks { onOutput(chunk) }
                onExit(code)
            }
        }
        stops.append((handle, onExit))
        return handle
    }
}

// MARK: - Tests

@MainActor
final class RunRegistryTests: XCTestCase {
    private var tempDir: URL!
    private var project: Project!
    private var registry: RunRegistry!
    private var launcher: FakeLauncher!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-runreg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("repo"), withIntermediateDirectories: true)
        project = Project(name: "repo", rootPath: tempDir.appendingPathComponent("repo").path)
        registry = RunRegistry()
        launcher = FakeLauncher()
        registry.launcher = launcher
        registry.dataDirectory = tempDir
        registry.reportFailure = nil
        registry.readinessTimeout = 2
        registry.survivalGrace = 0.2
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ configs: [RunConfiguration]) throws {
        try RunConfigFile.save(configs, projectRoot: project.rootURL)
    }

    func testStartBecomesReadyOnPatternMatch() async throws {
        try write([RunConfiguration(
            id: "dev", command: "fake dev", readyPattern: "listening"
        )])
        launcher.script = [.emitAndStay(["compiling…\n", "listening on 3000\n"])]
        let outcomes = await registry.start(project: project, configID: "dev")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].ok)
        let state = registry.state(project: project, configID: "dev")
        XCTAssertEqual(state.status, .running)
        XCTAssertNotNil(state.pid)
        XCTAssertTrue(state.logTail.contains("listening"))
        // The full log landed on disk too.
        let logText = try String(contentsOf: state.logFileURL!, encoding: .utf8)
        XCTAssertTrue(logText.contains("compiling"))
    }

    func testSurvivalGraceCountsAsRunningWithoutSignals() async throws {
        try write([RunConfiguration(id: "plain", command: "sleep 100")])
        launcher.script = [.emitAndStay([])]
        let outcomes = await registry.start(project: project, configID: "plain")
        XCTAssertTrue(outcomes[0].ok)
        XCTAssertEqual(registry.state(project: project, configID: "plain").status, .running)
    }

    func testEarlyExitProducesDiagnosis() async throws {
        try write([RunConfiguration(id: "bad", command: "nope", readyPattern: "never")])
        launcher.script = [.emitAndExit(["zsh: command not found: nope\n"], 127)]
        let outcomes = await registry.start(project: project, configID: "bad")
        XCTAssertFalse(outcomes[0].ok)
        XCTAssertEqual(outcomes[0].issue?.code, "command_not_found")
        XCTAssertEqual(registry.state(project: project, configID: "bad").status, .failed)
    }

    func testDependencyOrderAndFailurePropagation() async throws {
        try write([
            RunConfiguration(id: "api", command: "api", readyPattern: "up"),
            RunConfiguration(id: "web", command: "web", dependsOn: ["api"]),
        ])
        // api dies immediately → web must not be launched.
        launcher.script = [.emitAndExit(["boom\n"], 1)]
        let outcomes = await registry.start(project: project, configID: "web")
        XCTAssertEqual(launcher.launchedCommands, ["api"])
        XCTAssertEqual(outcomes.map(\.configID), ["api", "web"])
        XCTAssertFalse(outcomes[1].ok)
        XCTAssertEqual(outcomes[1].issue?.code, "dependency_failed")
    }

    func testDependencyOrderStartsPrerequisiteFirst() async throws {
        try write([
            RunConfiguration(id: "api", command: "api"),
            RunConfiguration(id: "web", command: "web", dependsOn: ["api"]),
        ])
        launcher.script = [.emitAndStay([]), .emitAndStay([])]
        let outcomes = await registry.start(project: project, configID: "web")
        XCTAssertEqual(launcher.launchedCommands, ["api", "web"])
        XCTAssertTrue(outcomes.allSatisfy(\.ok))
    }

    func testCycleIsRejected() async throws {
        try write([
            RunConfiguration(id: "a", command: "a", dependsOn: ["b"]),
            RunConfiguration(id: "b", command: "b", dependsOn: ["a"]),
        ])
        let outcomes = await registry.start(project: project, configID: "a")
        XCTAssertFalse(outcomes[0].ok)
        XCTAssertEqual(outcomes[0].issue?.code, "dependency_cycle")
        XCTAssertTrue(launcher.launchedCommands.isEmpty)
    }

    func testUnknownConfiguration() async {
        let outcomes = await registry.start(project: project, configID: "ghost")
        XCTAssertEqual(outcomes[0].issue?.code, "unknown_configuration")
    }

    func testInvalidCwd() async throws {
        try write([RunConfiguration(id: "x", command: "x", cwd: "does/not/exist")])
        let outcomes = await registry.start(project: project, configID: "x")
        XCTAssertEqual(outcomes[0].issue?.code, "invalid_cwd")
    }

    func testStopReturnsToIdle() async throws {
        try write([RunConfiguration(id: "dev", command: "dev")])
        launcher.script = [.emitAndStay([])]
        _ = await registry.start(project: project, configID: "dev")
        await registry.stop(project: project, configID: "dev")
        let state = registry.state(project: project, configID: "dev")
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.pid)
    }

    func testCrashWhileRunningIsDiagnosedAndReported() async throws {
        try write([RunConfiguration(id: "dev", command: "dev")])
        launcher.script = [.emitAndStay([])]
        var reportedIssue: RunIssue?
        registry.reportFailure = { _, _, issue in reportedIssue = issue }
        _ = await registry.start(project: project, configID: "dev")
        // Simulate the process dying after it was running.
        let (_, onExit) = launcher.stops[0]
        onExit(1)
        let state = registry.state(project: project, configID: "dev")
        XCTAssertEqual(state.status, .failed)
        XCTAssertNotNil(state.issue)
        XCTAssertNotNil(reportedIssue)
    }

    func testHistoryRecordsRunsAndSendInputReachesTheProcess() async throws {
        try write([RunConfiguration(id: "dev", command: "dev")])
        launcher.script = [.emitAndStay([])]
        _ = await registry.start(project: project, configID: "dev")
        XCTAssertTrue(registry.sendInput(project: project, configID: "dev", text: "r", raw: true))
        let (handle, onExit) = launcher.stops[0]
        XCTAssertEqual((handle as? FakeHandle)?.inputs, [Data("r".utf8)])
        onExit(0)
        let history = registry.history(project: project, configID: "dev")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].exitCode, 0)
        XCTAssertNotNil(history[0].endedAt)
        // Nothing running any more → input is refused.
        XCTAssertFalse(registry.sendInput(project: project, configID: "dev", text: "x"))
    }

    func testCleanExitAfterRunningIsNotAFailure() async throws {
        try write([RunConfiguration(id: "dev", command: "dev")])
        launcher.script = [.emitAndStay([])]
        _ = await registry.start(project: project, configID: "dev")
        let (_, onExit) = launcher.stops[0]
        onExit(0)
        XCTAssertEqual(registry.state(project: project, configID: "dev").status, .exited(0))
    }
}
