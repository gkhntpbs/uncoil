import AppKit
import XCTest
@testable import Uncoil

@MainActor
final class WindowMaximizeTests: XCTestCase {
    func testMaximizeUsesVisibleScreenAndRestoresOriginalFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let original = NSRect(x: screen.visibleFrame.minX + 40,
                              y: screen.visibleFrame.minY + 40, width: 900, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: original.size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false, screen: screen)
        window.setFrameOrigin(original.origin)
        let originalFrame = window.frame
        let coordinator = TitlebarControls.Coordinator(onOpenPalette: {})
        coordinator.toggleMaximize(window)
        XCTAssertEqual(window.frame, screen.visibleFrame)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        coordinator.toggleMaximize(window)
        XCTAssertEqual(window.frame, originalFrame)
    }
}
