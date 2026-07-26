import XCTest
@testable import Uncoil

/// The rules behind every banner: dedup, reminders, quiet hours and the
/// delivery filters. All pure, so the clock is injected rather than waited on.
final class NotificationPolicyTests: XCTestCase {
    private let session = UUID()
    private let project = UUID()

    private var now: Date {
        // A fixed midday so quiet-hours tests are not affected by the real time.
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 26, hour: 12, minute: 0)
        )!
    }

    private func decide(
        _ event: NotificationEvent = .input,
        prefs: NotificationPrefs,
        attempt: NotificationAttempt = NotificationAttempt(),
        context: NotificationPolicy.Context? = nil
    ) -> NotificationDecision {
        NotificationPolicy.decide(
            event: event,
            projectID: project,
            sessionID: session,
            prefs: prefs,
            attempt: attempt,
            context: context ?? .init(now: now)
        )
    }

    // MARK: - Master switches

    func testDefaultsSendTheFirstBanner() {
        let decision = decide(prefs: NotificationPrefs())
        XCTAssertNotNil(decision.dispatch)
        XCTAssertEqual(decision.dispatch?.attempt, 1)
        XCTAssertFalse(decision.dispatch?.isReminder ?? true)
    }

    func testMasterSwitchSuppressesEverything() {
        var prefs = NotificationPrefs()
        prefs.enabled = false
        XCTAssertEqual(decide(prefs: prefs).suppression, .masterOff)
    }

    func testPerEventSwitchSuppressesOnlyThatEvent() {
        var prefs = NotificationPrefs()
        prefs.update(.turnCompleted) { $0.enabled = false }
        XCTAssertEqual(decide(.turnCompleted, prefs: prefs).suppression, .eventOff)
        XCTAssertNotNil(decide(.input, prefs: prefs).dispatch)
    }

    func testProjectOverrideSuppresses() {
        var prefs = NotificationPrefs()
        prefs.perProject[project] = .init(enabled: false)
        XCTAssertEqual(decide(prefs: prefs).suppression, .projectOff)
    }

    // MARK: - Priority and sound resolution

    func testEventOverrideBeatsProjectAndGlobal() {
        var prefs = NotificationPrefs()
        prefs.priority = .low
        prefs.perProject[project] = .init(priority: .normal, sound: "Glass")
        prefs.update(.input) { $0.priority = .high; $0.sound = "Ping" }

        let dispatch = decide(prefs: prefs).dispatch
        XCTAssertEqual(dispatch?.priority, .high)
        XCTAssertEqual(dispatch?.sound, "Ping")
    }

    func testProjectOverrideBeatsGlobalWhenEventIsUnset() {
        var prefs = NotificationPrefs()
        prefs.priority = .low
        prefs.sound = "default"
        prefs.perProject[project] = .init(priority: .high, sound: "Glass")

        let dispatch = decide(prefs: prefs).dispatch
        XCTAssertEqual(dispatch?.priority, .high)
        XCTAssertEqual(dispatch?.sound, "Glass")
    }

    // MARK: - Dedup

    func testSecondEventForTheSameStateIsDeduped() {
        let prefs = NotificationPrefs()
        let attempt = NotificationAttempt(count: 1, lastSentAt: now)
        XCTAssertEqual(decide(prefs: prefs, attempt: attempt).suppression, .alreadySent)
    }

    // MARK: - Reminders

    func testReminderIsSkippedWhenRemindersAreOff() {
        let prefs = NotificationPrefs()  // reminders default to off
        let decision = decide(
            prefs: prefs,
            attempt: NotificationAttempt(count: 1, lastSentAt: now.addingTimeInterval(-3600)),
            context: .init(now: now, isReminderPass: true)
        )
        XCTAssertEqual(decision.suppression, .reminderOff)
    }

    func testReminderFiresOnceTheIntervalHasPassed() {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        prefs.reminders.intervalMinutes = 5

        let tooEarly = decide(
            prefs: prefs,
            attempt: NotificationAttempt(count: 1, lastSentAt: now.addingTimeInterval(-4 * 60)),
            context: .init(now: now, isReminderPass: true)
        )
        XCTAssertEqual(tooEarly.suppression, .reminderNotDue)

        let due = decide(
            prefs: prefs,
            attempt: NotificationAttempt(count: 1, lastSentAt: now.addingTimeInterval(-5 * 60)),
            context: .init(now: now, isReminderPass: true)
        )
        XCTAssertEqual(due.dispatch?.isReminder, true)
        XCTAssertEqual(due.dispatch?.attempt, 2)
    }

    func testReminderStopsAtTheConfiguredLimit() {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        prefs.reminders.intervalMinutes = 5
        prefs.reminders.maxCount = 2

        let context = NotificationPolicy.Context(now: now, isReminderPass: true)
        let long = now.addingTimeInterval(-3600)

        // count 1 and 2 are the first and second reminders; 3 is over the limit.
        XCTAssertNotNil(decide(
            prefs: prefs, attempt: .init(count: 1, lastSentAt: long), context: context
        ).dispatch)
        XCTAssertNotNil(decide(
            prefs: prefs, attempt: .init(count: 2, lastSentAt: long), context: context
        ).dispatch)
        XCTAssertEqual(
            decide(prefs: prefs, attempt: .init(count: 3, lastSentAt: long), context: context)
                .suppression,
            .reminderLimit
        )
    }

    func testUnlimitedRemindersNeverHitTheLimit() {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        prefs.reminders.maxCount = 0

        let decision = decide(
            prefs: prefs,
            attempt: .init(count: 99, lastSentAt: now.addingTimeInterval(-3600)),
            context: .init(now: now, isReminderPass: true)
        )
        XCTAssertNotNil(decision.dispatch)
    }

    func testMomentaryEventsAreNeverReminded() {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        XCTAssertFalse(prefs.remindsAbout(.turnCompleted))
        XCTAssertTrue(prefs.remindsAbout(.input))

        let decision = decide(
            .turnCompleted,
            prefs: prefs,
            attempt: .init(count: 1, lastSentAt: now.addingTimeInterval(-3600)),
            context: .init(now: now, isReminderPass: true)
        )
        XCTAssertEqual(decision.suppression, .reminderOff)
    }

    func testPerEventReminderOptOut() {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        prefs.update(.input) { $0.remind = false }
        XCTAssertFalse(prefs.remindsAbout(.input))
        XCTAssertTrue(prefs.remindsAbout(.permission))
    }

    // MARK: - Quiet hours

    func testQuietHoursWrapAroundMidnight() {
        var quiet = QuietHours()
        quiet.enabled = true
        quiet.startMinute = 23 * 60
        quiet.endMinute = 8 * 60

        func at(_ hour: Int) -> Date {
            Calendar.current.date(
                from: DateComponents(year: 2026, month: 7, day: 26, hour: hour)
            )!
        }
        XCTAssertTrue(quiet.contains(at(23)))
        XCTAssertTrue(quiet.contains(at(2)))
        XCTAssertTrue(quiet.contains(at(7)))
        XCTAssertFalse(quiet.contains(at(8)))
        XCTAssertFalse(quiet.contains(at(12)))
    }

    func testQuietHoursSuppressUnlessHighPriorityIsExempt() {
        var prefs = NotificationPrefs()
        prefs.quietHours.enabled = true
        prefs.quietHours.startMinute = 0
        prefs.quietHours.endMinute = 23 * 60 + 59
        prefs.quietHours.allowHighPriority = true

        XCTAssertEqual(decide(prefs: prefs).suppression, .quietHours)

        prefs.update(.input) { $0.priority = .high }
        XCTAssertNotNil(decide(prefs: prefs).dispatch)

        prefs.quietHours.allowHighPriority = false
        XCTAssertEqual(decide(prefs: prefs).suppression, .quietHours)
    }

    // MARK: - Delivery filters

    func testOnlyWhenBackgrounded() {
        var prefs = NotificationPrefs()
        prefs.onlyWhenBackgrounded = true

        XCTAssertEqual(
            decide(prefs: prefs, context: .init(now: now, appIsActive: true)).suppression,
            .appActive
        )
        XCTAssertNotNil(
            decide(prefs: prefs, context: .init(now: now, appIsActive: false)).dispatch
        )
    }

    func testVisibleSessionIsSuppressedOnlyWhileTheAppIsFrontmost() {
        var prefs = NotificationPrefs()
        prefs.suppressForVisibleSession = true

        XCTAssertEqual(
            decide(prefs: prefs, context: .init(
                now: now, appIsActive: true, visibleSessionID: session
            )).suppression,
            .visibleSession
        )
        // Same session on screen, but Uncoil is in the background: the user
        // cannot see it, so the banner is what tells them.
        XCTAssertNotNil(
            decide(prefs: prefs, context: .init(
                now: now, appIsActive: false, visibleSessionID: session
            )).dispatch
        )
    }

    // MARK: - Ledger

    func testLedgerRecordsClearsAndListsPendingEntries() {
        var ledger = NotificationLedger()
        XCTAssertEqual(ledger.attempt(sessionID: session, event: .input).count, 0)

        ledger.record(sessionID: session, event: .input, at: now)
        ledger.record(sessionID: session, event: .input, at: now.addingTimeInterval(60))
        let attempt = ledger.attempt(sessionID: session, event: .input)
        XCTAssertEqual(attempt.count, 2)
        XCTAssertEqual(attempt.lastSentAt, now.addingTimeInterval(60))

        let other = UUID()
        ledger.record(sessionID: other, event: .permission, at: now)
        XCTAssertEqual(ledger.pending().count, 2)
        XCTAssertTrue(ledger.pending().contains { $0.sessionID == session && $0.event == .input })
        XCTAssertTrue(ledger.pending().contains { $0.sessionID == other && $0.event == .permission })

        ledger.clear(sessionID: session, event: .input)
        XCTAssertEqual(ledger.attempt(sessionID: session, event: .input).count, 0)

        ledger.clear(sessionID: other)
        XCTAssertTrue(ledger.pending().isEmpty)
    }

    // MARK: - Persistence

    func testPrefsDecodeFromSettingsWrittenBeforePerEventPrefsExisted() throws {
        // The old shape, byte for byte — `perProject` really is an array on
        // disk, because a dictionary with non-String keys is what JSONEncoder
        // flattens into one. A synthesised decoder would throw on the missing keys,
        // and because SettingsStore decodes with `try?` that would silently wipe
        // every other setting — the reason this decoder is written by hand.
        let legacy = """
        {
          "enabled": true,
          "notifyPermission": true,
          "notifyInput": false,
          "notifyTurnCompleted": true,
          "priority": "high",
          "sound": "Glass",
          "perProject": []
        }
        """.data(using: .utf8)!

        let prefs = try JSONDecoder().decode(NotificationPrefs.self, from: legacy)
        XCTAssertTrue(prefs.enabled)
        XCTAssertEqual(prefs.priority, .high)
        XCTAssertEqual(prefs.sound, "Glass")
        // The retired flag survived as a per-event override.
        XCTAssertFalse(prefs.isEnabled(.input))
        XCTAssertTrue(prefs.isEnabled(.permission))
        // Everything new fell back to its default.
        XCTAssertFalse(prefs.reminders.enabled)
        XCTAssertFalse(prefs.quietHours.enabled)
        XCTAssertTrue(prefs.groupByProject)
    }

    func testPrefsRoundTrip() throws {
        var prefs = NotificationPrefs()
        prefs.reminders.enabled = true
        prefs.reminders.intervalMinutes = 7
        prefs.reminders.maxCount = 0
        prefs.quietHours.enabled = true
        prefs.quietHours.startMinute = 90
        prefs.onlyWhenBackgrounded = true
        prefs.update(.problem) { $0.priority = .low; $0.sound = "none" }

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(NotificationPrefs.self, from: data)
        XCTAssertEqual(decoded, prefs)
    }
}
