import XCTest
@testable import Uncoil

/// A session needs a working directory — an agent with nowhere to stand cannot
/// read a file, write one, or run anything. So "a session without a project"
/// still needs somewhere to be, and it gets one: a project Uncoil owns.
@MainActor
final class ScratchWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ProjectStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Creation

    /// Lazily: someone who never opens a one-off session should not find a
    /// folder they did not ask for.
    func testTheWorkspaceDoesNotExistUntilSomethingAsksForIt() {
        XCTAssertNil(store.scratchProject)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ScratchWorkspace.directory(dataDirectory: directory).path
            )
        )
    }

    func testOpeningAOneOffSessionMakesTheWorkspace() throws {
        let record = store.createScratchSession(provider: .claude)
        let project = try XCTUnwrap(store.scratchProject)
        XCTAssertEqual(record.projectID, project.id)
        XCTAssertTrue(project.isScratchWorkspace)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: project.rootPath),
            "an agent with nowhere to stand cannot do anything"
        )
    }

    /// Every one-off session shares the one workspace: a folder per session
    /// would be a directory of empty directories.
    func testASecondOneOffSessionReusesTheSameWorkspace() {
        let first = store.createScratchSession(provider: .claude)
        let second = store.createScratchSession(provider: .codex)
        XCTAssertEqual(first.projectID, second.projectID)
        XCTAssertEqual(store.projects.filter(\.isScratchWorkspace).count, 1)
    }

    /// The record is what everything else refers to, so when the folder is
    /// deleted from under it the folder is put back — not the record thrown
    /// away, which would strand the sessions inside it.
    func testADeletedFolderIsRestoredWithoutLosingTheSessions() throws {
        let record = store.createScratchSession(provider: .claude)
        let project = try XCTUnwrap(store.scratchProject)
        try FileManager.default.removeItem(atPath: project.rootPath)

        let again = store.ensureScratchProject()
        XCTAssertEqual(again.id, project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.rootPath))
        XCTAssertTrue(store.sessions.contains { $0.id == record.id })
    }

    func testTheFolderExplainsItselfToWhoeverFindsIt() throws {
        _ = store.createScratchSession(provider: .claude)
        let project = try XCTUnwrap(store.scratchProject)
        let readme = URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readme.path))
    }

    // MARK: - Keeping it apart

    /// A picker offering "apply this extension to Scratch" is offering
    /// nonsense: it is Uncoil's folder, not one of the user's projects.
    func testTheWorkspaceIsNotOneOfTheUsersProjects() {
        store.addProject(at: directory.appendingPathComponent("real"))
        _ = store.createScratchSession(provider: .claude)

        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.visibleProjects.count, 1)
        XCTAssertFalse(store.visibleProjects.contains { $0.isScratchWorkspace })
    }

    /// It still has to be *reachable* — a one-off session that cannot be found
    /// again is a session that was thrown away.
    func testTheWorkspaceIsStillInTheSidebarsList() {
        _ = store.createScratchSession(provider: .claude)
        XCTAssertTrue(store.projects.contains { $0.isScratchWorkspace })
    }

    /// Resolving a project by path is what routes hook events; without it a
    /// one-off session would report its status to nobody.
    func testTheWorkspaceResolvesFromItsPath() throws {
        _ = store.createScratchSession(provider: .claude)
        let project = try XCTUnwrap(store.scratchProject)
        XCTAssertEqual(store.project(containing: project.rootPath)?.id, project.id)
    }

    // MARK: - Order

    /// Pinning and manual order are about the projects someone chose to open.
    /// Uncoil's own folder competing with those for the top of the list would
    /// be the app putting its housekeeping above the user's work.
    func testTheWorkspaceSortsLastWhateverElseIsTrue() {
        _ = store.createScratchSession(provider: .claude)
        store.addProject(at: directory.appendingPathComponent("a"))
        store.addProject(at: directory.appendingPathComponent("b"))
        XCTAssertTrue(store.projects.last?.isScratchWorkspace ?? false)

        // Even pinned, which is reachable through an older document.
        if let scratch = store.scratchProject {
            store.updateProject(scratch.id) { $0.isPinned = true }
            store.sortProjects()
        }
        XCTAssertTrue(store.projects.last?.isScratchWorkspace ?? false)
    }

    func testAPinnedProjectStillLeadsTheOrdinaryOnes() {
        store.addProject(at: directory.appendingPathComponent("a"))
        store.addProject(at: directory.appendingPathComponent("b"))
        _ = store.createScratchSession(provider: .claude)
        guard let second = store.visibleProjects.last else { return XCTFail("no projects") }
        store.updateProject(second.id) { $0.isPinned = true }
        store.sortProjects()

        XCTAssertEqual(store.projects.first?.id, second.id)
        XCTAssertTrue(store.projects.last?.isScratchWorkspace ?? false)
    }

    // MARK: - Naming

    /// "new session" repeated down the sidebar tells nobody anything, and a
    /// one-off session has no folder name to be called after.
    func testSessionsAreNamedByWhenTheyWereOpened() {
        let morning = ScratchWorkspace.sessionTitle(
            for: .claude, at: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let later = ScratchWorkspace.sessionTitle(
            for: .claude, at: Date(timeIntervalSince1970: 1_770_007_200)
        )
        XCTAssertNotEqual(morning, later)
        XCTAssertTrue(morning.contains("Claude"))
    }
}

