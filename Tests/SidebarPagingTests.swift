import XCTest
@testable import Uncoil

/// A project's sessions are shown a page at a time, with "Load more" closing
/// each list that holds some back. Which ones are shown follows recency; where
/// they are drawn follows the user's order.
final class SidebarPagingTests: XCTestCase {
    private let project = UUID()
    private let group = UUID()
    private lazy var loose = (0..<12).map { _ in UUID() }
    private lazy var grouped = (0..<7).map { _ in UUID() }
    private let child = UUID()
    /// By default the list order is also the recency order, newest first.
    private lazy var ranks: [UUID: Date] = {
        var ranks: [UUID: Date] = [:]
        for (index, id) in (loose + grouped + [child]).enumerated() {
            ranks[id] = Date(timeIntervalSince1970: 1_000_000 - Double(index))
        }
        ranks[child] = .distantPast
        return ranks
    }()

    private func paged(
        _ limit: Int?, pages: [UUID: Int] = [:], keeping: UUID? = nil
    ) -> SidebarStructure {
        structure.paged(limit: limit, pages: pages, keeping: keeping) { self.ranks[$0] ?? .distantPast }
    }

    private var structure: SidebarStructure {
        SidebarStructure.build(
            projectIDs: [project],
            groups: { _ in [self.group] },
            sessions: { _ in
                self.grouped.map { ($0, self.group, nil) }
                    + self.loose.map { ($0, nil, nil) }
                    // A sub-agent of the first loose session.
                    + [(self.child, nil, self.loose[0])]
            }
        )
    }

