import XCTest
@testable import Uncoil

// MARK: - Preset decode / backward compatibility

final class SessionPresetTests: XCTestCase {
    func testBuiltInDefaults() {
        let ids = SessionPreset.builtInDefaults.map(\.id)
        XCTAssertEqual(ids, ["claude-worker", "codex-reviewer"])
        let worker = SessionPreset.builtInDefaults[0]
        XCTAssertEqual(worker.provider, .claude)
        XCTAssertTrue(worker.grantedCapabilities.contains("sessions.read"))
        XCTAssertTrue(worker.grantedCapabilities.contains("artifacts.read"))
    }

    /// settings.json written before presets existed (no `presets` key) still
    /// decodes, leaving presets nil.
    func testBackwardCompatibleDecodeWithoutPresets() throws {
        // Encode a current Persisted, strip the `presets` key, and decode: the
        // absence of the key must not break decoding.
        let encoded = try JSONEncoder().encode(SettingsStore.Persisted())
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "presets")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SettingsStore.Persisted.self, from: legacy)
        XCTAssertNil(decoded.presets)
    }

    func testPresetRoundtrip() throws {
        let preset = SessionPreset(
            id: "x", name: "X", provider: .codex,
            extraArguments: ["--model", "o1"], initialPromptTemplate: "hi",
            grantedCapabilities: ["sessions.read"], permissionMode: "standard")
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(SessionPreset.self, from: data)
        XCTAssertEqual(preset, back)
    }
}

// MARK: - Capability intersection (non-escalation)

final class ChildCapabilityTests: XCTestCase {
    func testIntersectionNeverEscalatesBeyondPresetOrCaller() {
        let preset = ["sessions.read", "artifacts.read", "browser.use"]
        let caller: Set<String> = ["sessions.read", "artifacts.read"]  // no browser.use
        // Requesting browser.use must be dropped (caller lacks it).
        let result = PolicyEngine.childCapabilities(
            requested: ["sessions.read", "browser.use"], preset: preset, callerGrants: caller)
        XCTAssertEqual(result, ["sessions.read"])
    }

    func testNilRequestedTakesPresetIntersectCaller() {
        let preset = ["sessions.read", "browser.use"]
        let caller: Set<String> = ["sessions.read", "artifacts.read"]
        let result = PolicyEngine.childCapabilities(requested: nil, preset: preset, callerGrants: caller)
        XCTAssertEqual(result, ["sessions.read"])
    }
}

// MARK: - Permission service

@MainActor
final class PermissionServiceTests: XCTestCase {
    private var dir: URL!
    private var service: PermissionService!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-perm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        service = PermissionService(dataDirectory: dir)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testGrantAndDirectionality() {
        let req = service.request(grantKey: "sessions.control", from: "A", target: "B")
        XCTAssertFalse(service.isGranted(from: "A", to: "B", key: "sessions.control"))
        service.grant(id: req.id)
        XCTAssertTrue(service.isGranted(from: "A", to: "B", key: "sessions.control"))
        // A→B granted must NOT authorize C→B.
        XCTAssertFalse(service.isGranted(from: "C", to: "B", key: "sessions.control"))
        // Nor a different key.
        XCTAssertFalse(service.isGranted(from: "A", to: "B", key: "sessions.close"))
    }

    func testRevoke() {
        let req = service.request(grantKey: "k", from: "A", target: "B")
        service.grant(id: req.id)
        XCTAssertTrue(service.isGranted(from: "A", to: "B", key: "k"))
        service.revoke(id: req.id)
        XCTAssertFalse(service.isGranted(from: "A", to: "B", key: "k"))
    }

    func testPendingExpiry() {
        // Write a permissions.json with an old pending request, then reload.
        let old = Date().addingTimeInterval(-(PermissionService.defaultPendingTTL + 60))
        let record = PermissionRequest(
            id: "e1", grantKey: "k", fromSessionID: "A", targetSessionID: "B",
            status: .pending, createdAt: old, decidedAt: nil, scope: nil)
        let data = try! JSONEncoder().encode([record])
        try! data.write(to: dir.appendingPathComponent("permissions.json"))
        let reloaded = PermissionService(dataDirectory: dir)
        XCTAssertTrue(reloaded.pending().isEmpty, "expired pending request should be pruned")
    }

