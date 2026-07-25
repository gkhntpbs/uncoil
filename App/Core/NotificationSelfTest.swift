import AppKit
import Foundation
import UserNotifications

/// Answers "do notifications actually arrive?" without a human watching for a
/// banner.
///
/// Notification delivery cannot be asserted from the unit-test host — the
/// framework is unusable there — and a banner is not something a test can see.
/// So the app can be asked to check itself: `-notification-selftest` reads the
/// authorization state, posts one notification, and reports what the system
/// says was delivered, on stdout, then exits.
@MainActor
enum NotificationSelfTest {
    static func runIfRequested() {
        guard LaunchConfig.shared.notificationSelfTest else { return }
        Task {
            let authorization = NotificationAuthorization.shared
            await authorization.refresh()
            report("status=\(authorization.status)")

            if authorization.status.canRequest {
                report("requesting authorization…")
                await authorization.request()
                report("status-after-request=\(authorization.status)")
            }

            guard authorization.status.canDeliver else {
                report(
                    "cannot deliver: macOS has not authorised Uncoil "
                        + "(\(authorization.status.label))"
                )
                NSApp.terminate(nil)
                return
            }

            await authorization.sendTestNotification()
            report("posted test notification")

            // Delivery is asynchronous; the system needs a moment before it will
            // admit to holding the notification.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            report("delivered=\(delivered.count)")
            for notification in delivered.prefix(5) {
                let content = notification.request.content
                report("- \(content.title): \(content.body)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func report(_ line: String) {
        print("[notification-selftest] \(line)")
        fflush(stdout)
    }
}
