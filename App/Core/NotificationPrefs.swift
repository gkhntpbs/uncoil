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
    static func post(
        title: String,
        body: String,
        projectID: UUID,
        prefs: NotificationPrefs
    ) {
        guard prefs.isEnabled(project: projectID) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.interruptionLevel = prefs.priority(project: projectID).interruptionLevel
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
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }
}
