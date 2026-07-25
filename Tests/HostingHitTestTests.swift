import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// The AppKit list migration needs to know exactly how much of the mouse a
/// hosted SwiftUI row takes: rows draw themselves in SwiftUI, but selection,
/// drags and the insertion point belong to the table view underneath. These are
/// probes of that boundary, kept as tests so a SwiftUI update that moves the
/// boundary shows up as a failure here rather than as a dead sidebar.
final class HostingHitTestTests: XCTestCase {
    private struct Probe: View {
        let onTap: () -> Void

        var body: some View {
            ZStack(alignment: .trailing) {
                Color.gray
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                Button("x", action: onTap)
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 200, height: 30)
        }
    }

    private final class RecordingView: NSView {
        var downs = 0
        override func mouseDown(with event: NSEvent) { downs += 1 }
    }

    private func host(onTap: @escaping () -> Void = {}) -> (RecordingView, NSView) {
        let host = NSHostingView(rootView: Probe(onTap: onTap))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        let container = RecordingView(frame: host.frame)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return (container, host)
    }

    /// A hosting view claims every point inside it, inert content or not — so
    /// hit testing alone cannot tell a row's controls from its background.
    func testHostingViewClaimsEvenInertContent() {
        let (_, hosted) = host()
        XCTAssertNotNil(hosted.hitTest(NSPoint(x: 20, y: 15)))
        XCTAssertNotNil(hosted.hitTest(NSPoint(x: 190, y: 15)))
    }

    /// …but it does not *keep* the click: an unhandled mouse-down travels up the
    /// responder chain, which is what reaches the enclosing `NSOutlineView` and
    /// gives the sidebar native selection, keyboard navigation and drags while
    /// its rows stay ordinary interactive SwiftUI. This is the load-bearing
    /// assumption of the AppKit list migration.
    func testHostingViewForwardsUnhandledClicksUpTheResponderChain() {
        let (container, hosted) = host()
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 15),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        hosted.mouseDown(with: event)
        XCTAssertEqual(
            container.downs, 1,
            "A hosted row now swallows clicks; the sidebar's selection and drags "
                + "would stop working and rows would need frame-gated hit testing"
        )
    }
}
