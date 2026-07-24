import XCTest
@testable import Uncoil

// MARK: - Fakes

/// Engine-independent fake browser: records commands, serves a canned snapshot
/// with ref `@e1`, and rejects unknown refs with a stale-element error.
final class FakeBrowserEngine: BrowserEngine, @unchecked Sendable {
    var installed = true
    var knownRefs: Set<String> = ["@e1"]
    private(set) var commands: [String] = []
    private let lock = NSLock()

    func record(_ s: String) { lock.lock(); commands.append(s); lock.unlock() }

    func probe() -> DependencyInfo {
        DependencyInfo(name: "agent-browser", installed: installed,
                       path: installed ? "/fake/agent-browser" : nil, version: "test",
                       detail: nil, remedy: installed ? nil : "npm install -g agent-browser")
    }

    func perform(_ command: BrowserCommand, session: String, profileDir: String?)
        -> Result<EngineResult, EngineError> {
        switch command {
        case .start: record("start"); return .success(EngineResult(data: .object(["started": .bool(true)])))
        case .stop: record("stop:\(session)"); return .success(EngineResult())
        case .open(let url): record("open:\(url)"); return .success(EngineResult())
        case .navigate(let url): record("navigate:\(url)"); return .success(EngineResult())
        case .snapshot:
            record("snapshot")
            return .success(EngineResult(externalContent: .object([
                "tree": .array([.object(["ref": .string("@e1"), "role": .string("button")])]),
            ])))
        case .click(let ref):
            record("click:\(ref)")
            if knownRefs.contains(ref) { return .success(EngineResult(data: .object(["clicked": .bool(true)]))) }
            return .failure(EngineError(.staleElementReference, "no element for \(ref)",
                                        remedy: "take a fresh snapshot"))
        case .screenshot(let path, _):
            record("screenshot")
            try? Data("PNG".utf8).write(to: URL(fileURLWithPath: path))
            return .success(EngineResult(artifactFiles: [path]))
        case .saveState(let path):
            record("saveState")
            try? Data("{}".utf8).write(to: URL(fileURLWithPath: path))
            return .success(EngineResult(artifactFiles: [path]))
        case .clearState: record("clearState:\(session)"); return .success(EngineResult())
        default: record("other"); return .success(EngineResult())
        }
    }
}

/// Engine-independent fake computer: binds windows whose pid is the current
/// process (so liveness passes), echoes commands.
final class FakeComputerEngine: ComputerEngine, @unchecked Sendable {
    var installed = true
    private(set) var commands: [String] = []
    private let lock = NSLock()
    func record(_ s: String) { lock.lock(); commands.append(s); lock.unlock() }

    func probe() -> DependencyInfo {
        DependencyInfo(name: "cua-driver", installed: installed,
                       path: installed ? "/fake/cua-driver" : nil, version: "test",
                       detail: installed ? "permissions: ok" : nil,
                       remedy: installed ? nil : "install cua-driver")
    }

    func perform(_ command: ComputerCommand, session: String) -> Result<EngineResult, EngineError> {
        switch command {
        case .inspectWindow(let bundleID, let windowID):
            record("inspect:\(bundleID)")
            return .success(EngineResult(externalContent: .object([
                "window": .object([
                    "bundle_id": .string(bundleID),
                    "pid": .int(Int(getpid())),
                    "window_id": .int(windowID ?? 42),
                    "title": .string("Fake Window"),
                ]),
            ])))
        case .snapshot: record("snapshot"); return .success(EngineResult(externalContent: .object(["ax": .string("tree")])))
        case .click: record("click"); return .success(EngineResult(data: .object(["clicked": .bool(true)])))
        case .type: record("type"); return .success(EngineResult())
        case .bringToFront: record("front"); return .success(EngineResult())
        case .listApps: record("listApps"); return .success(EngineResult(externalContent: .array([])))
        default: record("other"); return .success(EngineResult())
        }
    }
}

// MARK: - Identity

final class ControlIdentityTests: XCTestCase {
    func testDeterministic() {
        let p = UUID(); let s = UUID()
        XCTAssertEqual(ControlIdentity.derive(projectID: p, sessionID: s),
                       ControlIdentity.derive(projectID: p, sessionID: s))
    }
    func testShape() {
        let p = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let s = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        XCTAssertEqual(ControlIdentity.derive(projectID: p, sessionID: s), "uncoil-abcdef12-12345678")
    }
    func testSanitizeStripsIllegal() {
        XCTAssertEqual(ControlIdentity.sanitize("AB_c!12"), "ab-c-12")
    }
}

// MARK: - ProcessRunner

