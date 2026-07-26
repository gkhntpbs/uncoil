import Foundation

/// What a notification should look like once the policy has said yes.
struct NotificationDispatch: Equatable, Sendable {
    var priority: NotificationPrefs.Priority
    var sound: String
    /// True when this is a repeat of a state the user has not acted on.
    var isReminder: Bool
    /// 1 for the first banner, 2 for the first reminder, and so on.
    var attempt: Int
}

/// Why a notification was not sent. Surfaced in the settings pane's live
/// explanation, and asserted directly by the tests.
enum NotificationSuppression: String, Equatable, Sendable {
    case masterOff
    case eventOff
    case projectOff
    case quietHours
    case appActive
    case visibleSession
    case alreadySent
    case reminderOff
    case reminderNotDue
    case reminderLimit

    var label: String {
        switch self {
        case .masterOff: "Bildirimler kapalı"
        case .eventOff: "Bu olay için bildirim kapalı"
        case .projectOff: "Proje için bildirim kapalı"
        case .quietHours: "Sessiz saatler"
        case .appActive: "Uncoil ön planda"
        case .visibleSession: "Oturum zaten ekranda"
        case .alreadySent: "Bu durum için zaten bildirildi"
        case .reminderOff: "Hatırlatma kapalı"
        case .reminderNotDue: "Hatırlatma zamanı gelmedi"
        case .reminderLimit: "Hatırlatma sınırına ulaşıldı"
        }
    }
}

enum NotificationDecision: Equatable, Sendable {
    case send(NotificationDispatch)
    case skip(NotificationSuppression)

    var dispatch: NotificationDispatch? {
        if case .send(let dispatch) = self { return dispatch }
        return nil
    }

    var suppression: NotificationSuppression? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

/// How many times a given (session, event) pair has already notified, and when.
struct NotificationAttempt: Equatable, Sendable {
    var count = 0
    var lastSentAt: Date?
}

/// Pure decision layer for every banner Uncoil posts.
///
/// Kept free of `UNUserNotificationCenter`, timers and stores so the rules —
/// dedup, reminders, quiet hours, delivery filters — are asserted directly in
/// the unit suite rather than inferred from what did or did not pop up.
enum NotificationPolicy {
    struct Context: Equatable, Sendable {
        var now: Date
        /// True when Uncoil is the frontmost application.
        var appIsActive = false
        /// The session the user is currently looking at, if any.
        var visibleSessionID: UUID?
        /// True when the reminder sweep is asking, rather than a fresh event.
        var isReminderPass = false

        init(
            now: Date,
            appIsActive: Bool = false,
            visibleSessionID: UUID? = nil,
            isReminderPass: Bool = false
        ) {
            self.now = now
            self.appIsActive = appIsActive
            self.visibleSessionID = visibleSessionID
            self.isReminderPass = isReminderPass
        }
    }

    /// The dedup / reminder ledger key for a session's event.
    static func key(sessionID: UUID, event: NotificationEvent) -> String {
        "\(sessionID.uuidString)-\(event.rawValue)"
    }

    static func decide(
        event: NotificationEvent,
        projectID: UUID?,
        sessionID: UUID?,
        prefs: NotificationPrefs,
        attempt: NotificationAttempt,
        context: Context,
        calendar: Calendar = .current
    ) -> NotificationDecision {
        guard prefs.enabled else { return .skip(.masterOff) }
        guard prefs.isEnabled(event) else { return .skip(.eventOff) }
        if let projectID, !prefs.isEnabled(project: projectID) { return .skip(.projectOff) }

        let priority = prefs.priority(for: event, project: projectID)

        // Repeat handling comes before the delivery filters: a state that is
        // still unanswered but not yet due should read as "not due", not as
        // "app was in the foreground at that instant".
        let isReminder = attempt.count > 0
        if isReminder {
            guard context.isReminderPass else { return .skip(.alreadySent) }
            guard prefs.remindsAbout(event) else { return .skip(.reminderOff) }
            let limit = prefs.reminders.maxCount
            if limit > 0, attempt.count > limit { return .skip(.reminderLimit) }
            guard let last = attempt.lastSentAt else { return .skip(.reminderNotDue) }
            guard context.now.timeIntervalSince(last) >= prefs.reminders.interval else {
                return .skip(.reminderNotDue)
            }
        }

        // Quiet hours let high-priority events through when the user allows it;
        // everything else waits for the window to close.
        if prefs.quietHours.contains(context.now, calendar: calendar) {
            let exempt = prefs.quietHours.allowHighPriority && priority == .high
            if !exempt { return .skip(.quietHours) }
        }

        if prefs.onlyWhenBackgrounded, context.appIsActive { return .skip(.appActive) }
        if prefs.suppressForVisibleSession,
           let sessionID,
           context.visibleSessionID == sessionID,
           context.appIsActive {
            return .skip(.visibleSession)
        }

        return .send(NotificationDispatch(
            priority: priority,
            sound: prefs.sound(for: event, project: projectID),
            isReminder: isReminder,
            attempt: attempt.count + 1
        ))
    }
}

/// The mutable side of the policy: who has been told what, and when.
///
/// Lives next to the pure rules rather than inside `SessionStore` so a reminder
/// sweep can be replayed in a test with an injected clock.
struct NotificationLedger: Equatable {
    private(set) var attempts: [String: NotificationAttempt] = [:]

    init() {}

    func attempt(sessionID: UUID, event: NotificationEvent) -> NotificationAttempt {
        attempts[NotificationPolicy.key(sessionID: sessionID, event: event)] ?? NotificationAttempt()
    }

    /// Records a delivered banner and returns nothing — callers already hold
    /// the dispatch they acted on.
    mutating func record(sessionID: UUID, event: NotificationEvent, at date: Date) {
        let key = NotificationPolicy.key(sessionID: sessionID, event: event)
        var value = attempts[key] ?? NotificationAttempt()
        value.count += 1
        value.lastSentAt = date
        attempts[key] = value
    }

    /// Clears one event's history — the state it described is over.
    mutating func clear(sessionID: UUID, event: NotificationEvent) {
        attempts.removeValue(forKey: NotificationPolicy.key(sessionID: sessionID, event: event))
    }

    /// Clears everything for a session (new turn, session ended).
    mutating func clear(sessionID: UUID) {
        let prefix = sessionID.uuidString
        attempts = attempts.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Events currently mid-flight for a session, i.e. notified at least once
    /// and not yet cleared. This is what the reminder sweep walks.
    func pending() -> [(sessionID: UUID, event: NotificationEvent)] {
        attempts.keys.compactMap { key in
            // "<uuid>-<event>": the UUID's own dashes make a plain split unsafe,
            // so the event is taken from the tail and the rest is the id.
            guard let separator = key.lastIndex(of: "-") else { return nil }
            let rawEvent = String(key[key.index(after: separator)...])
            guard let event = NotificationEvent(rawValue: rawEvent),
                  let id = UUID(uuidString: String(key[key.startIndex..<separator]))
            else { return nil }
            return (id, event)
        }
    }
}
