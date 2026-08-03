import XCTest
@testable import Uncoil

/// Every area used to be offered on every project, so a folder with nothing in
/// it showed five tabs, four of them onto empty pages. That was its own problem
/// and it caused another: the tab row is the widest thing in the project header,
/// and with five tabs the header's minimum width grew past the window's, which
/// pushed the sidebar off the left edge where it could not be reached.
final class ProjectAreaAvailabilityTests: XCTestCase {
    func testABareFolderOffersOnlyGeneral() {
        XCTAssertEqual(ProjectAreaAvailability.areas(ProjectAreaFacts()), [.overview])
    }

    func testEachAreaAppearsOnlyWhenItHasSomething() {
        XCTAssertEqual(
            ProjectAreaAvailability.areas(ProjectAreaFacts(hasTaskSources: true)),
            [.overview, .tasks]
        )
        XCTAssertEqual(
            ProjectAreaAvailability.areas(ProjectAreaFacts(hasRunConfigurations: true)),
            [.overview, .run]
        )
        XCTAssertEqual(
            ProjectAreaAvailability.areas(ProjectAreaFacts(hasTestSuites: true)),
            [.overview, .tests]
        )
        XCTAssertEqual(
            ProjectAreaAvailability.areas(ProjectAreaFacts(hasGitHubRepository: true)),
            [.overview, .issues]
        )
    }

    func testAFullyEquippedProjectShowsEveryTabInOrder() {
        let facts = ProjectAreaFacts(
            hasTaskSources: true, hasRunConfigurations: true,
            hasTestSuites: true, hasGitHubRepository: true
        )
        XCTAssertEqual(
            ProjectAreaAvailability.areas(facts),
            [.overview, .tasks, .run, .tests, .issues]
        )
    }

    /// What is missing is what General offers to set up, so a feature is never
    /// simply undiscoverable.
    func testWhatIsMissingIsWhatIsOffered() {
        let facts = ProjectAreaFacts(hasTaskSources: true)
        XCTAssertEqual(ProjectAreaAvailability.offers(facts), [.run, .tests, .issues])
        XCTAssertTrue(
            ProjectAreaAvailability.offers(
                ProjectAreaFacts(
                    hasTaskSources: true, hasRunConfigurations: true,
                    hasTestSuites: true, hasGitHubRepository: true
                )
            ).isEmpty
        )
    }

    /// An area can stop existing under the user — a TODO.md deleted, a remote
    /// removed — and the screen would otherwise sit on a tab that is gone.
    func testASelectedAreaThatDisappearsFallsBackToGeneral() {
        XCTAssertEqual(
            ProjectAreaAvailability.resolve(.tasks, facts: ProjectAreaFacts()), .overview
        )
        XCTAssertEqual(
            ProjectAreaAvailability.resolve(
                .tasks, facts: ProjectAreaFacts(hasTaskSources: true)
            ),
            .tasks
        )
    }

    /// Nothing in the app can give a folder a GitHub remote, so that offer
    /// explains rather than promising a button that cannot work.
    func testTheIssuesOfferIsNotActionable() {
        XCTAssertFalse(ProjectArea.issues.offerIsActionable)
        XCTAssertTrue(ProjectArea.run.offerIsActionable)
        XCTAssertTrue(ProjectArea.tests.offerIsActionable)
    }

    func testEveryOfferableAreaSaysWhatItIs() {
        for area in ProjectArea.allCases where area != .overview {
            XCTAssertFalse(area.offerTitle.isEmpty, area.rawValue)
            XCTAssertFalse(area.offerDetail.isEmpty, area.rawValue)
        }
    }
}

/// The quick-launch strip was every provider Uncoil knows, in declaration
/// order: agents that are not installed, in an order nobody chose.
final class LauncherPrefsTests: XCTestCase {
    private let installed: Set<AgentProvider> = [.claude, .codex]

    func testAnUnconfiguredStripOffersWhatIsInstalled() {
        let resolved = LauncherPrefs.resolved(.default, installed: installed)
        XCTAssertTrue(resolved.contains(.terminal))
        XCTAssertTrue(resolved.contains(.claude))
        XCTAssertTrue(resolved.contains(.codex))
        // Not installed: a button that could only fail.
        XCTAssertFalse(resolved.contains(.gemini))
    }

