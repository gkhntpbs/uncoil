import AppKit
import Foundation

@MainActor
final class ApplicationLifecycle {
    static let shared = ApplicationLifecycle()

    var sessionQuitBehavior: SessionQuitBehavior = .keepSessionsRunning

    private init() {}
}

@MainActor
final class UncoilApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The notification delegate has to be installed before anything can be
        // delivered, or a banner that arrives while Uncoil is frontmost is
        // swallowed by the system default. Permission is read here and asked for
        // once, deliberately, rather than from inside whichever notification
        // happened to be first.
        PermissionNotificationCenter.shared.activate()
        NotificationSelfTest.runIfRequested()
        Task {
            await NotificationAuthorization.shared.refresh()
            if NotificationAuthorization.shared.status.canRequest {
                await NotificationAuthorization.shared.request()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let terminateSessions =
            ApplicationLifecycle.shared.sessionQuitBehavior == .terminateAllAgents
        TerminalRegistry.shared.prepareForApplicationTermination(
            terminateSessions: terminateSessions
        )
        RuntimeClient.shared.prepareForApplicationTermination(
            terminateSessions: terminateSessions
        )
        return .terminateNow
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            let existing = sender.windows
                .first { $0.title == "Uncoil" || $0.identifier?.rawValue == "main" }
            if let existing {
                existing.makeKeyAndOrderFront(nil)
            } else if let command = newWindowCommand(in: sender.mainMenu),
                      let action = command.action {
                sender.sendAction(
                    action,
                    to: command.target,
                    from: command
                )
            }
        }
        sender.activate()
        return true
    }

    private func newWindowCommand(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent.lowercased() == "n",
               item.keyEquivalentModifierMask.contains(.command),
               item.action != nil {
                return item
            }
            if let match = newWindowCommand(in: item.submenu) {
                return match
            }
        }
        return nil
    }
}
