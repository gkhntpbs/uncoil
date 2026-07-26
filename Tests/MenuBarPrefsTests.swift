import XCTest
@testable import Uncoil

/// What the menu bar draws: which counters make it into the label, which icon
/// the style resolves to, and when the item hides itself entirely.
final class MenuBarPrefsTests: XCTestCase {
    private func summary(
        running: Int = 0,
        permission: Int = 0,
        input: Int = 0,
        problems: Int = 0,
        tasksRunning: Int = 0
    ) -> MenuBarSummary {
        var value = MenuBarSummary()
        value.running = running
        value.waitingPermission = permission
        value.waitingInput = input
        value.problems = problems
        value.tasks.running = tasksRunning
        return value
    }

    func testDefaultLabelCountsRunningWaitingAndProblems() {
        let prefs = MenuBarPrefs()
        let label = prefs.label(for: summary(running: 3, permission: 2, problems: 1))
        XCTAssertEqual(label, "3 2! 1×")
    }

    func testWaitingCountsPermissionAndInputTogether() {
        let prefs = MenuBarPrefs()
        XCTAssertEqual(prefs.label(for: summary(permission: 1, input: 2)), "3!")
    }

    func testZeroCountersAreLeftOutEntirely() {
        let prefs = MenuBarPrefs()
        XCTAssertEqual(prefs.label(for: summary()), "")
        XCTAssertEqual(prefs.label(for: summary(running: 2)), "2")
    }

    func testDeselectedCountersDisappear() {
        var prefs = MenuBarPrefs()
        prefs.set(.running, enabled: false)
        prefs.set(.problems, enabled: false)
        XCTAssertEqual(prefs.label(for: summary(running: 3, permission: 2, problems: 1)), "2!")

        for counter in MenuBarPrefs.Counter.allCases {
            prefs.set(counter, enabled: false)
        }
        XCTAssertEqual(prefs.label(for: summary(running: 3, permission: 2, problems: 1)), "")
    }

    func testTaskCounterIsOptInAndReadsTheTaskTotals() {
        var prefs = MenuBarPrefs()
        XCTAssertFalse(prefs.shows(.tasks))
        prefs.set(.tasks, enabled: true)
        XCTAssertEqual(prefs.label(for: summary(tasksRunning: 4)), "4⏱")
    }

    func testIconStyleResolution() {
        var prefs = MenuBarPrefs()
        let waiting = summary(permission: 1)

        XCTAssertEqual(prefs.icon(for: waiting), .asset(MenuBarSummary.Icon.waiting.rawValue))

        prefs.monochrome = true
        XCTAssertEqual(prefs.icon(for: waiting), .asset(MenuBarSummary.Icon.idle.rawValue))

        prefs.iconStyle = .symbol
        XCTAssertEqual(prefs.icon(for: waiting), .symbol(MenuBarSummary.Icon.waiting.symbolName))

        prefs.iconStyle = .countOnly
        XCTAssertEqual(prefs.icon(for: waiting), MenuBarIcon.none)
    }

    func testHideWhenIdleOnlyHidesAnActuallyIdleMenuBar() {
        var prefs = MenuBarPrefs()
        prefs.hideWhenIdle = true

        XCTAssertFalse(prefs.isVisible(for: summary()))
        XCTAssertTrue(prefs.isVisible(for: summary(running: 1)))
        XCTAssertTrue(prefs.isVisible(for: summary(permission: 1)))

        prefs.hideWhenIdle = false
        XCTAssertTrue(prefs.isVisible(for: summary()))

        prefs.enabled = false
        XCTAssertFalse(prefs.isVisible(for: summary(running: 5)))
    }

    func testDecodesFromAnEmptyObject() throws {
        // Same reason as NotificationPrefs: a settings.json written before this
        // key existed must not fail the whole decode.
        let prefs = try JSONDecoder().decode(
            MenuBarPrefs.self, from: "{}".data(using: .utf8)!
        )
        XCTAssertEqual(prefs, MenuBarPrefs())
    }

    func testRoundTrip() throws {
        var prefs = MenuBarPrefs()
        prefs.iconStyle = .symbol
        prefs.hideWhenIdle = true
        prefs.showQuickLaunch = false
        prefs.set(.tasks, enabled: true)

        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarPrefs.self, from: data), prefs)
    }
}

/// The settings tree itself: every pane is reachable, deep links still resolve,
/// and search finds settings by the words a user would type.
final class SettingsNavigationTests: XCTestCase {
    func testEveryPaneBelongsToACategoryThatListsIt() {
        for pane in SettingsView.Pane.allCases {
            XCTAssertTrue(
                pane.category.panes.contains(pane),
                "\(pane.rawValue) is not listed by \(pane.category.rawValue)"
            )
        }
    }

    func testEveryCategoryHasAtLeastOnePane() {
        for category in SettingsView.Category.allCases {
            XCTAssertFalse(category.panes.isEmpty, "\(category.rawValue) is empty")
        }
    }

    func testLegacyDeepLinksStillResolve() {
        // Written by older builds of the command palette.
        XCTAssertEqual(SettingsView.Pane.resolve("defaults"), .general)
        XCTAssertEqual(SettingsView.Pane.resolve("transcripts"), .privacyData)
        XCTAssertEqual(SettingsView.Pane.resolve("agentBehavior"), .agentBehavior)
        XCTAssertEqual(SettingsView.Pane.resolve("notifications"), .notifications)
        XCTAssertNil(SettingsView.Pane.resolve("nope"))
    }

    func testSearchFindsPanesByWhatTheSettingIsCalled() {
        func search(_ query: String) -> [SettingsView.Pane] {
            SettingsView.Pane.allCases.filter { $0.searchText.contains(query.lowercased()) }
        }
        XCTAssertTrue(search("hatırlatma").contains(.reminders))
        XCTAssertTrue(search("ikinci kez").contains(.reminders))
        XCTAssertTrue(search("menü").contains(.menuBar))
        XCTAssertTrue(search("ikon").contains(.menuBar))
        XCTAssertTrue(search("sessiz").contains(.quietHours))
        XCTAssertTrue(search("editor").contains(.general))
        XCTAssertTrue(search("transcript").contains(.privacyData))
        XCTAssertTrue(search("computer use").contains(.permissions))
        XCTAssertTrue(search("zzzz").isEmpty)
    }
}
