import UserNotifications
import XCTest
@testable import Uncoil

/// macOS asks for notification permission exactly once. The app used to ask from
/// inside every post, on a background queue, so a refusal — or a prompt the user
/// never saw — turned into every later notification vanishing with nothing on
/// screen to explain it. These are the rules that replaced that.
final class NotificationAuthorizationStatusTests: XCTestCase {
    private typealias Status = NotificationAuthorization.Status

    func testSystemStatusesMapOntoWhatTheUserIsTold() {
        XCTAssertEqual(Status(.notDetermined), .notRequested)
        XCTAssertEqual(Status(.authorized), .granted)
        XCTAssertEqual(Status(.provisional), .provisional)
        XCTAssertEqual(Status(.denied), .denied)
    }

    func testOnlyAuthorisedStatesCanDeliver() {
        XCTAssertTrue(Status.granted.canDeliver)
        XCTAssertTrue(Status.provisional.canDeliver, "Quiet delivery is still delivery")
        XCTAssertFalse(Status.denied.canDeliver)
        XCTAssertFalse(Status.notRequested.canDeliver)
        XCTAssertFalse(Status.unknown.canDeliver)
    }

    /// Asking again after a refusal does nothing at all — macOS drops it — so
    /// the button that would ask must not be offered. System Settings is the
    /// only way back.
    func testAskingIsOnlyOfferedWhileItCanStillWork() {
        XCTAssertTrue(Status.notRequested.canRequest)
        XCTAssertTrue(Status.unknown.canRequest)
        XCTAssertFalse(Status.denied.canRequest)
        XCTAssertFalse(Status.granted.canRequest)
    }

    func testEveryStatusSaysSomethingToTheUser() {
        for status in [Status.unknown, .notRequested, .granted, .provisional, .denied] {
            XCTAssertFalse(status.label.isEmpty)
        }
    }
}

/// Which events post a notification, and whose preferences decide.
final class AttentionNotificationRulesTests: XCTestCase {
    private let project = UUID()

    func testTheGlobalSwitchTurnsOffEveryProject() {
        var prefs = NotificationPrefs()
        prefs.enabled = false
        XCTAssertFalse(prefs.isEnabled(project: project))
    }

    func testAProjectCanBeSilencedOnItsOwn() {
        var prefs = NotificationPrefs()
        prefs.perProject[project] = .init(enabled: false)
        XCTAssertFalse(prefs.isEnabled(project: project))
        XCTAssertTrue(prefs.isEnabled(project: UUID()), "Other projects keep notifying")
    }

    func testAProjectOverridesPriorityAndSoundWithoutTouchingTheDefaults() {
        var prefs = NotificationPrefs()
        prefs.priority = .normal
        prefs.sound = "default"
        prefs.perProject[project] = .init(priority: .high, sound: "Glass")
        XCTAssertEqual(prefs.priority(project: project), .high)
        XCTAssertEqual(prefs.sound(project: project), "Glass")
        XCTAssertEqual(prefs.priority(project: UUID()), .normal)
        XCTAssertEqual(prefs.sound(project: UUID()), "default")
    }

    /// Priority is what decides whether a banner interrupts, so the mapping is
    /// part of the behaviour rather than a detail.
    func testPriorityDecidesHowLoudlyMacOSPresentsIt() {
        XCTAssertEqual(NotificationPrefs.Priority.low.interruptionLevel, .passive)
        XCTAssertEqual(NotificationPrefs.Priority.normal.interruptionLevel, .active)
        XCTAssertEqual(NotificationPrefs.Priority.high.interruptionLevel, .timeSensitive)
    }
}

/// A session that asked for something has to be findable in the sidebar without
/// reading every row — the banner is easy to miss, and a finished turn goes back
/// to looking exactly like an idle one.
@MainActor
final class SessionAttentionTests: XCTestCase {
    private var store: SessionStore!
    private let session = UUID()

    override func setUp() {
        store = SessionStore()
    }

    func testWaitingStatesWantAttentionOnTheirOwn() {
        store.setStatus(.waitingForInput, for: session)
        XCTAssertTrue(store.wantsAttention(session))
        store.setStatus(.waitingForPermission, for: session)
        XCTAssertTrue(store.wantsAttention(session))
    }

    func testWorkingAndQuietStatesDoNot() {
        for status in [AgentSessionStatus.idle, .thinking, .running, .completed, .terminated] {
            store.setStatus(status, for: session)
            XCTAssertFalse(store.wantsAttention(session), "\(status) should not pulse")
        }
    }

    /// A completed turn drops back to `.idle`, so without this a finished agent
    /// would be indistinguishable from one nobody has started.
    func testAFinishedTurnKeepsWantingAttentionUntilItIsOpened() {
        store.setStatus(.idle, for: session)
        store.markAttention(session)
        XCTAssertTrue(store.wantsAttention(session))
        store.clearAttention(session)
        XCTAssertFalse(store.wantsAttention(session))
    }

    func testClearingASessionLeavesTheOthersAlone() {
        let other = UUID()
        store.markAttention(session)
        store.markAttention(other)
        store.clearAttention(session)
        XCTAssertFalse(store.wantsAttention(session))
        XCTAssertTrue(store.wantsAttention(other))
    }

    /// Opening a session that is still waiting must not silence the row: the
    /// state is real, not just an unread marker.
    func testOpeningASessionThatIsStillWaitingKeepsItMarked() {
        store.setStatus(.waitingForInput, for: session)
        store.markAttention(session)
        store.clearAttention(session)
        XCTAssertTrue(store.wantsAttention(session))
    }
}
