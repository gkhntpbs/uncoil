import XCTest
@testable import Uncoil

// MARK: - Protocol encoding

final class ControlProtocolTests: XCTestCase {
    func testSuccessEnvelopeRoundtrip() throws {
        let request = ControlRequest(capability: "uncoil_system", action: "version",
                                     caller_session_id: "abc", request_id: "req-1")
        let envelope = ControlEnvelope.success(request, data: .object(["app_version": .string("0.1.0")]))
        let line = try XCTUnwrap(Data.controlLine(envelope))
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let decoded = try JSONDecoder().decode(ControlEnvelope.self, from: line.dropLast())
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.request_id, "req-1")
    }

    func testErrorEnvelopeRoundtrip() throws {
        let request = ControlRequest(capability: "uncoil_sessions", action: "stop", request_id: "req-2")
        let envelope = ControlEnvelope.failure(request, code: .permissionDenied,
            message: "nope", retryable: false, target_session_id: "t1")
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ControlEnvelope.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "PERMISSION_DENIED")
        XCTAssertEqual(decoded.target_session_id, "t1")
        XCTAssertEqual(decoded, envelope)
    }

    func testJSONValueRoundtrip() throws {
        let value: JSONValue = .object([
            "a": .int(1), "b": .string("x"), "c": .bool(true),
            "d": .array([.double(1.5), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    /// Error-code strings are a stable public contract.
    func testErrorCodeStability() {
        XCTAssertEqual(ControlErrorCode.unknownProject.rawValue, "UNKNOWN_PROJECT")
        XCTAssertEqual(ControlErrorCode.unknownSession.rawValue, "UNKNOWN_SESSION")
        XCTAssertEqual(ControlErrorCode.sessionNotRunning.rawValue, "SESSION_NOT_RUNNING")
        XCTAssertEqual(ControlErrorCode.capabilityDisabled.rawValue, "CAPABILITY_DISABLED")
        XCTAssertEqual(ControlErrorCode.permissionRequired.rawValue, "PERMISSION_REQUIRED")
        XCTAssertEqual(ControlErrorCode.permissionDenied.rawValue, "PERMISSION_DENIED")
        XCTAssertEqual(ControlErrorCode.invalidRelationship.rawValue, "INVALID_RELATIONSHIP")
        XCTAssertEqual(ControlErrorCode.invalidPath.rawValue, "INVALID_PATH")
        XCTAssertEqual(ControlErrorCode.timeout.rawValue, "TIMEOUT")
        XCTAssertEqual(ControlErrorCode.invalidAction.rawValue, "INVALID_ACTION")
        XCTAssertEqual(ControlErrorCode.controlPlaneUnavailable.rawValue, "CONTROL_PLANE_UNAVAILABLE")
        XCTAssertEqual(ControlErrorCode.invalidArgument.rawValue, "INVALID_ARGUMENT")
        // Every code must have a non-empty, upper-snake-case raw value.
        for code in ControlErrorCode.allCases {
            XCTAssertFalse(code.rawValue.isEmpty)
            XCTAssertEqual(code.rawValue, code.rawValue.uppercased())
        }
    }
}

// MARK: - Relationship calculator

final class RelationshipTests: XCTestCase {
    private func record(parent: UUID? = nil, project: UUID) -> SessionRecord {
        var r = SessionRecord(projectID: project, provider: .claude, accountID: nil, title: "t")
        r.parentSessionID = parent
        return r
    }

    func testAllSevenRelations() {
        let project = UUID()
        let root = record(project: project)
        let child = record(parent: root.id, project: project)
        let grandchild = record(parent: child.id, project: project)
        let sibling = record(parent: root.id, project: project)
        let stranger = record(project: UUID())
        let all = Dictionary(uniqueKeysWithValues:
            [root, child, grandchild, sibling, stranger].map { ($0.id, $0) })

        func rel(_ target: SessionRecord, _ caller: SessionRecord) -> SessionRelation {
            PolicyEngine.relation(of: target, to: caller, in: all)
        }
        XCTAssertEqual(rel(root, root), .current)
        XCTAssertEqual(rel(child, root), .child)
        XCTAssertEqual(rel(root, child), .parent)
        XCTAssertEqual(rel(grandchild, root), .descendant)
        XCTAssertEqual(rel(root, grandchild), .ancestor)
        XCTAssertEqual(rel(sibling, child), .sibling)
        XCTAssertEqual(rel(stranger, root), .unrelated)
    }

    func testAncestryGuardsCycles() {
        let project = UUID()
        var a = SessionRecord(projectID: project, provider: .claude, accountID: nil, title: "a")
        var b = SessionRecord(projectID: project, provider: .claude, accountID: nil, title: "b")
        a.parentSessionID = b.id
        b.parentSessionID = a.id  // cycle
        let all = [a.id: a, b.id: b]
        // Must terminate and not include self.
        XCTAssertEqual(PolicyEngine.ancestors(of: a, in: all), [b.id])
    }
}

// MARK: - Policy decisions

final class PolicyDecisionTests: XCTestCase {
    private func rec(parent: UUID? = nil, project: UUID, caps: [String]? = nil) -> SessionRecord {
        var r = SessionRecord(projectID: project, provider: .claude, accountID: nil, title: "t")
        r.parentSessionID = parent
        r.capabilities = caps
        return r
    }

    func testSelfInspectAllowed() {
        let p = UUID(); let caller = rec(project: p)
        let all = [caller.id: caller]
        let decision = PolicyEngine.canRead(
            target: caller, caller: caller,
            relation: PolicyEngine.relation(of: caller, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertTrue(decision.allowed)
    }

    func testChildControlAllowedWithGrant() {
        let p = UUID()
        let caller = rec(project: p, caps: Array(PolicyEngine.defaultGrants) + ["sessions.control_children"])
        let child = rec(parent: caller.id, project: p)
        let all = [caller.id: caller, child.id: child]
        let decision = PolicyEngine.canControl(
            relation: PolicyEngine.relation(of: child, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertTrue(decision.allowed)
    }

    func testSiblingControlDenied() {
        let p = UUID(); let root = rec(project: p)
        let caller = rec(parent: root.id, project: p, caps: ["sessions.control_children"])
        let sibling = rec(parent: root.id, project: p)
        let all = [root.id: root, caller.id: caller, sibling.id: sibling]
        let decision = PolicyEngine.canControl(
            relation: PolicyEngine.relation(of: sibling, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.code, .permissionDenied)
    }

    func testCrossProjectReadDenied() {
        let caller = rec(project: UUID(), caps: ["sessions.read"])
        let other = rec(project: UUID())
        let all = [caller.id: caller, other.id: other]
        let decision = PolicyEngine.canRead(
            target: other, caller: caller,
            relation: PolicyEngine.relation(of: other, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.code, .permissionDenied)
    }

    func testCapabilityOffYieldsCapabilityDisabled() {
        let p = UUID()
        let caller = rec(project: p, caps: ["sessions.read"])
        let child = rec(parent: caller.id, project: p)
        let all = [caller.id: caller, child.id: child]
        let decision = PolicyEngine.canControl(
            relation: PolicyEngine.relation(of: child, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.code, .capabilityDisabled)
    }

    func testCannotControlSelf() {
        let caller = rec(project: UUID())
        let all = [caller.id: caller]
        let decision = PolicyEngine.canControl(
            relation: PolicyEngine.relation(of: caller, to: caller, in: all),
            grants: PolicyEngine.grants(for: caller))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.code, .invalidRelationship)
    }
}

// MARK: - Path containment

final class ArtifactPathTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-artifacts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testContainedFileResolves() throws {
        let file = root.appendingPathComponent("note.txt")
        try Data("hi".utf8).write(to: file)
        let resolved = CapabilityRouter.containedPath(root: root, name: "note.txt")
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.hasSuffix("/note.txt"))
    }

    func testDotDotRejected() {
        XCTAssertNil(CapabilityRouter.containedPath(root: root, name: "../escape"))
        XCTAssertNil(CapabilityRouter.containedPath(root: root, name: "/etc/passwd"))
    }

    func testSymlinkEscapeRejected() throws {
        // A symlink inside the root pointing outside must not resolve as contained.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(CapabilityRouter.containedPath(root: root, name: "link"))
    }
}

// MARK: - Worktree name validation

final class WorktreeNameTests: XCTestCase {
    func testValidation() {
        XCTAssertTrue(CapabilityRouter.isValidWorktreeName("fix-login"))
        XCTAssertTrue(CapabilityRouter.isValidWorktreeName("a.b_c-1"))
        XCTAssertFalse(CapabilityRouter.isValidWorktreeName(""))
        XCTAssertFalse(CapabilityRouter.isValidWorktreeName("a/b"))
        XCTAssertFalse(CapabilityRouter.isValidWorktreeName("has space"))
        XCTAssertFalse(CapabilityRouter.isValidWorktreeName(String(repeating: "x", count: 65)))
    }
}

@MainActor
final class ControlPlaneServerTests: XCTestCase {
    func testSecondServerCannotReplaceLiveSocket() throws {
        var projectRoot = URL(fileURLWithPath: #filePath)
        while projectRoot.path != "/" {
            let gitPath = projectRoot.appendingPathComponent(".git").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                break
            }
            projectRoot.deleteLastPathComponent()
        }
        let directory = projectRoot
            .appendingPathComponent(".build-cache/s", isDirectory: true)
            .appendingPathComponent(String(UUID().uuidString.prefix(4)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectStore = ProjectStore(directory: directory)
        let sessionStore = SessionStore()
        let router = CapabilityRouter(
            projectStore: projectStore,
            sessionStore: sessionStore,
            audit: AuditLog(dataDirectory: directory),
            dataDirectory: directory
        )
        let path = directory.appendingPathComponent("control.sock").path
        let first = ControlPlaneServer(socketPath: path, router: router)
        let second = ControlPlaneServer(socketPath: path, router: router)
        try first.start()
        defer { first.stop() }

        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EADDRINUSE)
        }
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Router integration (socket-free)

@MainActor
final class CapabilityRouterTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectStore!
    private var sessionStore: SessionStore!
    private var router: CapabilityRouter!
    private var caller: SessionRecord!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-cp-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(directory: tempDir)
        sessionStore = SessionStore()
        store.addProject(at: URL(fileURLWithPath: "/tmp/cp-demo"))
        let project = store.projects[0]
        caller = store.createSession(projectID: project.id, provider: .claude, accountID: nil, title: "claude: x")
        router = CapabilityRouter(
            projectStore: store, sessionStore: sessionStore,
            audit: AuditLog(dataDirectory: tempDir), dataDirectory: tempDir)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tempDir) }

    private func request(_ capability: String, _ action: String,
                         args: [String: JSONValue] = [:], caller withCaller: Bool = true) -> ControlRequest {
        ControlRequest(capability: capability, action: action, args: args,
                       caller_session_id: withCaller ? caller.id.uuidString : nil)
    }

    func testUnknownActionListsValidActions() async {
        let env = await router.handle(request("uncoil_projects", "frobnicate"))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ACTION")
        if case let .object(details)? = env.error?.details,
           case let .array(actions)? = details["valid_actions"] {
            XCTAssertTrue(actions.contains(.string("list")))
        } else {
            XCTFail("expected valid_actions in details")
        }
    }

    func testUnknownCapability() async {
        let env = await router.handle(request("uncoil_bogus", "list"))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ACTION")
    }

    func testSystemVersion() async {
        let env = await router.handle(request("uncoil_system", "version"))
        XCTAssertTrue(env.ok)
        if case let .object(data)? = env.data {
            XCTAssertEqual(data["protocol_version"], .int(ControlProtocol.version))
        } else { XCTFail("missing data") }
    }

    func testSessionsCurrentResolvesCaller() async {
        let env = await router.handle(request("uncoil_sessions", "current"))
        XCTAssertTrue(env.ok)
        XCTAssertEqual(env.target_session_id, caller.id.uuidString)
    }

    func testProjectsListReturnsProject() async {
        let env = await router.handle(request("uncoil_projects", "list"))
        XCTAssertTrue(env.ok)
        if case let .object(data)? = env.data, case let .array(projects)? = data["projects"] {
            XCTAssertEqual(projects.count, 1)
        } else { XCTFail("missing projects") }
    }

    func testCreateWorktreeDeniedWithoutGrant() async {
        store.updateSession(caller.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants.subtracting(["worktrees.create"]))
        }
        caller = store.sessions.first { $0.id == caller.id }
        let env = await router.handle(request("uncoil_projects", "create_worktree",
                                              args: ["name": .string("feature")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "CAPABILITY_DISABLED")
    }

    func testSessionGroupLifecycleThroughMCP() async {
        let second = store.createSession(
            projectID: store.projects[0].id,
            provider: .codex,
            accountID: nil,
            title: "codex: review"
        )
        let created = await router.handle(request(
            "uncoil_sessions",
            "create_group",
            args: ["name": .string("Review")]
        ))
        XCTAssertTrue(created.ok)
        guard case let .object(createdData)? = created.data,
              let groupID = createdData["group_id"]?.stringValue else {
            return XCTFail("missing group id")
        }

        let assigned = await router.handle(request(
            "uncoil_sessions",
            "assign_group",
            args: [
                "group_id": .string(groupID),
                "session_ids": .array([.string(second.id.uuidString)]),
            ]
        ))
        XCTAssertTrue(assigned.ok)
        XCTAssertEqual(store.sessions.first { $0.id == second.id }?.groupID?.uuidString, groupID)

        let listed = await router.handle(request("uncoil_sessions", "list_groups"))
        XCTAssertTrue(listed.ok)
        guard case let .object(listData)? = listed.data,
              case let .array(groups)? = listData["groups"] else {
            return XCTFail("missing groups")
        }
        XCTAssertEqual(groups.count, 1)

        let deleted = await router.handle(request(
            "uncoil_sessions",
            "delete_group",
            args: ["group_id": .string(groupID)]
        ))
        XCTAssertTrue(deleted.ok)
        XCTAssertNil(store.sessions.first { $0.id == second.id }?.groupID)
    }

    func testCreateWorktreeInvalidName() async {
        // Grant the capability so we exercise name validation, not policy.
        store.updateSession(caller.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants) + ["worktrees.create"]
        }
        let env = await router.handle(request("uncoil_projects", "create_worktree",
                                              args: ["name": .string("bad/name")]))
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error?.code, "INVALID_ARGUMENT")
    }

    /// Every registered action must return help documentation.
    func testHelpCoversEveryAction() async {
        for (capability, doc) in HelpRegistry.capabilities {
            // Whole-capability help.
            let overview = await router.handle(request(capability, "help"))
            XCTAssertTrue(overview.ok, "help failed for \(capability)")
            for action in doc.actionNames {
                let env = await router.handle(
                    request(capability, "help", args: ["for_action": .string(action)]))
                XCTAssertTrue(env.ok, "help for \(capability).\(action) failed")
                if case let .object(data)? = env.data, case .string(let md)? = data["markdown"] {
                    XCTAssertFalse(md.isEmpty, "empty docs for \(capability).\(action)")
                } else {
                    XCTFail("no markdown for \(capability).\(action)")
                }
            }
        }
    }
}
