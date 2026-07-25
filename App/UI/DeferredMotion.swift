import AppKit
import SwiftUI

/// Starts a never-ending animation only once the window is on screen.
///
/// A `repeatForever` animation — or a `TimelineView(.animation)` — that begins
/// during the app's very first render stops the window from ever being
/// presented: Uncoil launches, draws nothing, and spins. It is reproducible with
/// a session already waiting when the app starts (`-attention-fixture`), and it
/// goes away entirely with `-disable-animations`, which is what pinned the cause
/// down. Waiting a beat before the motion starts costs nothing anyone can see
/// and keeps the window's first presentation clear of it.
@MainActor
enum DeferredMotion {
    /// How often to look for a window, and for how long before giving up and
    /// animating anyway.
    static let pollInterval: Duration = .milliseconds(100)
    static let timeout: Duration = .seconds(5)

    static func start(_ begin: @escaping @MainActor () -> Void) {
        guard !LaunchConfig.shared.disableAnimations else { return }
        Task { @MainActor in
            await waitForVisibleWindow()
            begin()
        }
    }

    /// Waits for a real window to exist on screen. A fixed delay was not enough:
    /// the first presentation can take longer than any number worth guessing,
    /// and if the animation wins that race the window never arrives at all.
    private static func waitForVisibleWindow() async {
        var waited: Duration = .zero
        while waited < timeout {
            if NSApp.windows.contains(where: { $0.isVisible && $0.frame.height > 200 }) {
                return
            }
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
        }
    }
}
