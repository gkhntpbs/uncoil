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

    func testExtensionsWindowOpensFromCommandPaletteAndNavigates() {
        app.typeKey("k", modifierFlags: .command)
        app.typeText("extensions")

        let result = app.staticTexts["Extensions"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()

        let extensions = app.descendants(matching: .any)["extensions.container"]
        XCTAssertTrue(extensions.waitForExistence(timeout: 10))

        let skills = app.descendants(matching: .any)["extensions.section.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 5))
        skills.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["extensions.content.skills"]
                .waitForExistence(timeout: 5)
        )
    }

    func testAttentionCenterListsAndResolvesRows() {
        app.terminate()
        app.launchArguments.append("-attention-fixture")
        app.launch()

        let bell = app.descendants(matching: .any)["sidebar.attentionButton"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.click()

        let panel = app.descendants(matching: .any)["attention.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))

        let failure = app.descendants(matching: .any)["attention.item.test:fixture"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))

        app.descendants(matching: .any)["attention.resolve.test:fixture"].click()
        XCTAssertTrue(failure.waitForNonExistence(timeout: 5))
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

        // Presets and transcripts live on their own pages now: Agentlar →
        // Session Presetleri, and Gizlilik ve İzinler → Veri ve Transcript.
        let presetsPane = app.descendants(matching: .any)["settings.pane.presets"]
        XCTAssertTrue(presetsPane.waitForExistence(timeout: 10))
        presetsPane.click()

        let addPreset = app.descendants(matching: .any)["settings.presets.add"]
        XCTAssertTrue(addPreset.waitForExistence(timeout: 5))
        addPreset.click()

        let presetID = app.descendants(matching: .any)["settings.presets.editor.id"]
        let savePreset = app.descendants(matching: .any)["settings.presets.editor.save"]
        XCTAssertTrue(presetID.waitForExistence(timeout: 5))
        XCTAssertTrue(savePreset.exists)
        app.typeKey(.escape, modifierFlags: [])

        let dataPane = app.descendants(matching: .any)["settings.pane.privacyData"]
        XCTAssertTrue(dataPane.waitForExistence(timeout: 5))
        dataPane.click()

        let retention = app.descendants(matching: .any)["settings.transcripts.retention"]
        XCTAssertTrue(retention.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.transcripts.clear"].exists
        )
    }

    func testQuitBehaviorOptionsAreAvailable() {
        let settingsButton = app.descendants(matching: .any)["sidebar.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        // Quit behaviour moved to Genel, as an inline picker rather than two
        // hand-rolled radio rows.
        let general = app.descendants(matching: .any)["settings.pane.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.click()

        let quitPicker = app.descendants(matching: .any)["settings.agentBehavior.quit"]
        XCTAssertTrue(quitPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Keep sessions running"].exists)
        XCTAssertTrue(app.radioButtons["Terminate all agents on quit"].exists)
    }

    /// Switching multi-select on has to put a checkbox on every session row.
    /// The rows are hosted inside an outline view, so they are built once and
    /// keep what they were given: without an explicit rebuild the mode turned on
    /// and nothing about the rows changed.
    func testMultiSelectModePutsCheckboxesOnSessionRows() {
        let toggle = app.descendants(matching: .any)["sidebar.multiSelectButton"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))

        let checkbox = app.descendants(matching: .any)["sidebar.select.terminal"]
        XCTAssertFalse(checkbox.exists, "The checkbox is there before the mode is on")

        toggle.click()
        XCTAssertTrue(
            checkbox.waitForExistence(timeout: 5),
            "Turning multi-select on left the session rows without their checkboxes"
        )

        toggle.click()
        XCTAssertTrue(
            checkbox.waitForNonExistence(timeout: 5),
            "Turning multi-select off left the checkboxes behind"
        )
    }

    /// Selecting a session moves the sidebar's highlight to it. The row that had
    /// it has to give it up — it kept it while the rows were never rebuilt.
    func testSelectingASessionMovesTheSidebarHighlight() {
        let terminal = app.descendants(matching: .any)["sidebar.session.terminal"]
        let claude = app.descendants(matching: .any)["sidebar.session.claude: demo görev"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(claude.waitForExistence(timeout: 5))

        terminal.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["session.splitGroup"].waitForExistence(timeout: 10),
            "Clicking a sidebar session did not open it"
        )
        XCTAssertTrue(terminal.isSelected, "The clicked row is not marked as selected")

        claude.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["session.splitGroup"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(claude.isSelected)
        XCTAssertFalse(
            terminal.isSelected,
            "The row that lost the selection kept its highlight"
        )
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
        let popoutAction = app.menuItems["Open in a New Window"]
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
