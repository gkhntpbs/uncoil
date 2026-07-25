import Foundation
import UserNotifications
import AppKit

/// Notification preferences: global defaults + per-project overrides.
struct NotificationPrefs: Codable, Equatable {
    enum Priority: String, Codable, CaseIterable, Identifiable {
        case low      // passive: no banner interruption
        case normal   // active
        case high     // time sensitive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .low: "Düşük"
            case .normal: "Normal"
            case .high: "Yüksek"
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

    struct ProjectOverride: Codable, Equatable {
        var enabled: Bool?
        var priority: Priority?
        var sound: String?
    }

    var enabled = true
    var notifyPermission = true
    var notifyInput = true
    var notifyTurnCompleted = true
    var priority: Priority = .normal
    /// "default", "none", or a system sound name (Glass, Ping, …).
    var sound = "default"
    var perProject: [UUID: ProjectOverride] = [:]

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

    /// System alert sounds available for picking.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static func preview(sound: String) {
        guard sound != "default", sound != "none" else { return }
        NSSound(named: sound)?.play()
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
        sessionID: UUID? = nil
    ) {
        guard !isRunningTests else { return }
        guard prefs.isEnabled(project: projectID) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = prefs.priority(project: projectID).interruptionLevel
        // Tapping the banner opens the session it is about; the delegate reads
        // this the same way it does for permission banners.
        if let sessionID {
            content.userInfo = ["session_id": sessionID.uuidString]
        }
        switch prefs.sound(project: projectID) {
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
