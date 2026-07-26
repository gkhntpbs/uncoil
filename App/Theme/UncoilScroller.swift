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