final class ProcessRunnerTests: XCTestCase {
    func testEnvScrub() {
        setenv("UNCOIL_SECRET_TEST", "leak-me", 1)
        defer { unsetenv("UNCOIL_SECRET_TEST") }
        // `env` prints the child environment; the secret must be absent.
        let result = ProcessRunner.run(executable: "/usr/bin/env", arguments: [], timeout: 10)
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.stdoutString.contains("UNCOIL_SECRET_TEST"))
        XCTAssertTrue(result.stdoutString.contains("PATH="))
    }

    func testArgvNoShellInterpolation() {
        // If argv were shell-interpreted, `$(...)` would expand. It must not.
        let result = ProcessRunner.run(executable: "/bin/echo", arguments: ["$(whoami)"], timeout: 10)
        XCTAssertEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "$(whoami)")
    }

    func testNulArgumentRejected() {
        let result = ProcessRunner.run(executable: "/bin/echo", arguments: ["a\0b"], timeout: 5)
        XCTAssertFalse(result.launched)
    }

    func testTimeout() {
        let result = ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 1)
        XCTAssertTrue(result.timedOut)
    }
}

// MARK: - Domain policy (pure)

final class BrowserDomainPolicyTests: XCTestCase {
    func testSuffixMatch() {
        XCTAssertTrue(CapabilityRouter.hostMatches("app.example.com", "example.com"))
        XCTAssertTrue(CapabilityRouter.hostMatches("example.com", "example.com"))
        XCTAssertFalse(CapabilityRouter.hostMatches("notexample.com", "example.com"))
        XCTAssertFalse(CapabilityRouter.hostMatches("example.com.evil.com", "example.com"))
    }
    func testHostComponent() {
        XCTAssertEqual(CapabilityRouter.hostComponent("https://Foo.com/path"), "foo.com")
        XCTAssertEqual(CapabilityRouter.hostComponent("bare.host.dev"), "bare.host.dev")
    }
}

// MARK: - Browser handler contract