    func testEachListShowsOnePageAndCountsWhatItHolds() throws {
        let result = paged(5)
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.ungrouped.map(\.id), Array(loose.prefix(5)))
        XCTAssertEqual(project.hiddenCount, 7)
        XCTAssertEqual(project.groups.first?.sessions.map(\.id), Array(grouped.prefix(5)))
        XCTAssertEqual(project.groups.first?.hiddenCount, 2)
    }

    func testASubAgentRidesWithItsParentAndIsNotCounted() throws {
        let result = paged(5)
        let first = try XCTUnwrap(result.projects.first?.ungrouped.first)
        XCTAssertEqual(first.children.map(\.id), [child])
        XCTAssertEqual(result.projects.first?.ungrouped.count, 5)
    }

    func testLoadMoreAddsAPagePerPressPerList() throws {
        let once = paged(5, pages: [project: 1])
        XCTAssertEqual(once.projects.first?.ungrouped.count, 10)
        XCTAssertEqual(once.projects.first?.hiddenCount, 2)
        // The group's own list is untouched by the project's button.
        XCTAssertEqual(once.projects.first?.groups.first?.hiddenCount, 2)

        let twice = paged(5, pages: [project: 2])
        XCTAssertEqual(twice.projects.first?.ungrouped.count, 12)
        XCTAssertEqual(twice.projects.first?.hiddenCount, 0)
    }

    func testShowLessIsOfferedOnlyOnceMoreThanAPageIsShowing() throws {
        let first = try XCTUnwrap(paged(5).projects.first)
        XCTAssertFalse(first.canShowLess)

        let more = try XCTUnwrap(paged(5, pages: [project: 1]).projects.first)
        XCTAssertTrue(more.canShowLess)
        XCTAssertEqual(more.hiddenCount, 2)
        // The group was not extended, so it has nothing to fold.
        XCTAssertEqual(more.groups.first?.canShowLess, false)

        // Everything loaded: nothing left to load, still something to fold.
        let all = try XCTUnwrap(paged(5, pages: [project: 5]).projects.first)
        XCTAssertEqual(all.hiddenCount, 0)
        XCTAssertTrue(all.canShowLess)
    }

    func testAListThatFitsOnOnePageHasNothingToFold() throws {
        let project = try XCTUnwrap(paged(20, pages: [project: 3]).projects.first)
        XCTAssertFalse(project.canShowLess)
        XCTAssertEqual(project.hiddenCount, 0)
    }

    func testNoLimitLeavesTheTreeWhole() {
        XCTAssertEqual(paged(nil), structure)
        XCTAssertEqual(paged(0), structure)
        XCTAssertEqual(paged(50), structure)
    }

    func testTheOpenSessionIsNeverHeldBack() throws {
        let deep = loose[9]
        let result = paged(5, keeping: deep)
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.ungrouped.map(\.id), Array(loose.prefix(5)) + [deep])
        XCTAssertEqual(project.hiddenCount, 6)
    }

    func testAnOpenSubAgentKeepsItsParentsBranch() throws {
        ranks[loose[0]] = .distantPast
        let result = paged(1, keeping: child)
        let shown = try XCTUnwrap(result.projects.first?.ungrouped)
        XCTAssertEqual(shown.map(\.id), [loose[0], loose[1]])
        XCTAssertEqual(shown.first?.children.map(\.id), [child])
    }

    func testLoadMoreRowSitsAtTheDepthOfItsList() {
        let result = paged(5)
        XCTAssertEqual(result.depth(of: .more(project)), 1)
        XCTAssertEqual(result.depth(of: .more(group)), 2)
        XCTAssertNotEqual(SidebarItem.more(project).nodeID, SidebarItem.project(project).nodeID)
    }

    func testTheMostRecentlyUsedAreShownInTheUsersOrder() throws {
        // New sessions are stamped at the end of the list, so the newest are
        // the last rows — and those are the ones a page has to show.
        for (index, id) in loose.enumerated() {
            ranks[id] = Date(timeIntervalSince1970: Double(index))
        }
        let project = try XCTUnwrap(paged(3).projects.first)
        XCTAssertEqual(project.ungrouped.map(\.id), Array(loose.suffix(3)))
        XCTAssertEqual(project.hiddenCount, 9)
    }

    func testAPinnedSessionAlwaysMakesTheCut() throws {
        ranks[loose[11]] = .distantFuture
        let project = try XCTUnwrap(paged(3).projects.first)
        XCTAssertEqual(project.ungrouped.map(\.id), [loose[0], loose[1], loose[11]])
    }

    func testABusySubAgentKeepsItsParentInView() throws {
        let parent = loose[0]
        ranks[parent] = .distantPast
        ranks[child] = Date(timeIntervalSince1970: 2_000_000)
        let project = try XCTUnwrap(paged(3).projects.first)
        XCTAssertTrue(project.ungrouped.map(\.id).contains(parent))
    }

    func testPageSizeSettingZeroMeansAll() {
        XCTAssertNil(SidebarSessionLimit.pageSize(0))
        XCTAssertEqual(SidebarSessionLimit.pageSize(5), 5)
        XCTAssertEqual(SidebarSessionLimit.default, 5)
    }
}

@MainActor
final class SidebarSessionPagesTests: XCTestCase {
    func testShowLessGoesBackToTheFirstPage() {
        let pages = SidebarSessionPages()
        let list = UUID()
        pages.loadMore(list)
        pages.loadMore(list)
        XCTAssertEqual(pages.pages[list], 2)
        pages.showLess(list)
        XCTAssertNil(pages.pages[list])
    }
}

@MainActor
final class SidebarSessionLimitSettingTests: XCTestCase {
    func testTheLimitPersistsAndDefaultsToFive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSidebarLimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(SettingsStore(directory: directory).sidebarSessionLimit, 5)
        SettingsStore(directory: directory).setSidebarSessionLimit(0)
        XCTAssertEqual(SettingsStore(directory: directory).sidebarSessionLimit, 0)
        SettingsStore(directory: directory).setSidebarSessionLimit(10)
        XCTAssertEqual(SettingsStore(directory: directory).sidebarSessionLimit, 10)
    }
}