    func testPersistenceRoundtrip() {
        let req = service.request(grantKey: "k", from: "A", target: "B")
        service.grant(id: req.id)
        let reloaded = PermissionService(dataDirectory: dir)
        XCTAssertTrue(reloaded.isGranted(from: "A", to: "B", key: "k"))
    }
}

// MARK: - Atomic file

final class AtomicFileTests: XCTestCase {
    func testWriteReplacesContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.json")
        XCTAssertTrue(AtomicFile.write(Data("first".utf8), to: url))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "first")
        XCTAssertTrue(AtomicFile.write(Data("second".utf8), to: url))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "second")
    }
}

// MARK: - Orchestration through the router

@MainActor
final class OrchestrationRouterTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectStore!
    private var sessionStore: SessionStore!
    private var settings: SettingsStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!
    private var launched: [SessionRecord] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-orch-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(directory: tempDir)
        sessionStore = SessionStore()
        settings = SettingsStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/orch-demo"))
        let project = store.projects[0]
        caller = store.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "claude: root")
        // Grant the caller create_children plus the default read set.
        store.updateSession(caller.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants) + ["sessions.read", "sessions.create_children"]
        }
        caller = store.sessions.first { $0.id == caller.id }
        router = CapabilityRouter(
            projectStore: store, sessionStore: sessionStore, settings: settings,
            audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir)
        router.permissions = PermissionService(dataDirectory: tempDir)
        launched = []
        router.childLauncher = { [weak self] record, _ in self?.launched.append(record) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func req(_ action: String, args: [String: JSONValue] = [:], caller c: SessionRecord? = nil) -> ControlRequest {
        ControlRequest(capability: "uncoil_sessions", action: action, args: args,
                       caller_session_id: (c ?? caller).id.uuidString)
    }

    func testCreateChildDeniedWithoutGrant() async {
        // A plain caller without the grant.
        let plain = store.createSession(projectID: store.projects[0].id, provider: .claude, accountID: nil, title: "claude: plain")
        store.updateSession(plain.id) {
            $0.capabilities = Array(
                PolicyEngine.defaultGrants.subtracting(["sessions.create_children"])
            )
        }
        let env = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")], caller: plain))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testCreateChildUnknownPreset() async {
        let env = await router.handle(req("create_child", args: ["preset_id": .string("nope")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    func testCreateChildSucceedsAndLaunches() async {
        let env = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")]))
        XCTAssertTrue(env.ok, "\(String(describing: env.error))")
        XCTAssertEqual(launched.count, 1)
        // Child exists with parentSessionID == caller.
        let child = store.sessions.first { $0.parentSessionID == caller.id }
        XCTAssertNotNil(child)
        // Capabilities are intersected with the caller's grants.
        XCTAssertEqual(Set(child!.capabilities ?? []), Set(SessionPreset.builtInDefaults[0].grantedCapabilities).intersection(PolicyEngine.grants(for: caller)))
    }

    func testCreateChildIdempotency() async {
        let args: [String: JSONValue] = ["preset_id": .string("claude-worker"), "idempotency_key": .string("k1")]
        let first = await router.handle(req("create_child", args: args))
        let second = await router.handle(req("create_child", args: args))
        XCTAssertTrue(first.ok && second.ok)
        XCTAssertEqual(first.target_session_id, second.target_session_id)
        XCTAssertEqual(launched.count, 1, "idempotent call must not launch a second child")
        XCTAssertEqual(store.sessions.filter { $0.parentSessionID == caller.id }.count, 1)
    }

    func testCreateChildCapabilitySubsetNonEscalation() async {
        // Request computer.inspect which neither the caller nor the preset grants.
        let env = await router.handle(req("create_child", args: [
            "preset_id": .string("claude-worker"),
            "capabilities": .array([.string("computer.inspect"), .string("sessions.read")]),
        ]))
        XCTAssertTrue(env.ok)
        let child = store.sessions.first { $0.parentSessionID == caller.id }!
        XCTAssertFalse((child.capabilities ?? []).contains("computer.inspect"))
        XCTAssertTrue((child.capabilities ?? []).contains("sessions.read"))
    }

    func testWaitForChildrenSuccess() async {
        _ = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")]))
        let child = store.sessions.first { $0.parentSessionID == caller.id }!
        sessionStore.setStatus(.completed, for: child.id)
        let env = await router.handle(req("wait_for_children", args: ["timeout_s": .int(2)]))
        XCTAssertTrue(env.ok)
    }

    func testWaitForChildrenTimeout() async {
        _ = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")]))
        let child = store.sessions.first { $0.parentSessionID == caller.id }!
        sessionStore.setStatus(.running, for: child.id)  // never settles
        let env = await router.handle(req("wait_for_children", args: ["timeout_s": .int(1)]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "TIMEOUT")
        if case let .object(details)? = env.error?.details, case let .array(pending)? = details["pending"] {
            XCTAssertEqual(pending.count, 1)
        } else { XCTFail("expected pending list") }
    }

    func testReportToParentAndReadReportsRoundtrip() async {
        _ = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")]))
        let child = store.sessions.first { $0.parentSessionID == caller.id }!
        let report = await router.handle(ControlRequest(
            capability: "uncoil_sessions", action: "report_to_parent",
            args: ["message": .string("done"), "data": .object(["k": .int(1)])],
            caller_session_id: child.id.uuidString))
        XCTAssertTrue(report.ok, "\(String(describing: report.error))")
        // Parent sees pending_reports via inspect.
        let inspect = await router.handle(req("inspect"))
        if case let .object(data)? = inspect.data {
            XCTAssertEqual(data["pending_reports"], .int(1))
        } else { XCTFail("no inspect data") }
        // Parent reads and clears.
        let read = await router.handle(req("read_reports", args: ["clear": .bool(true)]))
        XCTAssertTrue(read.ok)
        if case let .object(data)? = read.data, case let .array(reports)? = data["reports"] {
            XCTAssertEqual(reports.count, 1)
        } else { XCTFail("no reports") }
        let readAgain = await router.handle(req("read_reports"))
        if case let .object(data)? = readAgain.data {
            XCTAssertEqual(data["count"], .int(0))
        } else { XCTFail("no data") }
    }

    func testReportToParentSizeLimit() async {
        _ = await router.handle(req("create_child", args: ["preset_id": .string("claude-worker")]))
        let child = store.sessions.first { $0.parentSessionID == caller.id }!
        let huge = String(repeating: "x", count: 9000)
        let env = await router.handle(ControlRequest(
            capability: "uncoil_sessions", action: "report_to_parent",
            args: ["message": .string(huge)], caller_session_id: child.id.uuidString))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    func testListPresetsReturnsBuiltIns() async {
        let env = await router.handle(ControlRequest(
            capability: "uncoil_projects", action: "list_presets",
            caller_session_id: caller.id.uuidString))
        XCTAssertTrue(env.ok)
        if case let .object(data)? = env.data, case let .array(presets)? = data["presets"] {
            XCTAssertEqual(presets.count, 2)
        } else { XCTFail("no presets") }
    }

    // Permission flow: controlling an unrelated session returns PERMISSION_REQUIRED,
    // then a granted directional permission lets it through.
    func testControlUnrelatedRequiresThenGrantsPermission() async {
        // A sibling-less unrelated session in the same project, controllable
        // only via a permission. Give caller control_children so the denial is
        // relationship-based (permissionDenied), not capability-based.
        store.updateSession(caller.id) {
            $0.capabilities = Array(
                PolicyEngine.defaultGrants.subtracting(["sessions.control_all"])
            ) + ["sessions.control_children"]
        }
        caller = store.sessions.first { $0.id == caller.id }
        let other = store.createSession(projectID: store.projects[0].id, provider: .claude, accountID: nil, title: "claude: other")
        let denied = await router.handle(req("send_text", args: [
            "session_id": .string(other.id.uuidString), "text": .string("hi")]))
        XCTAssertEqual(denied.error?.code, "PERMISSION_REQUIRED")
        // Grant A→other for sessions.control and retry.
        let request = router.permissions!.request(grantKey: "sessions.control", from: caller.id.uuidString, target: other.id.uuidString)
        router.permissions!.grant(id: request.id)
        let allowed = await router.handle(req("send_text", args: [
            "session_id": .string(other.id.uuidString), "text": .string("hi")]))
        XCTAssertTrue(allowed.ok, "\(String(describing: allowed.error))")
    }
}
