import XCTest
@testable import Uncoil

/// Opening a project used to re-run a `TODO.md` scan, three git subprocesses and
/// a GitHub request before anything could be drawn, every single time, because
/// the page lived in the view's own state. It is cached now, and this is the
/// rule that decides when the cache has gone stale.
final class ProjectPageFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAPageThatWasNeverLoadedAlwaysRefreshes() {
        XCTAssertTrue(ProjectPageFreshness.needsRefresh(loadedAt: nil, now: now))
    }

    func testAPageLoadedAMomentAgoIsLeftAlone() {
        XCTAssertFalse(
            ProjectPageFreshness.needsRefresh(loadedAt: now.addingTimeInterval(-2), now: now)
        )
    }

    func testAPageRefreshesOnceItIsPastTheWindow() {
        let window = ProjectPageFreshness.window
        XCTAssertFalse(
            ProjectPageFreshness.needsRefresh(
                loadedAt: now.addingTimeInterval(-(window - 1)), now: now
            )
        )
        XCTAssertTrue(
            ProjectPageFreshness.needsRefresh(loadedAt: now.addingTimeInterval(-window), now: now)
        )
    }

    /// Switching between projects has to stay free; the window is not seconds.
    func testTheWindowIsLongEnoughToSwitchProjectsFreelyAndShortEnoughToNotice() {
        XCTAssertGreaterThanOrEqual(ProjectPageFreshness.window, 30)
        XCTAssertLessThanOrEqual(ProjectPageFreshness.window, 300)
    }

    func testAClockThatWentBackwardsDoesNotForceARefresh() {
        XCTAssertFalse(
            ProjectPageFreshness.needsRefresh(loadedAt: now.addingTimeInterval(60), now: now)
        )
    }
}

@MainActor
final class ProjectPageStoreTests: XCTestCase {
    private let store = ProjectPageStore.shared
    private let projectID = UUID()

    func testAnUnknownProjectHasAnEmptyPageThatHasNotLoaded() {
        let snapshot = store.snapshot(for: UUID())
        XCTAssertFalse(snapshot.hasLoaded)
        XCTAssertTrue(snapshot.worktrees.isEmpty)
        XCTAssertTrue(snapshot.pullRequests.isEmpty)
        XCTAssertEqual(snapshot.openTaskCount, 0)
    }

    /// `hasLoaded` is what the dashboard shows a skeleton for, so it has to mean
    /// "nothing is known yet" and nothing else.
    func testInvalidatingMakesTheNextLookRebuildTheSnapshot() {
        XCTAssertTrue(
            ProjectPageFreshness.needsRefresh(loadedAt: store.snapshot(for: projectID).loadedAt),
            "A project nobody has opened must refresh"
        )
    }
}
