import XCTest
@testable import Uncoil

/// Six singletons used to carry the user somewhere — a settings pane on one, an
/// Extensions screen on another, a project tab in a per-project dictionary on a
/// third — and no two had the same shape. These tests pin the one that replaced
/// them, and in particular the rule every one of the six had to get right on its
/// own: a request is answered once and then gone.
@MainActor
final class RouterTests: XCTestCase {
    private var router: Router!

    override func setUp() async throws {
        router = Router()
    }

    // MARK: - Selection

    func testAskingForASessionLeavesItToBeTaken() {
        let session = UUID()
        router.go(to: .session(session))
        XCTAssertEqual(router.requestedSelection, .session(session))
        XCTAssertEqual(router.takeSelection(), .session(session))
        XCTAssertNil(router.takeSelection(), "the window that answered clears it")
    }

    /// Every window hears the request and only the one that owns the target
    /// answers, so asking twice for the same session has to be audible twice —
    /// otherwise the second click from the menu bar would do nothing.
    func testAskingTwiceForTheSameTargetIsHeardTwice() {
        let session = UUID()
        router.go(to: .session(session))
        let first = router.selectionCounter
        router.go(to: .session(session))
        XCTAssertEqual(router.selectionCounter, first + 1)
    }

    // MARK: - Project areas

    func testAProjectCanBeOpenedOnAnArea() {
        let project = UUID()
        router.go(to: .project(project, area: .run))
        XCTAssertEqual(router.requestedSelection, .project(project))
        XCTAssertEqual(router.takeArea(for: project), .run)
    }

    /// Consumed once: otherwise every later visit to the project would be
    /// dragged back to Run instead of landing where the user left off.
    func testTheAreaIsConsumedRatherThanSticking() {
        let project = UUID()
        router.go(to: .project(project, area: .run))
        _ = router.takeArea(for: project)
        XCTAssertNil(router.takeArea(for: project))
    }

    func testOneProjectsAreaDoesNotMoveAnother() {
        let first = UUID()
        let second = UUID()
        router.go(to: .project(first, area: .run))
        XCTAssertNil(router.takeArea(for: second))
        XCTAssertEqual(router.takeArea(for: first), .run)
    }

    func testOpeningAProjectWithoutAnAreaLandsWhereTheUserLeftIt() {
        let project = UUID()
        router.go(to: .project(project))
        XCTAssertNil(router.takeArea(for: project))
    }

    // MARK: - Project settings

    /// The sheet belongs to the sidebar, so the menu bar and the palette ask
    /// for it rather than each presenting one of their own.
    func testProjectSettingsAreAskedForOnceAndAnsweredOnce() {
        let project = UUID()
        router.go(to: .projectSettings(project))
        XCTAssertEqual(router.requestedProjectSettingsID, project)
        XCTAssertEqual(router.takeProjectSettings(), project)
        XCTAssertNil(router.takeProjectSettings())
    }

    func testAskingForTheSameProjectSettingsTwiceIsHeardTwice() {
        let project = UUID()
        router.go(to: .projectSettings(project))
        let first = router.projectSettingsCounter
        router.go(to: .projectSettings(project))
        XCTAssertEqual(router.projectSettingsCounter, first + 1)
    }

    // MARK: - Handoff

    /// The sheet belongs to the session's own header, so only that session may
    /// answer — every other header hears the same request.
    func testOnlyTheSessionThatWasAskedForOpensItsHandoff() {
        let wanted = UUID()
        let other = UUID()
        router.go(to: .handoff(sessionID: wanted))
        XCTAssertFalse(router.takeHandoff(for: other))
        XCTAssertTrue(router.takeHandoff(for: wanted))
        XCTAssertFalse(router.takeHandoff(for: wanted), "answered once")
    }

    // MARK: - Settings and Extensions

    func testASettingsPaneIsDeliveredOnce() {
        router.go(to: .settings(pane: "permissions"))
        XCTAssertEqual(router.takePane(), "permissions")
        XCTAssertNil(router.takePane())
    }

    func testAnExtensionsScreenAndActionTravelTogether() {
        router.go(to: .extensions(section: .security, action: .bumblebeeScan))
        XCTAssertEqual(router.extensionsSection, .security)
        XCTAssertEqual(router.extensionsAction, .bumblebeeScan)
    }

    /// The menu offers actions that do not move the window, and screens that
    /// carry no action; neither may clear the other.
    func testAnActionAloneLeavesTheScreenAlone() {
        router.go(to: .extensions(section: .security))
        router.go(to: .extensions(action: .rediscover))
        XCTAssertEqual(router.extensionsSection, .security)
        XCTAssertEqual(router.extensionsAction, .rediscover)
    }

    // MARK: - Onboarding

    func testOnboardingIsPresentedAndDismissed() {
        XCTAssertFalse(router.isPresentingOnboarding)
        router.go(to: .onboarding)
        XCTAssertTrue(router.isPresentingOnboarding)
        router.dismissOnboarding()
        XCTAssertFalse(router.isPresentingOnboarding)
    }
}
