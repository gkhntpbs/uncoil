import XCTest
@testable import Uncoil

/// Which session a hook event belongs to when a project is running more than
/// one agent. Before this, every event in a project landed on whichever session
/// started last, so one agent's status was shown on all of them.
@MainActor
final class HookSessionRoutingTests: XCTestCase {
    private var tempDir: URL!
    private var projects: ProjectStore!
    private var sessions: SessionStore!
    private var project: Project!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncoil-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        projects = ProjectStore(directory: tempDir)
        projects.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        project = projects.projects[0]
        sessions = SessionStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession(worktree: String? = nil) -> SessionRecord {
        let record = projects.createSession(
            projectID: project.id,
            provider: .claude,
            accountID: nil,
            title: "claude",
            worktreePath: worktree
        )
        sessions.setStatus(.idle, for: record.id)
        return record
    }

    private func resolve(providerSessionID: String?, cwd: String?) -> UUID? {
        sessions.sessionID(
            forProviderSessionID: providerSessionID,
            cwd: cwd,
            projectSessions: projects.sessions(for: project.id),
            project: project
        )
    }

    func testBoundSessionWinsOverTheNewestOne() {
        let first = makeSession()
        projects.updateSession(first.id) { $0.providerSessionID = "prov-a" }
        let second = makeSession()
        projects.updateSession(second.id) { $0.providerSessionID = "prov-b" }

        XCTAssertEqual(resolve(providerSessionID: "prov-a", cwd: "/tmp/demo"), first.id)
        XCTAssertEqual(resolve(providerSessionID: "prov-b", cwd: "/tmp/demo"), second.id)
    }

    func testAnUnknownAgentDoesNotStealABoundSession() {
        let bound = makeSession()
        projects.updateSession(bound.id) { $0.providerSessionID = "prov-a" }
        let fresh = makeSession()

        // A second agent's first event, before it has been bound to anything.
        XCTAssertEqual(resolve(providerSessionID: "prov-new", cwd: "/tmp/demo"), fresh.id)
    }

    func testWorkingDirectoryPicksAmongUnboundSessions() {
        let worktree = tempDir.appendingPathComponent("wt").path
        let inRoot = makeSession()
        let inWorktree = makeSession(worktree: worktree)

        XCTAssertEqual(resolve(providerSessionID: nil, cwd: worktree), inWorktree.id)
        XCTAssertEqual(resolve(providerSessionID: nil, cwd: "/tmp/demo"), inRoot.id)
    }

    func testTerminatedSessionsAreNeverRouted() {
        let live = makeSession()
        let dead = makeSession()
        projects.updateSession(dead.id) { $0.providerSessionID = "prov-dead" }
        sessions.setStatus(.terminated, for: dead.id)

        XCTAssertEqual(resolve(providerSessionID: "prov-dead", cwd: "/tmp/demo"), live.id)
    }
}
