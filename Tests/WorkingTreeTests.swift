import XCTest
@testable import Uncoil

final class WorkingTreeTests: XCTestCase {
    private let project = Project(id: UUID(), name: "uncoil", rootPath: "/repo")

    private func session(worktree: String?) -> SessionRecord {
        var record = SessionRecord(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: one")
        record.worktreePath = worktree
        return record
    }

    /// A tree has one checkout, so everyone in the project root shares a branch
    /// whether they know it or not.
    func testSessionsWithoutAWorktreeShareTheProjectRoot() {
        let a = session(worktree: nil)
        let b = session(worktree: nil)
        let elsewhere = session(worktree: "/repo/.uncoil-worktrees/heartbeat")
        let found = WorkingTree.sessions(
            at: "/repo", in: project, from: [a, b, elsewhere])
        XCTAssertEqual(Set(found.map(\.id)), [a.id, b.id])
    }

    func testAWorktreeIsItsOwnTree() {
        let root = session(worktree: nil)
        let inTree = session(worktree: "/repo/.uncoil-worktrees/heartbeat")
        let found = WorkingTree.sessions(
            at: "/repo/.uncoil-worktrees/heartbeat", in: project, from: [root, inTree])
        XCTAssertEqual(found.map(\.id), [inTree.id])
    }

    /// A trailing slash or a `..` hop is the same directory, and splitting one
    /// tree in two would leave half its sessions unwarned.
    func testPathsAreComparedAfterNormalising() {
        let a = session(worktree: "/repo/.uncoil-worktrees/heartbeat/")
        let b = session(worktree: "/repo/.uncoil-worktrees/../.uncoil-worktrees/heartbeat")
        let found = WorkingTree.sessions(
            at: "/repo/.uncoil-worktrees/heartbeat", in: project, from: [a, b])
        XCTAssertEqual(Set(found.map(\.id)), [a.id, b.id])
    }

    func testAnotherProjectsSessionsAreNeverIncluded() {
        var other = SessionRecord(
            projectID: UUID(), provider: .claude, accountID: nil, title: "claude: other")
        other.worktreePath = nil
        XCTAssertTrue(WorkingTree.sessions(at: "/repo", in: project, from: [other]).isEmpty)
    }

    func testOnlyInFlightStatusesCountAsWorking() {
        for status in [AgentSessionStatus.thinking, .running, .waitingForPermission, .waitingForInput] {
            XCTAssertTrue(status.isWorking, "\(status) should count as working")
        }
        for status in [AgentSessionStatus.idle, .completed, .terminated] {
            XCTAssertFalse(status.isWorking, "\(status) should not count as working")
        }
    }
}
