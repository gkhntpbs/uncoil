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

    private func makeTerminalSession() -> SessionRecord {
        let record = projects.createSession(
            projectID: project.id, provider: .terminal, accountID: nil, title: "terminal"
        )
        sessions.setStatus(.idle, for: record.id)
        return record
    }

    /// A hook event comes from an agent, and every branch of the routing ends
    /// in a guess. With terminal sessions in the pool those guesses landed on a
    /// plain shell, which is how a terminal row announced that Claude was
    /// waiting for input.
    func testATerminalSessionNeverReceivesAnAgentEvent() {
        let terminal = makeTerminalSession()
        let agent = makeSession()

        XCTAssertEqual(resolve(providerSessionID: nil, cwd: "/tmp/demo"), agent.id)
        XCTAssertNotEqual(resolve(providerSessionID: "unknown", cwd: "/tmp/demo"), terminal.id)
    }

    /// And with nothing but terminals open, the event belongs to nobody rather
    /// than to the newest shell.
    func testAnEventWithOnlyTerminalsOpenIsDropped() {
        _ = makeTerminalSession()
        _ = makeTerminalSession()

        XCTAssertNil(resolve(providerSessionID: nil, cwd: "/tmp/demo"))
    }
}

/// What survived the app being closed. Statuses are transient and agents are
/// not, so without asking the daemon every restored session read as Closed.
@MainActor
final class SessionReconcileTests: XCTestCase {
    private var tempDir: URL!
    private var projects: ProjectStore!
    private var sessions: SessionStore!
    private var project: Project!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncoil-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        projects = ProjectStore(directory: tempDir)
        projects.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        project = projects.projects[0]
        sessions = SessionStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession() -> SessionRecord {
        projects.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude"
        )
    }

    func testASessionTheDaemonStillHasIsLive() {
        let survivor = makeSession()
        XCTAssertEqual(sessions.status(of: survivor.id), .terminated, "before reconciling")

        var ended: [UUID] = []
        sessions.reconcile(
            aliveSessionIDs: [survivor.id],
            records: projects.sessions,
            markEnded: { ended.append($0) }
        )

        XCTAssertEqual(sessions.status(of: survivor.id), .idle)
        XCTAssertTrue(ended.isEmpty)
    }

    func testASessionTheDaemonLostIsClosedForGood() {
        let gone = makeSession()

        var ended: [UUID] = []
        sessions.reconcile(
            aliveSessionIDs: [],
            records: projects.sessions,
            markEnded: { ended.append($0) }
        )

        XCTAssertEqual(sessions.status(of: gone.id), .terminated)
        XCTAssertEqual(ended, [gone.id], "the record has to agree with the status")
    }

    /// A reconnect must not throw away what the session is actually doing.
    func testReconcilingDoesNotOverwriteALiveStatus() {
        let working = makeSession()
        sessions.setStatus(.waitingForPermission, for: working.id)

        sessions.reconcile(
            aliveSessionIDs: [working.id],
            records: projects.sessions,
            markEnded: { _ in }
        )

        XCTAssertEqual(sessions.status(of: working.id), .waitingForPermission)
    }

    /// A session already marked ended is history; reconciling does not reopen
    /// the question or fire `markEnded` for it a second time.
    func testAlreadyEndedSessionsAreLeftAlone() {
        let old = makeSession()
        projects.markSessionEnded(old.id, exitCode: 0)

        var ended: [UUID] = []
        sessions.reconcile(
            aliveSessionIDs: [],
            records: projects.sessions,
            markEnded: { ended.append($0) }
        )

        XCTAssertTrue(ended.isEmpty)
    }
}
