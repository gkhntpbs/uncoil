import XCTest
@testable import Uncoil

// MARK: - Capability catalog totality

final class CapabilityCatalogTests: XCTestCase {
    func testEveryGrantKeyHasAnEntry() {
        for key in CapabilityCatalog.allKeys {
            XCTAssertNotNil(CapabilityCatalog.entry(for: key),
                            "grant key \(key) has no catalog entry")
        }
    }

    func testCatalogHasNoUnknownKeys() {
        let known = PolicyEngine.defaultGrants.union(PolicyEngine.optionalGrants)
        for entry in CapabilityCatalog.all {
            XCTAssertTrue(known.contains(entry.key),
                          "catalog lists \(entry.key) which the policy engine does not know")
        }
    }

    func testGroupingCoversAllEntries() {
        let grouped = CapabilityCatalog.grouped().flatMap { $0.entries }
        XCTAssertEqual(Set(grouped.map(\.key)), Set(CapabilityCatalog.all.map(\.key)))
    }
}

// MARK: - PolicyEngine reads live session capabilities

final class LiveCapabilityTests: XCTestCase {
    private func rec(project: UUID, parent: UUID? = nil, caps: [String]? = nil) -> SessionRecord {
        var r = SessionRecord(projectID: project, provider: .claude, accountID: nil, title: "t")
        r.parentSessionID = parent
        r.capabilities = caps
        return r
    }

    func testGrantAddedFlipsDecisionFromDisabledToAllowed() {
        let p = UUID()
        var caller = rec(project: p, caps: Array(PolicyEngine.defaultGrants))
        let child = rec(project: p, parent: caller.id)
        let all = [caller.id: caller, child.id: child]
        let relation = PolicyEngine.relation(of: child, to: caller, in: all)

        // Without the grant: CAPABILITY_DISABLED.
        let before = PolicyEngine.canControl(relation: relation, grants: PolicyEngine.grants(for: caller))
        XCTAssertFalse(before.allowed)
        XCTAssertEqual(before.code, .capabilityDisabled)

        // Mutating the record's capabilities (what the proactive toggle does)
        // flips the very next read to allowed — grants are read live.
        caller.capabilities = Array(PolicyEngine.defaultGrants) + ["sessions.control_children"]
        let after = PolicyEngine.canControl(relation: relation, grants: PolicyEngine.grants(for: caller))
        XCTAssertTrue(after.allowed)
    }
}

// MARK: - PermissionService proactive grants + test injection

@MainActor
final class PermissionServiceProactiveTests: XCTestCase {
    private func makeService() -> PermissionService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-perm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PermissionService(dataDirectory: dir)
    }

    func testAddGrantMatchesApproveFlowShape() {
        let a = makeService()
        let granted = a.addGrant(grantKey: "sessions.control_children", from: "A", target: "B")
        XCTAssertEqual(granted.status, .granted)
        XCTAssertNotNil(granted.decidedAt)
        XCTAssertTrue(a.isGranted(from: "A", to: "B", key: "sessions.control_children"))

        // Same record shape the approve flow (request → grant) produces.
        let b = makeService()
        let req = b.request(grantKey: "sessions.control_children", from: "A", target: "B")
        b.grant(id: req.id)
        let viaApprove = b.granted().first { $0.id == req.id }
        XCTAssertEqual(viaApprove?.status, granted.status)
        XCTAssertEqual(viaApprove?.grantKey, granted.grantKey)
        XCTAssertEqual(viaApprove?.fromSessionID, granted.fromSessionID)
        XCTAssertEqual(viaApprove?.targetSessionID, granted.targetSessionID)
        XCTAssertNotNil(viaApprove?.decidedAt)
    }

    func testInjectTestRequestCreatesValidPending() {
        let a = makeService()
        let injected = a.injectTestRequest()
        XCTAssertEqual(injected.status, .pending)
        XCTAssertFalse(injected.fromSessionID.isEmpty)
        XCTAssertNotNil(injected.targetSessionID)
        XCTAssertTrue(a.pending().contains { $0.id == injected.id })
    }

    func testAddGrantIsDirectional() {
        let a = makeService()
        a.addGrant(grantKey: "sessions.control_children", from: "A", target: "B")
        XCTAssertTrue(a.isGranted(from: "A", to: "B", key: "sessions.control_children"))
        XCTAssertFalse(a.isGranted(from: "C", to: "B", key: "sessions.control_children"))
    }
}
