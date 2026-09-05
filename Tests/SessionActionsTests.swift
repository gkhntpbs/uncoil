import XCTest
@testable import Uncoil

/// Restart was written five times and had already drifted: two copies bumped a
/// view-local counter instead of the one every view watches, so restarting from
/// the session header rebuilt one terminal and left the split pane, the popout
/// and the group view showing the process that had just been killed.
@MainActor
final class SessionActionsTests: XCTestCase {
    private var tempDir: URL!
    private var projects: ProjectStore!
    private var sessions: SessionStore!
    private var actions: SessionActions!
    private var record: SessionRecord!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-actions-\(UUID().uuidString)", isDirectory: true)
        projects = ProjectStore(directory: tempDir)
        sessions = SessionStore()
        actions = SessionActions(projects: projects, sessions: sessions)
        projects.addProject(at: URL(fileURLWithPath: "/tmp/actions-demo"))
        let project = projects.projects[0]
        record = projects.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "one"
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRestartBumpsTheCounterEveryViewWatches() {
        XCTAssertNil(sessions.restartCounter[record.id])
        actions.restart(record.id)
        XCTAssertEqual(sessions.restartCounter[record.id], 1)
        actions.restart(record.id)
        XCTAssertEqual(sessions.restartCounter[record.id], 2)
    }

    /// The session is still there afterwards — that is the whole difference
    /// between restarting and closing.
    func testRestartKeepsTheRecord() {
        actions.restart(record.id)
        XCTAssertTrue(projects.sessions.contains { $0.id == record.id })
    }

    func testClosingEndsTheSessionButKeepsItInTheHistory() {
        actions.close(record.id)
        XCTAssertEqual(sessions.status(of: record.id), .terminated)
        let stored = projects.sessions.first { $0.id == record.id }
        XCTAssertNotNil(stored, "a closed session stays in the history")
        XCTAssertNotNil(stored?.endedAt)
    }

    func testDeletingForgetsTheSession() {
        actions.delete(record.id)
        XCTAssertFalse(projects.sessions.contains { $0.id == record.id })
    }

    func testDeletingManyForgetsEveryOne() {
        let project = projects.projects[0]
        let second = projects.createSession(
            projectID: project.id, provider: .codex, accountID: nil, title: "two"
        )
        actions.delete([record.id, second.id])
        XCTAssertTrue(projects.sessions.isEmpty)
    }
}
