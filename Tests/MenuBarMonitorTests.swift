import XCTest
@testable import Uncoil

final class MenuBarMonitorTests: XCTestCase {
    private let projectID = UUID()

    private func session() -> SessionRecord {
        SessionRecord(projectID: projectID, provider: .claude, accountID: nil, title: "claude: iş")
    }

    private func attention(_ kind: AttentionKind, id: String) -> AttentionItem {
        AttentionItem(
            id: id, kind: kind, title: "t", detail: nil,
            projectID: nil, sessionID: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testCountsEveryCategory() {
        let running = UUID(), thinking = UUID(), permission = UUID()
        let input = UUID(), completed = UUID(), idle = UUID(), dead = UUID()
        let summary = MenuBarMonitorEngine.summary(
            statuses: [
                running: .running,
                thinking: .thinking,
                permission: .waitingForPermission,
                input: .waitingForInput,
                completed: .completed,
                idle: .idle,
                dead: .terminated,
            ],
            attention: [
                attention(.runtime, id: "runtime"),
                attention(.testFailure, id: "test:1"),
                attention(.permission, id: "permission:1"),
            ]
        )
        XCTAssertEqual(summary.running, 2, "running and thinking both count as working")
        XCTAssertEqual(summary.waitingPermission, 1)
        XCTAssertEqual(summary.waitingInput, 1)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.problems, 2, "normal waits are not problems")
        XCTAssertTrue(summary.hasProblem)
        XCTAssertTrue(summary.needsUser)
    }

    func testIdleSummaryHasEmptyLabelAndRestingIcon() {
        let summary = MenuBarMonitorEngine.summary(statuses: [UUID(): .idle])
        XCTAssertEqual(MenuBarPrefs().label(for: summary), "")
        XCTAssertEqual(summary.headline, "Nothing pending")
        XCTAssertEqual(summary.icon, .idle)
        XCTAssertFalse(summary.hasProblem)
        XCTAssertFalse(summary.needsUser)
    }

    func testLabelAndHeadlineReportWhatIsHappening() {
        let summary = MenuBarMonitorEngine.summary(
            statuses: [UUID(): .running, UUID(): .waitingForPermission],
            attention: [attention(.runtime, id: "runtime")]
        )
        XCTAssertEqual(MenuBarPrefs().label(for: summary), "1 1! 1×")
        XCTAssertTrue(summary.headline.contains("1 running"))
        XCTAssertTrue(summary.headline.contains("1 waiting for permission"))
        XCTAssertTrue(summary.headline.contains("1 problem"))
    }

    /// Three logos, three answers: color while agents work, yellow whenever
    /// anything waits on the user, plain when idle. Waiting always outranks
    /// working — a busy icon must not hide a question.
    func testIconEscalatesWithUrgency() {
        XCTAssertEqual(
            MenuBarMonitorEngine.summary(statuses: [UUID(): .running]).icon,
            .working
        )
        XCTAssertEqual(
            MenuBarMonitorEngine.summary(statuses: [UUID(): .waitingForInput]).icon,
            .waiting
        )
        XCTAssertEqual(
            MenuBarMonitorEngine.summary(statuses: [UUID(): .waitingForPermission]).icon,
            .waiting
        )
        XCTAssertEqual(
            MenuBarMonitorEngine.summary(
                statuses: [UUID(): .running, UUID(): .waitingForInput]
            ).icon,
            .waiting
        )
        XCTAssertEqual(
            MenuBarMonitorEngine.summary(
                statuses: [UUID(): .waitingForPermission],
                attention: [attention(.runtime, id: "runtime")]
            ).icon,
            .waiting
        )
    }

    func testOnlyBusySessionsAreInterruptible() {
        let busy = session(), waiting = session(), idle = session(), dead = session()
        let interruptible = MenuBarMonitorEngine.interruptible(
            [busy, waiting, idle, dead],
            statuses: [
                busy.id: .running,
                waiting.id: .waitingForPermission,
                idle.id: .idle,
                dead.id: .terminated,
            ]
        )
        XCTAssertEqual(Set(interruptible.map(\.id)), [busy.id, waiting.id])
    }
}
