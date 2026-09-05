import XCTest
@testable import Uncoil

/// Starting a session was written out at every surface that offers one, and the
/// copies had already drifted: a terminal opened in a worktree was called
/// `terminal @ feature-x` from the sidebar and plain `terminal` from everywhere
/// else, and only some copies remembered that a shell has no login to store.
@MainActor
final class SessionLaunchTests: XCTestCase {
    private var tempDir: URL!
    private var projects: ProjectStore!
    private var settings: SettingsStore!
    private var project: Project!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-launch-\(UUID().uuidString)", isDirectory: true)
        projects = ProjectStore(directory: tempDir)
        settings = SettingsStore()
        projects.addProject(at: URL(fileURLWithPath: "/tmp/launch-demo"))
        project = projects.projects[0]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func request(
        _ provider: AgentProvider, worktreePath: String? = nil
    ) -> SessionLaunchRequest {
        SessionLaunchRequest(project: project, provider: provider, worktreePath: worktreePath)
    }

    /// A terminal is named after where it is, because that is the only thing
    /// that tells one from another.
    func testATerminalIsNamedAfterWhereItRuns() {
        XCTAssertEqual(request(.terminal).title, "terminal")
        XCTAssertEqual(
            request(.terminal, worktreePath: "/tmp/launch-demo/.worktrees/feature-x").title,
            "terminal @ feature-x"
        )
    }

    /// A worktree does not rename an agent's session: the agent replaces the
    /// placeholder with the actual subject as soon as it knows it.
    func testAnAgentSessionKeepsItsPlaceholderInAWorktree() {
        let plain = request(.claude).title
        XCTAssertEqual(request(.claude, worktreePath: "/tmp/x/.worktrees/y").title, plain)
    }

    /// A stored login on a shell session would put an account name and a usage
    /// ring on a window that has neither.
    func testAShellIsNeverGivenALogin() {
        let login = AccountProfile(provider: .terminal, name: "nope")
        var terminal = request(.terminal)
        terminal.account = login
        XCTAssertNil(terminal.accountID)

        var agent = request(.claude)
        agent.account = AccountProfile(provider: .claude, name: "work")
        XCTAssertEqual(agent.accountID, agent.account?.id)
    }

    func testLaunchingRecordsTheSessionAgainstItsProjectAndWorktree() {
        let launcher = SessionLauncher(projects: projects, settings: settings)
        let worktree = "/tmp/launch-demo/.worktrees/feature-x"
        let record = launcher.launch(.claude, in: project, worktreePath: worktree)

        XCTAssertEqual(record.projectID, project.id)
        XCTAssertEqual(record.provider, .claude)
        XCTAssertEqual(record.worktreePath, worktree)
        XCTAssertTrue(projects.sessions.contains { $0.id == record.id })
    }

    /// The button offers the first of the user's own launcher order, resolved
    /// against what is installed — an agent that is not on the machine is a
    /// button that can only fail.
    func testTheDefaultAgentIsTheFirstInstalledOneTheUserOrdered() {
        let launcher = SessionLauncher(projects: projects, settings: settings)
        XCTAssertEqual(launcher.defaultProvider, settings.launcherProviders.first)
    }
}
