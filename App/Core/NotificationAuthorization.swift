import AppKit
import Foundation
import UserNotifications

/// macOS notification permission, as something the user can see and act on.
///
/// Authorization used to be asked for from inside every post, on a background
/// queue, at whatever moment an agent happened to finish. macOS only ever shows
/// that prompt once: if it was missed or refused, every later notification was
/// dropped in silence with nothing in the app to say so. Permission is now asked
/// for deliberately, and its state is something Settings can show.
@MainActor
final class NotificationAuthorization: ObservableObject {
    static let shared = NotificationAuthorization()

    enum Status: Equatable {
        /// Not looked up yet.
        case unknown
        /// macOS has never asked — the prompt is still available.
        case notRequested
        case granted
        /// Quiet delivery only: banners are off, Notification Center still gets them.
        case provisional
        /// Refused. macOS will not ask again; only System Settings can undo it.
        case denied

        var label: String {
            switch self {
            case .unknown: String(localized: "Unknown")
            case .notRequested: String(localized: "Not asked yet")
            case .granted: String(localized: "Allowed")
            case .provisional: String(localized: "Silent delivery")
            case .denied: String(localized: "Denied")
            }
        }

        /// Whether a notification posted now can reach the user.
        var canDeliver: Bool {
            self == .granted || self == .provisional
        }

        /// Whether asking is still possible; once refused, only System Settings
        /// can change the answer.
        var canRequest: Bool {
            self == .notRequested || self == .unknown
        }

        init(_ status: UNAuthorizationStatus) {
            switch status {
            case .notDetermined: self = .notRequested
            case .authorized: self = .granted
            case .provisional: self = .provisional
            case .denied: self = .denied
            @unknown default: self = .unknown
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    /// What went wrong the last time permission was asked for, if anything.
    @Published private(set) var lastError: String?
    /// Set after a test notification is handed to macOS, so Settings can say so.
    @Published private(set) var lastTestSentAt: Date?

    private init() {}

    /// Reads the current state. Safe to call often; it asks the system, not a
    /// cached copy, because the user can change it in System Settings at any
    /// time without the app hearing about it.
    func refresh() async {
        guard !AttentionNotifier.isRunningTests else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = Status(settings.authorizationStatus)
    }

    /// Shows the system prompt, once. Does nothing after a refusal — macOS
    /// silently drops the second ask, which would look like a dead button.
    @discardableResult
    func request() async -> Bool {
        guard !AttentionNotifier.isRunningTests else { return false }
        lastError = nil
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
            if !granted, status == .denied {
                lastError = "Permission denied. You can turn it on in System Settings."
            }
            return granted
        } catch {
            lastError = error.localizedDescription
            await refresh()
            return false
        }
    }

    /// Opens the Notifications pane of System Settings, scrolled to Uncoil when
    /// macOS honours the bundle id.
    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.gkhntpbs.uncoil"
        let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                + "?id=\(bundleID)"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Delivers a notification the user asked for, so "do notifications work
    /// here?" has an answer that does not involve waiting for an agent.
    func sendTestNotification() async {
        guard !AttentionNotifier.isRunningTests else { return }
        await refresh()
        if status.canRequest {
            await request()
        }
        let content = UNMutableNotificationContent()
        content.title = "Uncoil"
        content.body = "Notifications work. This is how it looks when an agent is waiting for input."
        content.sound = .default
        content.interruptionLevel = .active
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "uncoil.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
        lastTestSentAt = .now
    }
}
