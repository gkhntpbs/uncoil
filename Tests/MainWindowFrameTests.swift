import XCTest
@testable import Uncoil

/// The saved main-window frame, and the corner bug it caused.
@MainActor
final class MainWindowFrameTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "UncoilMainWindowFrameTests"
    private let key = "NSWindow Frame UncoilMainWindow"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// What the menu-bar status item wrote: a 32×30 window at the top edge of
    /// the screen. Restoring it is what put the app in the corner.
    func testTheStatusItemsFrameIsDiscarded() {
        defaults.set("-634 1050 32 30 -1920 0 1920 1050 ", forKey: key)
        MainWindowFrame.forgetImplausibleFrame(defaults: defaults, key: key)
        XCTAssertNil(defaults.string(forKey: key))
    }

    func testARealWindowFrameIsKept() {
        let frame = "-634 418 940 632 -1920 0 1920 1050 "
        defaults.set(frame, forKey: key)
        MainWindowFrame.forgetImplausibleFrame(defaults: defaults, key: key)
        XCTAssertEqual(defaults.string(forKey: key), frame)
    }

    func testAnUnreadableFrameIsDiscardedRatherThanRestored() {
        defaults.set("bozuk", forKey: key)
        MainWindowFrame.forgetImplausibleFrame(defaults: defaults, key: key)
        XCTAssertNil(defaults.string(forKey: key))
    }

    func testNothingSavedIsLeftAlone() {
        MainWindowFrame.forgetImplausibleFrame(defaults: defaults, key: key)
        XCTAssertNil(defaults.string(forKey: key))
    }
}
