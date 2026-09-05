import XCTest
@testable import Uncoil

/// Which windows exist and how to reach one was a bare string at a dozen call
/// sites, and two of them matched it by substring or by window title. Matching
/// the title is what made the command palette open over Settings the moment the
/// interface language stopped being English.
final class AppWindowTests: XCTestCase {
    func testTheIdsAreTheSceneIdsTheAppDeclares() {
        XCTAssertEqual(AppWindow.main.rawValue, "main")
        XCTAssertEqual(AppWindow.session.rawValue, "session-window")
        XCTAssertEqual(AppWindow.settings.rawValue, "settings")
        XCTAssertEqual(AppWindow.extensions.rawValue, "extensions")
    }

    func testEveryWindowIdIsDistinct() {
        let ids = AppWindow.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The palette may open over the shell and must not open over the windows
    /// the shell put beside it.
    func testOnlyTheShellIsNotAuxiliary() {
        XCTAssertFalse(AppWindow.main.isAuxiliary)
        for window in AppWindow.allCases where window != .main {
            XCTAssertTrue(window.isAuxiliary, "\(window) sits beside the shell")
        }
    }

    @MainActor
    func testAWindowIsRecognisedByItsSceneIdNotItsTitle() {
        let window = NSWindow()
        window.title = "Ayarlar"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        XCTAssertEqual(AppWindow.of(window), .settings)

        // A value-presented scene suffixes its id with the value, which is why
        // the match is a prefix rather than equality.
        window.identifier = NSUserInterfaceItemIdentifier("session-window-\(UUID().uuidString)")
        XCTAssertEqual(AppWindow.of(window), .session)

        window.identifier = NSUserInterfaceItemIdentifier("something-else")
        XCTAssertNil(AppWindow.of(window))
        XCTAssertNil(AppWindow.of(nil))
    }
}
