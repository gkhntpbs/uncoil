import Foundation
import UserNotifications
import AppKit

/// The distinct things Uncoil can notify about.
///
/// Each one carries its own on/off, priority, sound and reminder switch, so
/// "tell me loudly when an agent is blocked, stay quiet when a turn ends" is a
/// setting rather than a compromise.
enum NotificationEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case permission
    case input
    case turnCompleted
    case problem
    case taskCompleted
    case mergeReady
    case loginRequired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permission: String(localized: "Waiting for permission")
        case .input: String(localized: "Waiting for input")
        case .turnCompleted: String(localized: "Turn done")
        case .problem: String(localized: "Errors and problems")
        case .taskCompleted: String(localized: "Task done")
        case .mergeReady: String(localized: "Ready to merge")
        case .loginRequired: String(localized: "Login needed")
        }
    }

    var detail: String {
        switch self {
        case .permission: String(localized: "The agent is asking to use a tool.")
        case .input: String(localized: "The agent asked a question and is waiting for your answer.")
        case .turnCompleted: String(localized: "The agent finished its turn; over to you.")
        case .problem: String(localized: "A runtime error, a failing test or a dropped connection.")
        case .taskCompleted: String(localized: "A task finished.")
        case .mergeReady: String(localized: "A task branch is ready to merge.")
        case .loginRequired: String(localized: "The provider session dropped; you need to sign in again.")
        }
    }

    var symbolName: String {
        switch self {
        case .permission: "hand.raised"
        case .input: "bubble.left.and.text.bubble.right"
        case .turnCompleted: "checkmark.circle"
        case .problem: "exclamationmark.triangle"
        case .taskCompleted: "flag.checkered"
        case .mergeReady: "arrow.trianglehead.merge"
        case .loginRequired: "person.badge.key"
        }
    }

    /// Whether the event describes a state that *persists* until the user acts.
    /// Only those can sensibly be reminded about — a finished turn is a moment,
    /// not a condition, so re-announcing it would just be noise.
    var supportsReminder: Bool {
        switch self {
        case .permission, .input, .loginRequired, .mergeReady: true
        case .turnCompleted, .problem, .taskCompleted: false
        }
    }

    /// Everything is on out of the box; the point of the pane is turning things
    /// off, not discovering that half of them were never on.
    var defaultEnabled: Bool { true }
}

/// Per-event overrides. Every field is optional: nil means "follow the global
/// setting", which is what keeps the general pane meaningful.
struct NotificationEventPrefs: Codable, Equatable, Sendable {
    var enabled: Bool?
    var priority: NotificationPrefs.Priority?
    var sound: String?
    /// Whether this event re-notifies while it stays unanswered.
    var remind: Bool?
}

/// Repeat-reminder configuration: how often an unanswered state re-announces
/// itself, and how many times before it gives up.
struct ReminderPrefs: Codable, Equatable, Sendable {
    var enabled = false
    /// Minutes between reminders; clamped to at least 1.
    var intervalMinutes = 5
    /// How many reminders may follow the first banner. 0 = unlimited.
    var maxCount = 3

    var interval: TimeInterval { TimeInterval(max(1, intervalMinutes) * 60) }
}

/// A daily window in which only high-priority events may interrupt.
struct QuietHours: Codable, Equatable, Sendable {
    var enabled = false
    /// Minutes past midnight.
    var startMinute = 23 * 60
    var endMinute = 8 * 60
    /// When true, `high` priority events still get through.
    var allowHighPriority = true

