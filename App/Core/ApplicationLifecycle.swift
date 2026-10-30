import AppKit
import Foundation
import Combine

@MainActor
final class ApplicationLifecycle: ObservableObject {
    static let shared = ApplicationLifecycle()

    var sessionQuitBehavior: SessionQuitBehavior = .keepSessionsRunning

    @Published var isInBackground = false
    var quitCompletely = false

    func continueInBackground() {
        isInBackground = true
        NSApp.hide(nil)
    }

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

    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateCancel }
        let lifecycle = ApplicationLifecycle.shared
        let quitCompletely = lifecycle.quitCompletely
        var stopEverything = quitCompletely
        lifecycle.quitCompletely = false
        if !stopEverything, !RunRegistry.shared.activeRuns.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Project processes are still running")
            alert.informativeText = String(localized: "You can keep Uncoil in the menu bar, quit using each run's setting, or stop all project processes before quitting. Agent sessions follow your separate quit setting.")
            alert.addButton(withTitle: String(localized: "Quit Using Run Settings"))
            alert.addButton(withTitle: String(localized: "Keep Uncoil in Menu Bar"))
            alert.addButton(withTitle: String(localized: "Stop All and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn:
                lifecycle.continueInBackground()
                return .terminateCancel
            case .alertThirdButtonReturn: stopEverything = true
            default: return .terminateCancel
            }
        }
        terminationPending = true
        Task { @MainActor in
            let stopped = await RunRegistry.shared.prepareForQuit(stopEverything: stopEverything)
            guard stopped else {
                terminationPending = false
                let alert = NSAlert()
                alert.messageText = String(localized: "Some project processes have not stopped yet")
                alert.informativeText = String(localized: "Uncoil will stay open so you can inspect and stop them from the menu bar.")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let terminateSessions = quitCompletely || lifecycle.sessionQuitBehavior == .terminateAllAgents
            TerminalRegistry.shared.prepareForApplicationTermination(terminateSessions: terminateSessions)
            RuntimeClient.shared.prepareForApplicationTermination(terminateSessions: terminateSessions)
            RunRegistry.shared.disconnectSupervisor(shutdown: stopEverything || RunRegistry.shared.activeRuns.isEmpty)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ApplicationLifecycle.shared.isInBackground = false
        if !flag {
            let existing = sender.windows.first { AppWindow.of($0) == .main }
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
