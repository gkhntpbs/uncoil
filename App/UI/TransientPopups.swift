import AppKit
import Combine
import SwiftUI

/// Keeps the app's transient popups — hover help, usage card, attention list,
/// run history — from stacking on each other or on other surfaces.
///
/// Each popover used to decide on its own, so a hover-help bubble could open
/// on top of an open menu, a sheet, the command palette or another popover,
/// and two help bubbles could be up at once. The rules here are few:
/// - one hover-help bubble at a time;
/// - hover help never opens while a menu, sheet, palette or other popover is up;
/// - a menu or sheet closes hover help; the palette or leaving the app closes
///   every transient popup.
@MainActor
final class TransientPopups: ObservableObject {
    static let shared = TransientPopups()

    /// Fires when every transient popup should close.
    let dismissAll = PassthroughSubject<Void, Never>()

    /// The hover-help bubble currently allowed to be open.
    @Published private(set) var activeHelp: UUID?

    /// Full-window overlays (the command palette) that are up right now.
    private var blockingOverlays = 0
    private var menuTracking = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Help only: a menu may live inside a popover (a picker in the
                // usage card), and opening it must not close its own popover.
                TransientPopups.shared.menuTracking += 1
                TransientPopups.shared.activeHelp = nil
            }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let shared = TransientPopups.shared
                shared.menuTracking = max(0, shared.menuTracking - 1)
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TransientPopups.shared.activeHelp = nil }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TransientPopups.shared.closeAll() }
        })
    }

    func closeAll() {
        activeHelp = nil
        dismissAll.send()
    }

    func overlayDidAppear() {
        blockingOverlays += 1
        closeAll()
    }

    func overlayDidDisappear() {
        blockingOverlays = max(0, blockingOverlays - 1)
    }

    /// Whether a hover-help bubble may open now; claims the single slot if so.
    func claimHelp(_ id: UUID) -> Bool {
        guard blockingOverlays == 0, menuTracking == 0 else { return false }
        let key = NSApp.keyWindow
        if key?.attachedSheet != nil { return false }
        // Another popover (usage card, attention list, run history) is open.
        if activeHelp == nil, Self.anyPopoverVisible() { return false }
        activeHelp = id
        return true
    }

    func releaseHelp(_ id: UUID) {
        if activeHelp == id { activeHelp = nil }
    }

    private static func anyPopoverVisible() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && String(describing: type(of: window)).contains("Popover")
        }
    }
}

extension View {
    /// Closes a popover bound to `isPresented` whenever transient popups are
    /// told to clear (palette opened, menu or sheet shown, app deactivated).
    func dismissWithTransientPopups(_ isPresented: Binding<Bool>) -> some View {
        onReceive(TransientPopups.shared.dismissAll) { _ in
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }
    }
}
