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

    /// Gemini emits no hooks and never binds a provider session id, so it was
    /// the standing fallback for every Claude event nobody claimed — one
    /// agent's work shown on another agent's row.
    func testAProviderThatSendsNoHooksIsNeverGuessedAt() {
        let gemini = projects.createSession(
            projectID: project.id, provider: .gemini, accountID: nil, title: "gemini"
        )
        sessions.setStatus(.idle, for: gemini.id)

        XCTAssertNil(resolve(providerSessionID: nil, cwd: "/tmp/demo"))
        XCTAssertNil(resolve(providerSessionID: "prov-a", cwd: "/tmp/demo"))
    }

    /// A session restored at launch has no status until the daemon answers,
    /// and its first hook is exactly when it says who it is.
    func testASessionThatHasNotBeenHeardFromStillAnswersToItsOwnID() {
        let restored = makeSession()
        projects.updateSession(restored.id) { $0.providerSessionID = "prov-a" }
        sessions.setStatus(.unknown, origin: .lifecycle, for: restored.id)

        XCTAssertEqual(resolve(providerSessionID: "prov-a", cwd: "/tmp/demo"), restored.id)
        XCTAssertNil(
            resolve(providerSessionID: nil, cwd: "/tmp/demo"),
            "but it is not guessed at while nothing is known about it"
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

    /// A Claude sub-agent spawned by the Task tool carries its own `session_id`
    /// and shares its parent's `cwd`. Nothing is bound to that id, and once
    /// every session in the project is bound the routing used to fall back to
    /// the newest live one — writing the sub-agent's activity onto an agent
    /// that is not it.
    ///
    /// That misattribution is what made a waiting agent notify over and over:
    /// the sub-agent's tool events flipped the parent out of `waitingForInput`,
    /// the reminder sweep dropped the ledger entry because the status no longer
    /// matched, and the parent's next wait counted as a first banner instead of
    /// a capped reminder.
    func testASubAgentsEventIsNotWrittenOntoAnAlreadyBoundSession() {
        let parent = makeSession()
        projects.updateSession(parent.id) { $0.providerSessionID = "prov-parent" }
        let other = makeSession()
        projects.updateSession(other.id) { $0.providerSessionID = "prov-other" }

        XCTAssertNil(resolve(providerSessionID: "prov-subagent", cwd: "/tmp/demo"))
    }

    /// The parent's own events still route: it is bound, and binding wins.
    func testTheParentStillReceivesItsOwnEvents() {
        let parent = makeSession()
        projects.updateSession(parent.id) { $0.providerSessionID = "prov-parent" }
        _ = makeSession()

        XCTAssertEqual(resolve(providerSessionID: "prov-parent", cwd: "/tmp/demo"), parent.id)
    }

    /// An agent that reports no session id at all cannot be told apart from a
    /// sub-agent, so the old guess stays for it — dropping those events would
    /// take live status away from builds that never send one.
    func testAnEventWithoutASessionIDStillFallsBack() {
        let bound = makeSession()
        projects.updateSession(bound.id) { $0.providerSessionID = "prov-a" }

        XCTAssertEqual(resolve(providerSessionID: nil, cwd: "/elsewhere"), bound.id)
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
        XCTAssertEqual(
            sessions.status(of: survivor.id), .unknown,
            "before reconciling nobody has said anything about it"
        )

        var ended: [UUID] = []
        sessions.reconcile(
            aliveSessionIDs: [survivor.id],
            records: projects.sessions,
            markEnded: { ended.append($0) }
        )

        XCTAssertEqual(sessions.status(of: survivor.id), .idle)
        XCTAssertTrue(ended.isEmpty)
    }

    /// One silence is not a death. The daemon can answer `list` while it is
    /// restarting, before it has re-adopted the sessions it still owns, and
    /// closing them on that answer is permanent and wrong.
    func testOneMissedHandshakeSaysUnknownRatherThanClosed() {
        let missing = makeSession()

        var ended: [UUID] = []
        let unaccountedFor = sessions.reconcile(
            aliveSessionIDs: [],
            records: projects.sessions,
            markEnded: { ended.append($0) }
        )

        XCTAssertEqual(sessions.status(of: missing.id), .unknown)
        XCTAssertTrue(ended.isEmpty, "nothing is written to disk on one silence")
        XCTAssertEqual(unaccountedFor, [missing.id], "the caller is told to ask again")
    }

    func testASessionMissingTwiceIsClosedForGood() {
        let gone = makeSession()

        var ended: [UUID] = []
        for _ in 0..<2 {
            sessions.reconcile(
                aliveSessionIDs: [],
                records: projects.sessions,
                markEnded: { ended.append($0) }
            )
        }

        XCTAssertEqual(sessions.status(of: gone.id), .terminated)
        XCTAssertEqual(ended, [gone.id], "the record has to agree with the status")
    }

    /// The daemon hiccuping must not close a running agent: it was missing from
    /// one answer and present in the next, so it never left.
    func testASessionThatComesBackIsNotClosed() {
        let flapping = makeSession()
        sessions.setStatus(.running, for: flapping.id)

        var ended: [UUID] = []
        let markEnded: (UUID) -> Void = { ended.append($0) }
        sessions.reconcile(
            aliveSessionIDs: [], records: projects.sessions, markEnded: markEnded)
        XCTAssertEqual(sessions.status(of: flapping.id), .unknown)

        sessions.reconcile(
            aliveSessionIDs: [flapping.id], records: projects.sessions, markEnded: markEnded)
        XCTAssertEqual(sessions.status(of: flapping.id), .idle)

        // And the count starts over: the next single silence is again not fatal.
        sessions.reconcile(
            aliveSessionIDs: [], records: projects.sessions, markEnded: markEnded)
        XCTAssertTrue(ended.isEmpty)
        XCTAssertEqual(sessions.status(of: flapping.id), .unknown)
    }

    /// The direction nothing used to correct: the record says the session is
    /// over, the status still says it is working.
    func testAnEndedRecordSilencesAStatusThatDisagrees() {
        let stale = makeSession()
        sessions.setStatus(.running, for: stale.id)
        projects.markSessionEnded(stale.id, exitCode: 0)

        sessions.reconcile(
            aliveSessionIDs: [], records: projects.sessions, markEnded: { _ in })

        XCTAssertEqual(sessions.status(of: stale.id), .terminated)
    }

    /// A sleeping session is absent from the daemon on purpose, so the missing
    /// count must never start for it.
    func testASleepingSessionIsNeverCountedAsMissing() {
        let asleep = makeSession()
        projects.markSessionAsleep(asleep.id, mode: .hibernated)

        var ended: [UUID] = []
        for _ in 0..<3 {
            sessions.reconcile(
                aliveSessionIDs: [], records: projects.sessions,
                markEnded: { ended.append($0) })
        }

        XCTAssertEqual(sessions.status(of: asleep.id), .hibernated)
        XCTAssertTrue(ended.isEmpty)
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
