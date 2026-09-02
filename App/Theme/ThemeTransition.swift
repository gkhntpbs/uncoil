import AppKit
import Foundation

/// The fade between one theme and the next.
///
/// A palette change repaints every surface in every window at once, and doing
/// it on a single frame reads as a glitch rather than as a setting taking
/// effect. This fades the content out, makes the change while nobody can see
/// it, and fades it back in.
///
/// It fades rather than cross-fades on purpose. A true cross-fade needs a
/// snapshot of the old content to hold on screen, and the only ways to take one
/// of a live window are `cacheDisplay`, which comes back blank for the
/// Metal-backed terminal views, and `CGWindowListCreateImage`, which asks the
/// user for screen-recording permission. A fade needs neither: it is one
/// property on a view the app already owns.
///
/// The whole change happens inside the completion handler, so a palette write,
/// a terminal repaint and a SwiftUI identity rebuild all land while the content
/// is invisible — which is also why the rebuild `ThemedWindow` performs is not
/// seen as a flash.
@MainActor
enum ThemeTransition {
    /// Seconds. Short enough not to be a wait, long enough that the eye reads
    /// it as one movement rather than two.
    static let fadeOut: TimeInterval = 0.11
    static let fadeIn: TimeInterval = 0.20

    /// Runs `change` between a fade out and a fade in.
    ///
    /// `change` is always called exactly once, even when there is nothing to
    /// fade or motion is turned off — this is a presentation detail wrapped
    /// around a setting, and the setting must not depend on it.
    static func fade(_ change: @escaping () -> Void) {
        let views = fadeableViews()
        guard !views.isEmpty, !prefersReducedMotion else {
            change()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for view in views { view.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                change()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeIn
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for view in views { view.animator().alphaValue = 1 }
                } completionHandler: {
                    MainActor.assumeIsolated {
                        // Belt and braces: an animation interrupted by another
                        // one — two quick appearance changes — must never leave
                        // a window sitting at alpha 0 with no way back.
                        for view in views { view.alphaValue = 1 }
                    }
                }
            }
        }
    }

    /// Content views worth fading: every window actually on screen, including
    /// the settings window the choice was made in. Leaving that one out was the
    /// first thing tried and it looked worse — the window doing the switching
    /// was the one window that hard-swapped.
    ///
    /// `occlusionState` matters: a window buried behind another is not animated,
    /// because AppKit does not run animations for occluded windows and the
    /// completion handler that restores alpha would be the only thing keeping
    /// it visible.
    private static func fadeableViews() -> [NSView] {
        (NSApp?.windows ?? [])
            .filter { $0.isVisible && $0.occlusionState.contains(.visible) }
            .compactMap(\.contentView)
    }

    /// Honours both the system's Reduce Motion and Uncoil's own
    /// `-disable-animations`, so a UI test never waits on a fade.
    private static var prefersReducedMotion: Bool {
        LaunchConfig.shared.disableAnimations
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
