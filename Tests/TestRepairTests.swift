import XCTest
@testable import Uncoil

/// What a failing suite says when it is handed to an agent.
@MainActor
final class TestRepairTests: XCTestCase {
    private let suite = TestSuiteConfiguration(
        id: "unit", name: "Unit tests", command: "swift test", framework: .swift
    )

    private func record(
        cases: [TestCaseResult], summary: TestRunSummary, logTail: String = ""
    ) -> TestRunRecord {
        TestRunRecord(
            id: "1", suiteID: "unit", startedAt: Date(), finishedAt: Date(),
            exitCode: 1, summary: summary, cases: cases, logTail: logTail
        )
    }

    /// The failure mode worth guarding: a suite turned green by deleting what
    /// it was checking is worse than a red one, so the prompt says so.
    func testTheAgentIsToldNotToWeakenTheTest() {
        let text = TestRepair.prompt(
            suite: suite,
            record: record(
                cases: [TestCaseResult(suite: "S", name: "testOne", outcome: .failed)],
                summary: TestRunSummary(passed: 4, failed: 1, isDetailed: true)
            )
        )
        XCTAssertTrue(text.contains("Do not weaken"))
        XCTAssertTrue(text.contains("whether the test or the code is wrong"))
    }

    /// The names and reasons are what make the prompt worth sending at all.
    func testFailuresTravelWithTheirMessages() {
        let text = TestRepair.prompt(
            suite: suite,
            record: record(
                cases: [
                    TestCaseResult(
                        suite: "DockerStatusTests", name: "testEmptyOutput", outcome: .failed,
                        message: "XCTAssertTrue failed"
                    ),
                    TestCaseResult(suite: "S", name: "testPasses", outcome: .passed),
                ],
                summary: TestRunSummary(passed: 1, failed: 1, isDetailed: true)
            )
        )
        XCTAssertTrue(text.contains("DockerStatusTests.testEmptyOutput: XCTAssertTrue failed"))
        XCTAssertFalse(text.contains("testPasses"))
        XCTAssertTrue(text.contains("{\"action\":\"test_run\",\"id\":\"unit\"}"))
        XCTAssertTrue(text.contains("uncoil_run"))
    }

    /// A long list would spend the agent's context on an enumeration; what it
    /// needs is the shape of the breakage and an honest count of the rest.
    func testOnlyTheFirstFailuresAreListed() {
        let failures = (1...25).map {
            TestCaseResult(suite: "S", name: "test\($0)", outcome: .failed)
        }
        let text = TestRepair.prompt(
            suite: suite,
            record: record(
                cases: failures, summary: TestRunSummary(failed: 25, isDetailed: true)
            )
        )
        XCTAssertTrue(text.contains("S.test1"))
        XCTAssertFalse(text.contains("S.test25"))
        XCTAssertTrue(text.contains("…and 15 more"))
    }

    /// One test, handed over on its own from its detail window.
    func testASingleTestCanBeTheWholeSubject() {
        let one = TestCaseResult(suite: "S", name: "testOne", outcome: .failed)
        let text = TestRepair.prompt(
            suite: suite,
            record: record(
                cases: [one, TestCaseResult(suite: "S", name: "testTwo", outcome: .failed)],
                summary: TestRunSummary(failed: 2, isDetailed: true)
            ),
            focus: one
        )
        XCTAssertTrue(text.contains("The test 'S.testOne'"))
        XCTAssertFalse(text.contains("testTwo"))
    }

    /// A framework nobody parsed has no failing names to send, so the output is
    /// the only thing that can explain it — and it goes.
    func testAnUndetailedRunSendsItsOutput() {
        let text = TestRepair.prompt(
            suite: TestSuiteConfiguration(id: "e2e", command: "./run.sh"),
            record: record(
                cases: [], summary: TestRunSummary(failed: 1),
                logTail: "Segmentation fault"
            )
        )
        XCTAssertTrue(text.contains("Segmentation fault"))
    }

    /// A detailed run's output is not sent: the names and messages already say
    /// what happened, and the tail would be a thousand green lines.
    func testADetailedRunDoesNotResendItsLog() {
        let text = TestRepair.prompt(
            suite: suite,
            record: record(
                cases: [TestCaseResult(suite: "S", name: "testOne", outcome: .failed)],
                summary: TestRunSummary(passed: 400, failed: 1, isDetailed: true),
                logTail: "a thousand green lines"
            )
        )
        XCTAssertFalse(text.contains("a thousand green lines"))
    }

    /// A fresh session knows nothing about Uncoil holding the suite's results,
    /// so the prompt says which actions drive it — otherwise the agent re-runs
    /// the suite by hand and reads its own scrollback.
    func testThePromptExplainsTheMcpsTestActions() {
        let note = TestRepair.mcpNote(suiteID: "unit")
        for action in ["test_run", "test_results", "test_list", "test_update", "help"] {
            XCTAssertTrue(note.contains(action), "the note should mention \(action)")
        }
        XCTAssertTrue(note.contains("uncoil_run"))
        XCTAssertTrue(note.contains(".uncoil/tests.json"))
    }

    /// The session is named after what is wrong, so a sidebar full of them
    /// still says which failure is which.
    func testTheSessionIsNamedAfterTheFailure() {
        XCTAssertEqual(TestRepair.title(suite: suite, focus: nil), "fix Unit tests")
        XCTAssertEqual(
            TestRepair.title(
                suite: suite,
                focus: TestCaseResult(suite: "S", name: "testOne", outcome: .failed)
            ),
            "fix testOne"
        )
    }
}