/// The sidebar's ordering rule on its own.
final class ProjectSortRankTests: XCTestCase {
    func testPinnedLeadsPlainLeadsScratch() {
        let pinned = ProjectSortRank.rank(isScratch: false, isPinned: true)
        let plain = ProjectSortRank.rank(isScratch: false, isPinned: false)
        let scratch = ProjectSortRank.rank(isScratch: true, isPinned: false)
        XCTAssertLessThan(pinned, plain)
        XCTAssertLessThan(plain, scratch)
    }

    /// Pinning cannot lift it: it is not one of the projects being ordered.
    func testPinningTheWorkspaceDoesNotLiftIt() {
        XCTAssertEqual(
            ProjectSortRank.rank(isScratch: true, isPinned: true),
            ProjectSortRank.rank(isScratch: true, isPinned: false)
        )
    }
}

/// The way in. A one-off session is reached for at exactly the moment nothing
/// else is open, so it has to be one keystroke away rather than something to
/// scroll past four projects to find.
final class ScratchPaletteTests: XCTestCase {
    private func context(query: String, providers: [AgentProvider]) -> PaletteContext {
        PaletteContext(
            query: query, projects: [], sessions: [], statuses: [:],
            currentProjectID: nil, currentSessionID: nil, files: [], artifacts: [],
            projectRoot: nil, settingsPanes: [], launcherProviders: providers
        )
    }

    private func items(_ ctx: PaletteContext) -> [PaletteItem] {
        PaletteEngine.compute(ctx).flatMap(\.items)
    }

    func testOneCommandPerLauncherProvider() {
        let found = items(context(query: "", providers: [.claude, .terminal]))
            .filter { $0.id.hasPrefix("cmd.scratch.") }
        XCTAssertEqual(found.count, 2)
    }

    /// Same answer as everywhere else, so an agent that is not installed is not
    /// offered here either.
    func testOnlyTheProvidersTheStripOffers() {
        let found = items(context(query: "", providers: [.claude]))
            .filter { $0.id.hasPrefix("cmd.scratch.") }
        XCTAssertEqual(found.map(\.id), ["cmd.scratch.claude"])
    }

    func testTheCommandCarriesTheProviderItWillOpen() throws {
        let item = try XCTUnwrap(
            items(context(query: "", providers: [.codex]))
                .first { $0.id == "cmd.scratch.codex" }
        )
        guard case .newScratchSession(let provider) = item.action else {
            return XCTFail("expected a scratch action, got \(item.action)")
        }
        XCTAssertEqual(provider, .codex)
    }

    /// Available with no project open at all — which is the case it exists for.
    func testItIsOfferedWithNothingElseOpen() {
        XCTAssertFalse(
            items(context(query: "", providers: [.claude]))
                .filter { $0.id.hasPrefix("cmd.scratch.") }
                .isEmpty
        )
    }

    func testItIsFoundBySearching() {
        let found = items(context(query: "one-off", providers: [.claude]))
            .filter { $0.id.hasPrefix("cmd.scratch.") }
        XCTAssertFalse(found.isEmpty)
    }
}
