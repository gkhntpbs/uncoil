import XCTest
@testable import Uncoil

@MainActor
final class PermissionNotificationPolicyTests: XCTestCase {
    func testRiskyGrantsCanNotBeApprovedFromABanner() {
        XCTAssertTrue(PermissionNotificationPolicy.isSensitive(grantKey: "computer.foreground_control"))
        XCTAssertTrue(PermissionNotificationPolicy.isSensitive(grantKey: "sessions.read_all"))
        XCTAssertEqual(
            PermissionNotificationPolicy.category(grantKey: "computer.foreground_control"),
            PermissionNotificationPolicy.sensitiveCategory
        )
    }

    func testOrdinaryGrantsAreDecidableInline() {
        XCTAssertFalse(PermissionNotificationPolicy.isSensitive(grantKey: "projects.read"))
        XCTAssertEqual(
            PermissionNotificationPolicy.category(grantKey: "projects.read"),
            PermissionNotificationPolicy.decidableCategory
        )
    }

    func testUnknownGrantKeyIsTreatedAsSensitive() {
        XCTAssertTrue(PermissionNotificationPolicy.isSensitive(grantKey: "made.up.key"))
    }

    func testEveryCatalogEntryHasAStableCategory() {
        for entry in CapabilityCatalog.all {
            let category = PermissionNotificationPolicy.category(grantKey: entry.key)
            XCTAssertEqual(
                category,
                entry.risky
                    ? PermissionNotificationPolicy.sensitiveCategory
                    : PermissionNotificationPolicy.decidableCategory,
                entry.key
            )
        }
    }

    func testBodyNamesTheGrantAndBothSides() {
        let body = PermissionNotificationPolicy.body(
            grantKey: "projects.read",
            from: "AAAAAAAA-1111-2222-3333-444444444444",
            target: "BBBBBBBB-1111-2222-3333-444444444444"
        )
        XCTAssertTrue(body.contains("AAAAAAAA"))
        XCTAssertTrue(body.contains("BBBBBBBB"))
        XCTAssertTrue(body.contains("Projeleri oku"))
    }
}

@MainActor
final class PermissionScopeAndTimeoutTests: XCTestCase {
    private func service() -> PermissionService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilPermissionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PermissionService(dataDirectory: directory)
    }

    func testOnceGrantAuthorizesExactlyOneCall() {
        let service = service()
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")
        service.grant(id: request.id, scope: .once)

        XCTAssertTrue(service.isGranted(from: "a", to: "b", key: "projects.read"))
        XCTAssertFalse(
            service.isGranted(from: "a", to: "b", key: "projects.read"),
            "a one-time grant is consumed by the call it authorized"
        )
        XCTAssertEqual(
            service.requests.first { $0.id == request.id }?.status,
            .consumed
        )
    }

    func testPersistentGrantKeepsAuthorizing() {
        let service = service()
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")
        service.grant(id: request.id, scope: .persistent)

        XCTAssertTrue(service.isGranted(from: "a", to: "b", key: "projects.read"))
        XCTAssertTrue(service.isGranted(from: "a", to: "b", key: "projects.read"))
        XCTAssertEqual(service.requests.first { $0.id == request.id }?.status, .granted)
    }

    func testGrantDefaultsToPersistentAndLegacyRecordsDecodeAsPersistent() {
        let service = service()
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")
        service.grant(id: request.id)
        XCTAssertEqual(
            service.requests.first { $0.id == request.id }?.effectiveScope,
            .persistent
        )

        let legacy = try! JSONDecoder().decode(
            PermissionRequest.self,
            from: Data(#"{"id":"x","grantKey":"projects.read","fromSessionID":"a","status":"granted","createdAt":0}"#.utf8)
        )
        XCTAssertNil(legacy.scope)
        XCTAssertEqual(legacy.effectiveScope, .persistent)
    }

    func testUnansweredRequestExpiresInsteadOfVanishing() {
        let service = service()
        service.pendingTTL = 0
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")

        XCTAssertTrue(service.pending().isEmpty)
        XCTAssertFalse(service.isGranted(from: "a", to: "b", key: "projects.read"))
        XCTAssertEqual(service.expired().map(\.id), [request.id])
        XCTAssertEqual(
            service.requests.first { $0.id == request.id }?.status,
            .expired,
            "the record is kept so the pane can explain the timeout"
        )
    }

    func testTimeoutCanBeDisabled() {
        let service = service()
        service.pendingTTL = nil
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")
        XCTAssertEqual(service.pending().map(\.id), [request.id])
        _ = service.isGranted(from: "a", to: "b", key: "projects.read")
        XCTAssertTrue(service.expired().isEmpty)
    }

    func testNewRequestNotifiesOnce() {
        let service = service()
        var posted: [String] = []
        service.onRequestCreated = { posted.append($0.grantKey) }

        service.request(grantKey: "projects.read", from: "a", target: "b")
        service.request(grantKey: "projects.read", from: "a", target: "b")
        XCTAssertEqual(posted, ["projects.read"], "a repeated ask reuses the pending record")
    }

    func testBannerDecisionsOnlyApplyToDecidableRequests() {
        let service = service()
        let notifications = PermissionNotificationCenter.shared
        notifications.permissions = service

        let ordinary = service.request(grantKey: "projects.read", from: "a", target: "b")
        notifications.handle(
            action: PermissionNotificationPolicy.allowOnceAction,
            category: PermissionNotificationPolicy.decidableCategory,
            requestID: ordinary.id,
            sessionID: nil
        )
        XCTAssertEqual(service.requests.first { $0.id == ordinary.id }?.status, .granted)
        XCTAssertEqual(service.requests.first { $0.id == ordinary.id }?.scope, .once)

        let risky = service.request(grantKey: "computer.foreground_control", from: "a", target: "b")
        notifications.handle(
            action: PermissionNotificationPolicy.allowOnceAction,
            category: PermissionNotificationPolicy.sensitiveCategory,
            requestID: risky.id,
            sessionID: nil
        )
        XCTAssertEqual(
            service.requests.first { $0.id == risky.id }?.status,
            .pending,
            "a sensitive grant is never approved from a banner"
        )
        notifications.permissions = nil
    }

    func testBannerDenyIsHonoredForDecidableRequests() {
        let service = service()
        let notifications = PermissionNotificationCenter.shared
        notifications.permissions = service
        let request = service.request(grantKey: "projects.read", from: "a", target: "b")
        notifications.handle(
            action: PermissionNotificationPolicy.denyAction,
            category: PermissionNotificationPolicy.decidableCategory,
            requestID: request.id,
            sessionID: nil
        )
        XCTAssertEqual(service.requests.first { $0.id == request.id }?.status, .denied)
        notifications.permissions = nil
    }
}