    /// True when `date`'s local time falls inside the window. Windows that wrap
    /// past midnight (23:00 → 08:00) are handled by the inverted comparison.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return startMinute < endMinute
            ? (minute >= startMinute && minute < endMinute)
            : (minute >= startMinute || minute < endMinute)
    }

    static func label(forMinute minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

/// Notification preferences: global defaults, per-event overrides, reminders,
/// quiet hours, delivery filters and per-project overrides.
struct NotificationPrefs: Codable, Equatable, Sendable {
    enum Priority: String, Codable, CaseIterable, Identifiable, Sendable {
        case low      // passive: no banner interruption
        case normal   // active
        case high     // time sensitive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .low: String(localized: "Low")
            case .normal: String(localized: "Normal")
            case .high: String(localized: "High")
            }
        }

        var detail: String {
            switch self {
            case .low: String(localized: "Lands silently in Notification Center.")
            case .normal: String(localized: "Appears as an ordinary banner.")
            case .high: String(localized: "Breaks through Focus, shown as time-sensitive.")
            }
        }

        var interruptionLevel: UNNotificationInterruptionLevel {
            switch self {
            case .low: .passive
            case .normal: .active
            case .high: .timeSensitive
            }
        }
    }

    struct ProjectOverride: Codable, Equatable, Sendable {
        var enabled: Bool?
        var priority: Priority?
        var sound: String?
    }

    // MARK: Global

    var enabled = true
    var priority: Priority = .normal
    /// "default", "none", or a system sound name (Glass, Ping, …).
    var sound = "default"

    // MARK: Per-event

    var events: [String: NotificationEventPrefs] = [:]

    // MARK: Reminders / quiet hours / delivery

    var reminders = ReminderPrefs()
    var quietHours = QuietHours()
    /// Only notify while Uncoil is not the frontmost app.
    var onlyWhenBackgrounded = false
    /// Stay quiet about the session the user is already looking at.
    var suppressForVisibleSession = false
    /// Group a project's banners into one Notification Center stack.
    var groupByProject = true

    // MARK: Per-project

    var perProject: [UUID: ProjectOverride] = [:]

    init() {}

    // MARK: - Effective values

    func isEnabled(project: UUID) -> Bool {
        guard enabled else { return false }
        return perProject[project]?.enabled ?? true
    }

    func priority(project: UUID) -> Priority {
        perProject[project]?.priority ?? priority
    }

    func sound(project: UUID) -> String {
        perProject[project]?.sound ?? sound
    }

    func prefs(for event: NotificationEvent) -> NotificationEventPrefs {
        events[event.rawValue] ?? NotificationEventPrefs()
    }

    func isEnabled(_ event: NotificationEvent) -> Bool {
        prefs(for: event).enabled ?? event.defaultEnabled
    }

    /// Priority for an event in a project: event override → project override →
    /// global. The event wins because it is the most specific thing the user set.
    func priority(for event: NotificationEvent, project: UUID?) -> Priority {
        if let value = prefs(for: event).priority { return value }
        if let project { return priority(project: project) }
        return priority
    }

    func sound(for event: NotificationEvent, project: UUID?) -> String {
        if let value = prefs(for: event).sound { return value }
        if let project { return sound(project: project) }
        return sound
    }

    /// Whether this event re-notifies while it stays unanswered.
    func remindsAbout(_ event: NotificationEvent) -> Bool {
        guard reminders.enabled, event.supportsReminder else { return false }
        return prefs(for: event).remind ?? true
    }

    mutating func update(
        _ event: NotificationEvent,
        _ change: (inout NotificationEventPrefs) -> Void
    ) {
        var value = prefs(for: event)
        change(&value)
        events[event.rawValue] = value
    }

    // MARK: - Legacy accessors
    //
    // Call sites that predate per-event prefs keep working; they now read
    // through the event table instead of standalone flags.

    var notifyPermission: Bool { isEnabled(.permission) }
    var notifyInput: Bool { isEnabled(.input) }
    var notifyTurnCompleted: Bool { isEnabled(.turnCompleted) }

    /// System alert sounds available for picking.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static func soundLabel(_ value: String) -> String {
        switch value {
        case "default": "Default"
        case "none": "Silent"
        default: value
        }
    }

    static func preview(sound: String) {
        guard sound != "default", sound != "none" else { return }
        NSSound(named: sound)?.play()
    }

    // MARK: - Codable
    //
    // Written by hand on purpose. The synthesised decoder treats a missing key
    // as an error even when the property has a default, so adding a field would
    // make every older settings.json fail to decode — and because the whole
    // Persisted blob is decoded with `try?`, that failure would silently reset
    // *all* settings, not just notifications. Every field is optional here, and
    // the three retired flags are migrated into the event table.

    private enum CodingKeys: String, CodingKey {
        case enabled, priority, sound, events, reminders, quietHours
        case onlyWhenBackgrounded, suppressForVisibleSession, groupByProject, perProject
        case notifyPermission, notifyInput, notifyTurnCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        sound = try container.decodeIfPresent(String.self, forKey: .sound) ?? "default"
        events = try container.decodeIfPresent(
            [String: NotificationEventPrefs].self, forKey: .events
        ) ?? [:]
        reminders = try container.decodeIfPresent(ReminderPrefs.self, forKey: .reminders)
            ?? ReminderPrefs()
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
            ?? QuietHours()
        onlyWhenBackgrounded = try container.decodeIfPresent(
            Bool.self, forKey: .onlyWhenBackgrounded
        ) ?? false
        suppressForVisibleSession = try container.decodeIfPresent(
            Bool.self, forKey: .suppressForVisibleSession
        ) ?? false
        groupByProject = try container.decodeIfPresent(Bool.self, forKey: .groupByProject) ?? true
        perProject = try container.decodeIfPresent(
            [UUID: ProjectOverride].self, forKey: .perProject
        ) ?? [:]

        // Migrate the three pre-per-event flags. Only an explicit `false` is
        // carried over; a missing key means the user never opted out.
        migrate(container, .notifyPermission, into: .permission)
        migrate(container, .notifyInput, into: .input)
        migrate(container, .notifyTurnCompleted, into: .turnCompleted)
    }

    private mutating func migrate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        into event: NotificationEvent
    ) {
        guard events[event.rawValue] == nil,
              let legacy = try? container.decodeIfPresent(Bool.self, forKey: key),
              legacy != event.defaultEnabled
        else { return }
        update(event) { $0.enabled = legacy }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(priority, forKey: .priority)
        try container.encode(sound, forKey: .sound)
        if !events.isEmpty { try container.encode(events, forKey: .events) }
        if reminders != ReminderPrefs() { try container.encode(reminders, forKey: .reminders) }
        if quietHours != QuietHours() { try container.encode(quietHours, forKey: .quietHours) }
        if onlyWhenBackgrounded {
            try container.encode(onlyWhenBackgrounded, forKey: .onlyWhenBackgrounded)
        }
        if suppressForVisibleSession {
            try container.encode(suppressForVisibleSession, forKey: .suppressForVisibleSession)
        }
        if !groupByProject { try container.encode(groupByProject, forKey: .groupByProject) }
        if !perProject.isEmpty { try container.encode(perProject, forKey: .perProject) }
    }
}

