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

/// Keeps every Uncoil window a window of its own.
@MainActor
enum WindowTabbing {
    static func untab(_ window: NSWindow) {
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        // A window that already ended up in a tab group (merged before this
        // build, or by a path that ignored the mode) is split back out.
        if let tabs = window.tabbedWindows, tabs.count > 1 {
            for other in tabs where other !== window {
                other.tabbingMode = .disallowed
                other.moveTabToNewWindow(nil)
            }
        }
    }
}

@MainActor
final class UncoilApplicationDelegate: NSObject, NSApplicationDelegate {
    private var tabObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Uncoil is several windows, never one window with tabs. With the
        // system's "Prefer tabs" setting (or Window › Merge All Windows) macOS
        // would otherwise fold new windows into a tab bar on top of the
        // sidebar. Turning automatic tabbing off also removes the tab items
        // from the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        tabObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowTabbing.untab(window) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows { WindowTabbing.untab(window) }
        let info = Bundle.main.infoDictionary
        AppLog.log(.app, "launch Uncoil \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Task.detached(priority: .utility) {
            for name in ["claude", "codex"] {
                let found = SettingsStore.which(name)
                AppLog.log(.usage, "launch: \(name) → \(found ?? "not found") (fixed list: \(BinarySearchPath.locate(name) ?? "no"))")
            }
            AppLog.log(.usage, "launch: login shell PATH has \(SettingsStore.interactivePATH.count) entries")
        }
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