    /// A shell needs no CLI of its own, so it is always available even on a
    /// machine with no agent at all.
    func testWithNoAgentInstalledTheTerminalRemains() {
        XCTAssertEqual(LauncherPrefs.resolved(.default, installed: []), [.terminal])
    }

    func testAConfiguredOrderIsHonouredAsWritten() {
        let prefs = LauncherPrefs(order: [.codex, .terminal, .claude])
        XCTAssertEqual(
            LauncherPrefs.resolved(prefs, installed: installed), [.codex, .terminal, .claude]
        )
    }

    /// A chosen agent whose CLI has gone is left out of the strip — but the
    /// choice itself is kept, because a CLI can come back.
    func testAChosenAgentThatIsNoLongerInstalledIsLeftOut() {
        let prefs = LauncherPrefs(order: [.claude, .gemini])
        XCTAssertEqual(LauncherPrefs.resolved(prefs, installed: [.claude]), [.claude])
    }

    /// Everything the user chose is gone. Their first choice is kept rather
    /// than substituting one they never asked for, because an empty strip has
    /// no way to start a session at all.
    func testTheStripIsNeverEmptiedByAMissingCLI() {
        let prefs = LauncherPrefs(order: [.gemini])
        XCTAssertEqual(LauncherPrefs.resolved(prefs, installed: []), [.gemini])
    }

    func testADuplicateEntryIsShownOnce() {
        let prefs = LauncherPrefs(order: [.claude, .claude, .terminal])
        XCTAssertEqual(LauncherPrefs.resolved(prefs, installed: installed), [.claude, .terminal])
    }

    // MARK: - Editing

    func testTheLastShortcutCannotBeRemoved() {
        XCTAssertFalse(LauncherPrefs.canRemove(from: [.terminal]))
        XCTAssertEqual(LauncherPrefs.removing(.terminal, from: [.terminal]), [.terminal])
    }

    func testRemovingWorksWhileMoreThanOneRemains() {
        XCTAssertEqual(
            LauncherPrefs.removing(.terminal, from: [.claude, .terminal]), [.claude]
        )
    }

    func testAddingIsIdempotent() {
        XCTAssertEqual(LauncherPrefs.adding(.gemini, to: [.claude]), [.claude, .gemini])
        XCTAssertEqual(LauncherPrefs.adding(.claude, to: [.claude]), [.claude])
    }

    // MARK: - Reordering

    func testMovingAnEntryLater() {
        XCTAssertEqual(
            LauncherPrefs.moving(.claude, to: 2, in: [.claude, .codex, .terminal]),
            [.codex, .claude, .terminal]
        )
    }

    func testMovingAnEntryEarlier() {
        XCTAssertEqual(
            LauncherPrefs.moving(.terminal, to: 0, in: [.claude, .codex, .terminal]),
            [.terminal, .claude, .codex]
        )
    }

    /// Removing the entry first shifts everything after it left by one, so a
    /// drop past its old position lands one slot too far without the
    /// adjustment.
    func testADropPastTheOriginalPositionDoesNotOvershoot() {
        XCTAssertEqual(
            LauncherPrefs.moving(.claude, to: 3, in: [.claude, .codex, .gemini, .terminal]),
            [.codex, .gemini, .claude, .terminal]
        )
    }

    func testMovingSomethingNotInTheListChangesNothing() {
        XCTAssertEqual(
            LauncherPrefs.moving(.gemini, to: 0, in: [.claude, .terminal]),
            [.claude, .terminal]
        )
    }

    func testReorderingKeepsEveryEntry() {
        let order: [AgentProvider] = [.claude, .codex, .gemini, .terminal]
        for provider in order {
            for index in 0...order.count {
                let moved = LauncherPrefs.moving(provider, to: index, in: order)
                XCTAssertEqual(Set(moved), Set(order), "\(provider) → \(index)")
                XCTAssertEqual(moved.count, order.count, "\(provider) → \(index)")
            }
        }
    }
}