/// Posts session-attention notifications with per-project prefs and
/// once-per-state dedup handled by the caller.
enum AttentionNotifier {
    /// True while a test bundle is loaded.
    ///
    /// `UNUserNotificationCenter` is not usable in the unit-test host, and its
    /// authorization callback arrives on a background queue — long after the test
    /// that triggered it finished, where an ObjC exception from it surfaced as an
    /// unrelated test failing intermittently. Delivery is therefore skipped in
    /// tests; the state transitions that lead to a notification are asserted
    /// directly instead.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Posts a session-attention banner.
    ///
    /// It does not ask for permission: macOS shows that prompt exactly once, and
    /// asking for it here meant it appeared at whatever moment an agent finished
    /// — or, if it had already been dismissed, never again, with every later
    /// notification dropped silently. Permission is asked for at launch and from
    /// Settings; an unauthorised post is simply discarded by the system, and
    /// Settings is where the user finds out why.
    static func post(
        title: String,
        body: String,
        projectID: UUID,
        prefs: NotificationPrefs,
        sessionID: UUID? = nil,
        dispatch: NotificationDispatch? = nil
    ) {
        guard !isRunningTests else { return }
        guard prefs.isEnabled(project: projectID) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = dispatch?.isReminder == true ? "\(body) · reminder" : body
        content.interruptionLevel = (dispatch?.priority ?? prefs.priority(project: projectID))
            .interruptionLevel
        if prefs.groupByProject {
            content.threadIdentifier = projectID.uuidString
        }
        // Tapping the banner opens the session it is about; the delegate reads
        // this the same way it does for permission banners.
        if let sessionID {
            content.userInfo = ["session_id": sessionID.uuidString]
            content.categoryIdentifier = PermissionNotificationPolicy.sensitiveCategory
        }
        switch dispatch?.sound ?? prefs.sound(project: projectID) {
        case "none":
            break
        case "default":
            content.sound = .default
        case let name:
            content.sound = UNNotificationSound(
                named: UNNotificationSoundName("\(name).aiff")
            )
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }
}