@MainActor
final class BrowserHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!
    private var fake: FakeBrowserEngine!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-br-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/br-demo"))
        let project = store.projects[0]
        caller = store.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "c")
        router = CapabilityRouter(projectStore: store, sessionStore: SessionStore(),
                                  audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir)
        fake = FakeBrowserEngine()
        router.browserEngine = fake
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func grant(_ caps: [String]) {
        store.updateSession(caller.id) { $0.capabilities = Array(PolicyEngine.defaultGrants) + caps }
        caller = store.sessions.first { $0.id == caller.id }
    }
    private func req(_ action: String, _ args: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(capability: "uncoil_browser", action: action, args: args,
                       caller_session_id: caller.id.uuidString)
    }

    func testDisabledWithoutGrant() async {
        store.updateSession(caller.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants.subtracting(["browser.use"]))
        }
        caller = store.sessions.first { $0.id == caller.id }
        let env = await router.handle(req("status"))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testUnavailableWhenNotInstalled() async {
        grant(["browser.use"]); fake.installed = false
        let env = await router.handle(req("open", ["url": .string("https://example.com")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "BROWSER_UNAVAILABLE")
    }

    func testStartSnapshotClickFlow() async {
        grant(["browser.use"])
        _ = await router.handle(req("start"))
        let snap = await router.handle(req("snapshot"))
        XCTAssertTrue(snap.ok)
        // Snapshot content is wrapped under the trust boundary.
        if case .object(let d)? = snap.data, case .object(let ext)? = d["external_content"] {
            XCTAssertEqual(ext["note"]?.stringValue, TrustBoundary.externalContentNote)
        } else { XCTFail("no wrapped external_content") }
        let click = await router.handle(req("click", ["ref": .string("@e1")]))
        XCTAssertTrue(click.ok)
    }

    func testStaleRefMapping() async {
        grant(["browser.use"])
        let env = await router.handle(req("click", ["ref": .string("@e999")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "STALE_ELEMENT_REFERENCE")
    }

    func testDomainBlockedDenied() async {
        grant(["browser.use"])
        _ = await router.handle(req("start", ["blocked_domains": .array([.string("evil.com")])]))
        let env = await router.handle(req("navigate", ["url": .string("https://sub.evil.com/x")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "PERMISSION_DENIED")
        XCTAssertFalse(fake.commands.contains("navigate:https://sub.evil.com/x"))
    }

    func testDomainAllowedPasses() async {
        grant(["browser.use"])
        _ = await router.handle(req("start", ["allowed_domains": .array([.string("example.com")])]))
        let ok = await router.handle(req("open", ["url": .string("https://example.com/a")]))
        XCTAssertTrue(ok.ok)
        let denied = await router.handle(req("open", ["url": .string("https://other.com/a")]))
        XCTAssertEqual(denied.error?.code, "PERMISSION_DENIED")
    }

    func testScreenshotArtifactRouting() async {
        grant(["browser.use"])
        let env = await router.handle(req("screenshot"))
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.artifacts.count, 1)
        let root = caller.artifactRoot(dataDirectory: tempDir).path
        if case .object(let a)? = env.artifacts.first, case .string(let path)? = a["path"] {
            XCTAssertTrue(path.hasPrefix(root), "artifact not under session root: \(path)")
            XCTAssertTrue(path.contains("/browser/screenshots/"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        } else { XCTFail("no artifact path") }
    }

    func testClearStateIsolation() async {
        grant(["browser.use", "browser.persistent_state"])
        // Second session in the same project.
        let other = store.createSession(projectID: store.projects[0].id, provider: .claude,
                                        accountID: nil, title: "other")
        store.updateSession(other.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants) + ["browser.use", "browser.persistent_state"]
        }
        // Both save state (writes an artifact under each session's states dir).
        _ = await router.handle(req("save_state"))
        let otherReq = ControlRequest(capability: "uncoil_browser", action: "save_state",
                                      caller_session_id: other.id.uuidString)
        _ = await router.handle(otherReq)

        let otherStates = other.artifactRoot(dataDirectory: tempDir)
            .appendingPathComponent("browser/states")
        let otherFilesBefore = (try? FileManager.default.contentsOfDirectory(atPath: otherStates.path))?.count ?? 0
        XCTAssertGreaterThan(otherFilesBefore, 0)

        // Caller clears — the other session's state files must remain.
        _ = await router.handle(req("clear_state"))
        let callerStates = caller.artifactRoot(dataDirectory: tempDir).appendingPathComponent("browser/states")
        XCTAssertFalse(FileManager.default.fileExists(atPath: callerStates.path))
        let otherFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: otherStates.path))?.count ?? 0
        XCTAssertEqual(otherFilesAfter, otherFilesBefore)
        // Engine clearState only ever saw the caller's derived id.
        let callerID = ControlIdentity.derive(projectID: caller.projectID, sessionID: caller.id)
        XCTAssertTrue(fake.commands.contains("clearState:\(callerID)"))
    }
}

// MARK: - Computer handler contract

@MainActor
final class ComputerHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!
    private var fake: FakeComputerEngine!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-co-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/co-demo"))
        caller = store.createSession(projectID: store.projects[0].id, provider: .claude,
                                     accountID: nil, title: "c")
        router = CapabilityRouter(projectStore: store, sessionStore: SessionStore(),
                                  audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir)
        fake = FakeComputerEngine()
        router.computerEngine = fake
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func grant(_ caps: [String]) {
        store.updateSession(caller.id) { $0.capabilities = Array(PolicyEngine.defaultGrants) + caps }
        caller = store.sessions.first { $0.id == caller.id }
    }
    private func req(_ action: String, _ args: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(capability: "uncoil_computer", action: action, args: args,
                       caller_session_id: caller.id.uuidString)
    }

    func testInspectRequiresGrant() async {
        let env = await router.handle(req("list_apps"))
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testBackgroundGrantGating() async {
        grant(["computer.inspect"])  // inspect only, no background
        _ = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        let env = await router.handle(req("click", ["x": .int(10), "y": .int(20)]))
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testForegroundGrantGating() async {
        grant(["computer.inspect", "computer.background_control"])
        _ = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        let env = await router.handle(req("bring_to_front"))
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testBindingLifecycleAndClick() async {
        grant(["computer.inspect", "computer.background_control"])
        let inspect = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        XCTAssertTrue(inspect.ok)
        XCTAssertNotNil(router.computerBindings[caller.id])
        let click = await router.handle(req("click", ["x": .int(5), "y": .int(6)]))
        XCTAssertTrue(click.ok)
    }

    func testMutatingWithoutBindingIsStale() async {
        grant(["computer.background_control"])
        let env = await router.handle(req("click", ["x": .int(1), "y": .int(2)]))
        XCTAssertEqual(env.error?.code, "STALE_WINDOW_BINDING")
    }

    func testStaleBindingWhenProcessGone() async {
        grant(["computer.inspect", "computer.background_control"])
        _ = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        // Simulate the window's process dying by pointing at an unused pid.
        var binding = router.computerBindings[caller.id]!
        binding.target.pid = 2_000_000_000  // not a live pid
        router.computerBindings[caller.id] = binding
        let env = await router.handle(req("type", ["text": .string("hi")]))
        XCTAssertEqual(env.error?.code, "STALE_WINDOW_BINDING")
    }

    func testForegroundWarns() async {
        grant(["computer.inspect", "computer.background_control", "computer.foreground_control"])
        _ = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        let env = await router.handle(req("bring_to_front"))
        XCTAssertTrue(env.ok)
        XCTAssertFalse(env.warnings.isEmpty)
    }

    func testUnavailableWhenNotInstalled() async {
        grant(["computer.inspect"]); fake.installed = false
        let env = await router.handle(req("list_apps"))
        XCTAssertEqual(env.error?.code, "COMPUTER_UNAVAILABLE")
    }

    func testExternalContentWrapped() async {
        grant(["computer.inspect", "computer.background_control"])
        _ = await router.handle(req("inspect_window", ["bundle_id": .string("com.apple.Finder")]))
        let snap = await router.handle(req("snapshot"))
        XCTAssertTrue(snap.ok)
        if case .object(let d)? = snap.data, case .object(let ext)? = d["external_content"] {
            XCTAssertEqual(ext["note"]?.stringValue, TrustBoundary.externalContentNote)
        } else { XCTFail("expected wrapped external_content") }
    }
}
