import XCTest

/// End-to-end smoke flow against the deterministic "demo" fixture.
/// Launch args isolate all state under a temp directory — the user's real
/// projects/settings are never touched.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-control-plane", "-reset-state",
            "-fixture", "demo",
            "-route", "project",
            "-window-width", "1100", "-window-height", "720",
            "-disable-animations",
        ]
        app.launch()
        app.activate()
    }

    override func tearDown() {
        app.terminate()
    }

    func testSmokeFlow_dashboard_session_and_back() {
        // 1. Launch: fixture project visible in sidebar, dashboard auto-selected.
        let projectRow = app.descendants(matching: .any)["sidebar.project.demo-project"]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10), "Fixture project missing in sidebar")

        let dashboard = app.descendants(matching: .any)["dashboard.container"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10), "Dashboard not shown on launch")

        // 2. Fixture sessions listed on the dashboard.
        let sessionCard = app.descendants(matching: .any)["dashboard.session.terminal"]
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 5), "Fixture session card missing")

        // 3. Open the (harmless, plain-shell) terminal session.
        sessionCard.click()
        let terminal = app.descendants(matching: .any)["session.container"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal did not appear")

        // 4. Back to the dashboard.
        let backButton = app.descendants(matching: .any)["session.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5), "Back navigation failed")

        // 5. Sidebar session row selects the session too.
        let sessionRow = app.descendants(matching: .any)["sidebar.session.terminal"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 5))
        sessionRow.click()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
    }

    func testSettingsWindowOpens() {
        let settingsButton = app.descendants(matching: .any)["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()
        let settings = app.descendants(matching: .any)["settings.container"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings window did not open")
    }
}
