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
            "-ui-testing", "-reset-state",
            "-fixture", "demo",
            "-window-width", "1100", "-window-height", "720",
            "-disable-animations",
        ]
        app.launch()
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
        let terminal = app.descendants(matching: .any)["session.splitGroup"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal did not appear")

        // 4. Back to the dashboard.
        let backButton = app.descendants(matching: .any)["session.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.click()
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5), "Back navigation failed")

        let sessionRow = app.descendants(matching: .any)["dashboard.session.claude: demo görev"]
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

    func testClosedSessionHistoryCanBeResumed() {
        let history = app.descendants(matching: .any)["dashboard.sessionHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))

        let closedSession = app.descendants(matching: .any)[
            "dashboard.session.codex: geçmiş görev"
        ]
        for _ in 0..<4 where !closedSession.exists {
            app.descendants(matching: .any)["dashboard.container"].swipeUp()
        }
        XCTAssertTrue(closedSession.waitForExistence(timeout: 5))
        closedSession.click()

        let terminal = app.descendants(matching: .any)["session.splitGroup"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
    }

    func testPresetAndTranscriptSettingsAreAvailable() {
        let settingsButton = app.descendants(matching: .any)["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        let agentBehavior = app.descendants(matching: .any)["settings.pane.agentBehavior"]
        XCTAssertTrue(agentBehavior.waitForExistence(timeout: 10))
        agentBehavior.click()

        let addPreset = app.descendants(matching: .any)["settings.presets.add"]
        for _ in 0..<5 where !addPreset.exists {
            app.windows["Uncoil Ayarları"].swipeUp()
        }
        XCTAssertTrue(addPreset.waitForExistence(timeout: 5))
        addPreset.click()

        let presetID = app.descendants(matching: .any)["settings.presets.editor.id"]
        let savePreset = app.descendants(matching: .any)["settings.presets.editor.save"]
        XCTAssertTrue(presetID.waitForExistence(timeout: 5))
        XCTAssertTrue(savePreset.exists)
        app.typeKey(.escape, modifierFlags: [])

        let retention = app.descendants(matching: .any)["settings.transcripts.retention"]
        for _ in 0..<5 where !retention.exists {
            app.windows["Uncoil Ayarları"].swipeUp()
        }
        XCTAssertTrue(retention.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.transcripts.clear"].exists
        )
    }

    func testQuitBehaviorOptionsAreAvailable() {
        let settingsButton = app.descendants(matching: .any)["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        let agentBehavior = app.descendants(matching: .any)["settings.pane.agentBehavior"]
        XCTAssertTrue(agentBehavior.waitForExistence(timeout: 10))
        agentBehavior.click()

        let keepRunning = app.descendants(matching: .any)[
            "settings.agentBehavior.quit.keepSessionsRunning"
        ]
        let terminateAll = app.descendants(matching: .any)[
            "settings.agentBehavior.quit.terminateAllAgents"
        ]
        XCTAssertTrue(keepRunning.waitForExistence(timeout: 5))
        XCTAssertTrue(terminateAll.waitForExistence(timeout: 5))
        XCTAssertEqual(keepRunning.value as? String, "selected")
        terminateAll.click()
        XCTAssertEqual(terminateAll.value as? String, "selected")
    }

    func testNewWindowCommandRestoresClosedMainWindow() {
        let mainWindow = app.windows["Uncoil"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 5))

        app.typeKey("n", modifierFlags: .command)

        XCTAssertTrue(
            app.windows["Uncoil"].waitForExistence(timeout: 10),
            "The new-window command did not recreate the main window"
        )
    }

    func testSessionPopoutFromContextMenu() {
        let sessionRow = app.descendants(matching: .any)["sidebar.session.terminal"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 10))
        sessionRow.rightClick()
        let popoutAction = app.menuItems["Yeni Pencerede Aç"]
        XCTAssertTrue(popoutAction.waitForExistence(timeout: 5))
        popoutAction.click()

        let popout = app.windows["Oturum"]
        XCTAssertTrue(popout.waitForExistence(timeout: 10), "Session popout window did not appear")
    }

    func testDragSessionCreatesSplitPane() {
        let primary = app.descendants(matching: .any)["dashboard.session.terminal"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        primary.click()

        let container = app.descendants(matching: .any)["session.splitGroup"]
        XCTAssertTrue(container.waitForExistence(timeout: 10))

        let secondary = app.descendants(matching: .any)["sidebar.drag.claude: demo görev"]
        XCTAssertTrue(secondary.waitForExistence(timeout: 5))
        secondary.press(forDuration: 0.5, thenDragTo: container)

        let splitPane = app.descendants(matching: .any)["session.splitPane"]
        XCTAssertTrue(splitPane.waitForExistence(timeout: 10), "Split session pane did not appear")
    }

    func testCodexStructuredApprovalPanelCanBeResolved() {
        app.terminate()
        app.launchArguments.append("-codex-approval-fixture")
        app.launch()

        let launcher = app.descendants(matching: .any)["launcher.codex"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
        launcher.click()

        let panel = app.descendants(matching: .any)["session.codexApproval"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["session.codexApproval.accept"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["session.codexApproval.session"].exists
        )
        let decline = app.descendants(matching: .any)["session.codexApproval.decline"]
        XCTAssertTrue(decline.exists)
        decline.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }
}
