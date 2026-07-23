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

/// Drop into a ScrollView's content (`.background(ScrollerStyler())`) to
/// restyle the enclosing NSScrollView with Uncoil scrollers.
struct ScrollerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async {
            guard let scrollView = probe.enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            if !(scrollView.verticalScroller is UncoilScroller) {
                let scroller = UncoilScroller()
                scroller.controlSize = .small
                scrollView.verticalScroller = scroller
            }
            if !(scrollView.horizontalScroller is UncoilScroller) {
                let scroller = UncoilScroller()
                scroller.controlSize = .small
                scrollView.horizontalScroller = scroller
            }
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Applies the Uncoil scroller style to the nearest enclosing ScrollView.
    func uncoilScrollers() -> some View {
        background(ScrollerStyler())
    }
}
