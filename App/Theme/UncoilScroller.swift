import AppKit
import SwiftUI

/// Thin, dark, understated scroller matching the Uncoil surface.
final class UncoilScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        let isVertical = knobRect.height >= knobRect.width
        let thickness: CGFloat = 4
        let drawRect: NSRect
        if isVertical {
            drawRect = NSRect(
                x: knobRect.midX - thickness / 2,
                y: knobRect.minY + 2,
                width: thickness,
                height: max(20, knobRect.height - 4)
            )
        } else {
            drawRect = NSRect(
                x: knobRect.minX + 2,
                y: knobRect.midY - thickness / 2,
                width: max(20, knobRect.width - 4),
                height: thickness
            )
        }
        let path = NSBezierPath(roundedRect: drawRect, xRadius: thickness / 2, yRadius: thickness / 2)
        NSColor(white: 1, alpha: 0.16).setFill()
        path.fill()
    }

    // No track — the knob floats on the surface.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Drop into a scrolling surface's content (`.uncoilScrollers()`) to restyle the
/// enclosing NSScrollView.
///
/// The probe re-applies on every update, not only at creation: SwiftUI rebuilds
/// `Form`, `List` and `ScrollView` bodies freely, and a scroll view that was
/// styled once can come back with AppKit's own scrollers after a rebuild. The
/// work is a couple of identity checks when nothing changed.
struct ScrollerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { Self.style(probe.enclosingScrollView) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.style(nsView.enclosingScrollView) }
    }

    static func style(_ scrollView: NSScrollView?) {
        guard let scrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is UncoilScroller) {
            scrollView.verticalScroller = makeScroller()
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is UncoilScroller) {
            scrollView.horizontalScroller = makeScroller()
        }
    }

    private static func makeScroller() -> UncoilScroller {
        let scroller = UncoilScroller()
        scroller.controlSize = .small
        return scroller
    }
}

extension View {
    /// Applies the Uncoil scroller style to the nearest enclosing ScrollView.
    func uncoilScrollers() -> some View {
        background(ScrollerStyler())
    }
}

/// Restyles every `NSScrollView` in a window, however it was created.
///
/// `ScrollerStyler` only reaches the scroll view it is planted inside, and a
/// probe placed in a `Form` or a `List` row may never be laid out — which is
/// how the settings pages and several panels kept AppKit's own scrollers
/// despite carrying the modifier. Sweeping the window's view tree does not care
/// where a scroll view came from: SwiftUI, an `NSViewRepresentable`, or a
/// `TextEditor`'s private hosting view.
///
/// AppKit rebuilds scrollers when the scroller-style preference changes and when
/// SwiftUI recreates a body, so one sweep at launch is not enough; this re-runs
/// on the window events that follow those rebuilds.
@MainActor
enum WindowScrollerSweep {
    static func apply(in window: NSWindow?) {
        guard let root = window?.contentView else { return }
        walk(root)
    }

    private static func walk(_ view: NSView) {
        if let scrollView = view as? NSScrollView {
            ScrollerStyler.style(scrollView)
        }
        for subview in view.subviews { walk(subview) }
    }
}

private struct ScrollerSweeper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        context.coordinator.observe(probe)
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sweepSoon(nsView.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false

        func observe(_ probe: NSView) {
            // The window is not attached yet at make time, and content arrives
            // lazily after that, so the first sweeps are staggered rather than
            // done once.
            for delay in [0.0, 0.15, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak probe] in
                    WindowScrollerSweep.apply(in: probe?.window)
                }
            }
            let center = NotificationCenter.default
            for name: Notification.Name in [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification,
            ] {
                observers.append(center.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak probe] _ in
                    MainActor.assumeIsolated { WindowScrollerSweep.apply(in: probe?.window) }
                })
            }
            // Scroll bars appearing and disappearing is a system-wide setting;
            // when it flips, AppKit hands every scroll view a fresh scroller.
            observers.append(center.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak probe] _ in
                MainActor.assumeIsolated { WindowScrollerSweep.apply(in: probe?.window) }
            })
        }

        /// Coalesces the sweeps a burst of view updates would otherwise cause.
        func sweepSoon(_ window: NSWindow?) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                self?.scheduled = false
                WindowScrollerSweep.apply(in: window)
            }
        }

        deinit {
            let center = NotificationCenter.default
            for observer in observers { center.removeObserver(observer) }
        }
    }
}

extension View {
    /// Keeps every scroll view in this window on Uncoil's scroller, including
    /// the ones no call site can reach.
    func sweepScrollers() -> some View {
        background(ScrollerSweeper().frame(width: 0, height: 0))
    }
}
