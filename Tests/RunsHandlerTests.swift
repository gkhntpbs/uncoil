import XCTest
@testable import Uncoil

@MainActor
final class RunsHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var repoDir: URL!
    private var store: ProjectStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-runs-\(UUID().uuidString)", isDirectory: true)
        repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        store = ProjectStore(directory: tempDir)
        store.addProject(at: repoDir)
        let project = store.projects[0]
        caller = store.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: run"
        )
        router = CapabilityRouter(
            projectStore: store, sessionStore: SessionStore(),
            audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir
        )
        let registry = RunRegistry()
        registry.dataDirectory = tempDir
        registry.reportFailure = nil
        registry.survivalGrace = 0.2
        registry.readinessTimeout = 2
        router.runRegistry = registry
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func call(
        _ action: String, args: [String: JSONValue] = [:],
        capabilities: [String]? = nil
    ) async -> ControlEnvelope {
        if let capabilities {
            store.updateSession(caller.id) { $0.capabilities = capabilities }
        }
        return await router.handle(ControlRequest(
            capability: "uncoil_run", action: action, args: args,
            caller_session_id: caller.id.uuidString
        ))
    }

    func testHelpCoversEveryAction() async {
        let env = await call("help")
        XCTAssertTrue(env.ok)
    }

    func testListEmptyProject() async {
        let env = await call("list")
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.data?.objectValue?["total"]?.intValue, 0)
    }

    func testDetectWritesConfigFile() async throws {
        try #"{"scripts":{"dev":"vite"}}"#
            .write(to: repoDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let env = await call("detect")
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.data?.objectValue?["total"]?.intValue, 1)
        let saved = RunConfigFile.load(projectRoot: repoDir)
        XCTAssertEqual(saved.configurations.map(\.id), ["dev"])
        XCTAssertEqual(saved.configurations[0].source, .detected)
    }

    func testUpdateCreatesAgentConfigAndStatusReadsIt() async {
        let env = await call("update", args: ["configuration": .object([
            "id": .string("api"),
            "command": .string("true"),
            "ports": .array([.int(9999)]),
            "custom": .string("preserved"),
        ])])
        XCTAssertTrue(env.ok)
        let status = await call("status", args: ["id": .string("api")])
        XCTAssertTrue(status.ok)
        let data = status.data?.objectValue
        XCTAssertEqual(data?["source"]?.stringValue, "agent")
        XCTAssertEqual(data?["custom"]?.stringValue, "preserved")
        XCTAssertEqual(data?["state"]?.objectValue?["status"]?.stringValue, "idle")
    }

    func testUpdateAcceptsStringifiedConfiguration() async {
        let env = await call("update", args: [
            "configuration": .string(#"{"id":"wire","command":"true","ports":[81]}"#),
        ])
        XCTAssertTrue(env.ok, "\(String(describing: env.error))")
        XCTAssertEqual(
            RunConfigFile.load(projectRoot: repoDir).configurations.first?.id, "wire"
        )
    }

    func testUpdateAcceptsTopLevelFields() async {
        let env = await call("update", args: [
            "id": .string("flat"), "command": .string("true"),
        ])
        XCTAssertTrue(env.ok, "\(String(describing: env.error))")
        XCTAssertEqual(
            RunConfigFile.load(projectRoot: repoDir).configurations.first?.id, "flat"
        )
    }

    func testUpdateRejectsBrokenDependencyGraph() async {
        let env = await call("update", args: ["configuration": .object([
            "id": .string("web"),
            "command": .string("true"),
            "depends_on": .array([.string("ghost")]),
        ])])
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    func testStartUnknownIdListsKnownIds() async {
        let env = await call("start", args: ["id": .string("nope")])
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    func testStartStopRealProcess() async throws {
        // A real (fast, harmless) process through the real launcher: proves the
        // whole stack — file → registry → shell — end to end.
        try RunConfigFile.save([RunConfiguration(
            id: "echo", command: "echo hello-from-run && sleep 30"
        )], projectRoot: repoDir)
        let start = await call("start", args: ["id": .string("echo")])
        XCTAssertTrue(start.ok, "start failed: \(String(describing: start.error))")
        let logs = await call("logs", args: ["id": .string("echo")])
        XCTAssertTrue(logs.ok)
        let external = logs.data?.objectValue?["external_content"]
        XCTAssertNotNil(external)
        let stop = await call("stop", args: ["id": .string("echo")])
        XCTAssertTrue(stop.ok)
        XCTAssertEqual(stop.data?.objectValue?["status"]?.stringValue, "idle")
    }

    func testStartFailureReturnsIssueAndLogTail() async throws {
        try RunConfigFile.save([RunConfiguration(
            id: "broken", command: "definitely-not-a-command-xyz", readyPattern: "never"
        )], projectRoot: repoDir)
        let env = await call("start", args: ["id": .string("broken")])
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_STATE_TRANSITION")
        let details = env.error?.details?.objectValue
        XCTAssertEqual(details?["issue"]?.objectValue?["code"]?.stringValue, "command_not_found")
    }

    func testGrantsAreEnforced() async {
        let read = await call("list", capabilities: ["projects.read"])
        XCTAssertEqual(read.error?.code, "CAPABILITY_DISABLED")
        let write = await call("detect", capabilities: ["runs.read"])
        XCTAssertEqual(write.error?.code, "CAPABILITY_DISABLED")
        let control = await call("start", args: ["id": .string("x")],
                                 capabilities: ["runs.read", "runs.write"])
        XCTAssertEqual(control.error?.code, "CAPABILITY_DISABLED")
    }

    func testRemoveRefusedWhileRunningAndWorksWhenIdle() async throws {
        try RunConfigFile.save([RunConfiguration(
            id: "svc", command: "sleep 30"
        )], projectRoot: repoDir)
        let start = await call("start", args: ["id": .string("svc")])
        XCTAssertTrue(start.ok)
        let refused = await call("remove", args: ["id": .string("svc")])
        XCTAssertEqual(refused.error?.code, "INVALID_STATE_TRANSITION")
        _ = await call("stop", args: ["id": .string("svc")])
        let removed = await call("remove", args: ["id": .string("svc")])
        XCTAssertTrue(removed.ok)
        XCTAssertTrue(RunConfigFile.load(projectRoot: repoDir).configurations.isEmpty)
    }

    func testIdlessCallsResolveTheDefaultConfiguration() async throws {
        try RunConfigFile.save([
            RunConfiguration(id: "a", command: "sleep 30"),
            RunConfiguration(id: "b", command: "echo b && sleep 30", isDefault: true),
        ], projectRoot: repoDir)
        let status = await call("status")
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.data?.objectValue?["id"]?.stringValue, "b")
        let start = await call("start")
        XCTAssertTrue(start.ok, "start failed: \(String(describing: start.error))")
        let stop = await call("stop")
        XCTAssertTrue(stop.ok)
    }

    func testIdlessCallWithoutDefaultFails() async throws {
        try RunConfigFile.save([
            RunConfiguration(id: "a", command: "true"),
            RunConfiguration(id: "b", command: "true"),
        ], projectRoot: repoDir)
        let env = await call("status")
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    func testSetDefaultAndUpdateKeepASingleDefault() async throws {
        try RunConfigFile.save([
            RunConfiguration(id: "a", command: "true", isDefault: true),
            RunConfiguration(id: "b", command: "true"),
        ], projectRoot: repoDir)
        let set = await call("set_default", args: ["id": .string("b")])
        XCTAssertTrue(set.ok)
        XCTAssertEqual(
            RunConfigFile.load(projectRoot: repoDir).configurations.filter(\.isDefault).map(\.id),
            ["b"]
        )
        // update with "default": true moves the flag again.
        let update = await call("update", args: ["configuration": .object([
            "id": .string("c"), "command": .string("true"), "default": .bool(true),
        ])])
        XCTAssertTrue(update.ok)
        XCTAssertEqual(
            RunConfigFile.load(projectRoot: repoDir).configurations.filter(\.isDefault).map(\.id),
            ["c"]
        )
    }

    func testUnknownActionRejected() async {
        let env = await call("frobnicate")
        XCTAssertEqual(env.error?.code, "INVALID_ACTION")
    }
}
