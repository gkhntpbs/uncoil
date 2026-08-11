import XCTest
@testable import Uncoil

/// Reading a test runner's output. Every sample here is the real shape the tool
/// prints, because the whole value of this layer is that it matches reality —
/// a parser that agrees only with its own fixtures reports green on a red suite.
final class TestOutputParserTests: XCTestCase {
    // MARK: - XCTest

    /// `xcodebuild` writes `-[Suite method]`, `swift test` writes `Suite.method`.
    func testBothXCTestNameStylesAreRead() {
        let cases = TestOutputParser.parseXCTest("""
        Test Case '-[UncoilTests.SessionSleepTests testAClosedSessionCannotHibernate]' started.
        Test Case '-[UncoilTests.SessionSleepTests testAClosedSessionCannotHibernate]' passed (0.002 seconds).
        Test Case 'DockerStatusTests.testEmptyOutput' failed (0.100 seconds).
        """)
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases[0].outcome, .passed)
        XCTAssertEqual(cases[0].name, "testAClosedSessionCannotHibernate")
        XCTAssertEqual(cases[0].duration, 0.002)
        XCTAssertEqual(cases[1].outcome, .failed)
        XCTAssertEqual(cases[1].suite, "DockerStatusTests")
    }

    /// Every XCTest case prints a "started" line as well. Counting it would
    /// double the total and, worse, count a failing test as one pass and one
    /// failure.
    func testStartedLinesAreNotCountedAsResults() {
        let cases = TestOutputParser.parseXCTest("""
        Test Case '-[Suite testOne]' started.
        Test Case '-[Suite testOne]' passed (0.001 seconds).
        """)
        XCTAssertEqual(cases.count, 1)
    }

    func testASkippedXCTestIsNotAPass() {
        let cases = TestOutputParser.parseXCTest(
            "Test Case '-[Suite testSkipped]' skipped (0.001 seconds)."
        )
        XCTAssertEqual(cases.first?.outcome, .skipped)
    }

    /// Verbatim from this project's own `xcodebuild test` output.
    ///
    /// The fixtures above are written by hand and could agree only with
    /// themselves; this one cannot. When it was captured, xcodebuild printed 62
    /// `Test Case` lines for the two suites and reported "Executed 31 tests" —
    /// exactly the terminal half.
    func testRealXcodebuildOutputIsCountedTheWayXcodebuildCountsIt() {
        let output = """
        Test Suite 'DockerStatusTests' started at 2026-08-03 15:02:11.104.
        Test Case '-[UncoilTests.DockerStatusTests testAJSONArrayIsParsed]' started.
        Test Case '-[UncoilTests.DockerStatusTests testAJSONArrayIsParsed]' passed (0.001 seconds).
        Test Case '-[UncoilTests.DockerStatusTests testAnUnhealthyContainerIsReportedAsDegraded]' started.
        Test Case '-[UncoilTests.DockerStatusTests testAnUnhealthyContainerIsReportedAsDegraded]' passed (0.000 seconds).
        Test Suite 'DockerStatusTests' passed at 2026-08-03 15:02:11.106.
        	 Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds
        """
        let cases = TestOutputParser.parseXCTest(output)
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases.filter { $0.outcome == .passed }.count, 2)
        XCTAssertEqual(cases[0].suite, "UncoilTests.DockerStatusTests")
        XCTAssertEqual(cases[0].name, "testAJSONArrayIsParsed")
        // "Test Suite" lines start with the same two words and must not be read
        // as cases; the summary line must not be either.
        XCTAssertFalse(cases.contains { $0.name.contains("Executed") })
    }

    // MARK: - go test -json

    func testGoJSONIsRead() {
        let cases = TestOutputParser.parseGoJSON("""
        {"Action":"run","Package":"example.com/app","Test":"TestOne"}
        {"Action":"pass","Package":"example.com/app","Test":"TestOne","Elapsed":0.01}
        {"Action":"fail","Package":"example.com/app","Test":"TestTwo","Elapsed":0.5}
        {"Action":"skip","Package":"example.com/app","Test":"TestThree"}
        """)
        XCTAssertEqual(cases.map(\.outcome), [.passed, .failed, .skipped])
        XCTAssertEqual(cases[0].duration, 0.01)
        XCTAssertEqual(cases[0].suite, "example.com/app")
    }

    /// go emits the same pass/fail actions for the package as a whole, without
    /// a `Test` field. Counting those would add a phantom result per package.
    func testThePackageSummaryIsNotCountedAsATest() {
        let cases = TestOutputParser.parseGoJSON("""
        {"Action":"pass","Package":"example.com/app","Test":"TestOne","Elapsed":0.01}
        {"Action":"pass","Package":"example.com/app","Elapsed":0.02}
        """)
        XCTAssertEqual(cases.count, 1)
    }

    // MARK: - cargo

    func testCargoOutputIsRead() {
        let cases = TestOutputParser.parseCargo("""
        running 3 tests
        test store::tests::it_reads ... ok
        test store::tests::it_writes ... FAILED
        test slow::tests::it_waits ... ignored
        """)
        XCTAssertEqual(cases.map(\.outcome), [.passed, .failed, .skipped])
        XCTAssertEqual(cases[0].suite, "store::tests")
        XCTAssertEqual(cases[0].name, "it_reads")
    }

    // MARK: - pytest

    func testPytestVerboseOutputIsRead() {
        let cases = TestOutputParser.parsePytest("""
        tests/test_api.py::test_get PASSED                                   [ 33%]
        tests/test_api.py::test_post FAILED                                  [ 66%]
        tests/test_api.py::test_delete SKIPPED                               [100%]
        """)
        XCTAssertEqual(cases.map(\.outcome), [.passed, .failed, .skipped])
        XCTAssertEqual(cases[0].suite, "tests/test_api.py")
        XCTAssertEqual(cases[0].name, "test_get")
    }

    /// pytest's summary lines also contain `::`. Reading them as tests would
    /// add a duplicate of every failure.
    func testPytestSummaryLinesAreNotTests() {
        let cases = TestOutputParser.parsePytest("""
        =================================== FAILURES ===================================
        ____________________________ test_post _____________________________
        tests/test_api.py::test_post FAILED                                  [ 66%]
        """)
        XCTAssertEqual(cases.count, 1)
    }

    // MARK: - Jest / Vitest

    func testJestOutputIsRead() {
        let cases = TestOutputParser.parseJest("""
          ✓ renders the header (12 ms)
          ✕ submits the form
          ↓ skips on CI
        """)
        XCTAssertEqual(cases.map(\.outcome), [.passed, .failed, .skipped])
        XCTAssertEqual(cases[0].name, "renders the header")
        XCTAssertEqual(cases[0].duration, 0.012)
    }

    /// A test whose own name ends in a parenthesis must not have it eaten by
    /// the duration stripper.
    func testAParenthesisThatIsNotADurationStaysInTheName() {
        let cases = TestOutputParser.parseJest("  ✓ handles the empty case (edge)")
        XCTAssertEqual(cases.first?.name, "handles the empty case (edge)")
        XCTAssertNil(cases.first?.duration)
    }

    // MARK: - Summaries

    func testTheSummaryCountsWhatWasParsed() {
        let result = TestOutputParser.parse("""
        Test Case '-[Suite testOne]' passed (0.001 seconds).
        Test Case '-[Suite testTwo]' failed (0.001 seconds).
        Test Case '-[Suite testThree]' skipped (0.001 seconds).
        """, framework: .swift, exitCode: 1)
        XCTAssertEqual(result.summary.passed, 1)
        XCTAssertEqual(result.summary.failed, 1)
        XCTAssertEqual(result.summary.skipped, 1)
        XCTAssertTrue(result.summary.isDetailed)
        XCTAssertFalse(result.summary.didPass)
    }

    /// An unrecognised framework still reports pass or fail — but it must not
    /// claim a per-test breakdown it never read.
    func testAnUnknownFrameworkReportsTheExitCodeAndSaysSo() {
        let failed = TestOutputParser.parse(
            "some output nobody parses", framework: .unknown, exitCode: 1
        )
        XCTAssertTrue(failed.cases.isEmpty)
        XCTAssertFalse(failed.summary.isDetailed)
        XCTAssertFalse(failed.summary.didPass)

        let passed = TestOutputParser.parse(
            "some output nobody parses", framework: .unknown, exitCode: 0
        )
        XCTAssertTrue(passed.summary.didPass)
        XCTAssertFalse(passed.summary.isDetailed)
    }

    /// A runner that printed green tests and then crashed did not pass, and the
    /// counts alone would say it did.
    func testANonZeroExitOverridesAllGreenCounts() {
        let result = TestOutputParser.parse(
            "Test Case '-[Suite testOne]' passed (0.001 seconds).",
            framework: .swift, exitCode: 74
        )
        XCTAssertEqual(result.summary.passed, 1)
        XCTAssertFalse(result.summary.didPass)
    }

    func testAGreenSuiteWithAZeroExitPasses() {
        let result = TestOutputParser.parse(
            "Test Case '-[Suite testOne]' passed (0.001 seconds).",
            framework: .swift, exitCode: 0
        )
        XCTAssertTrue(result.summary.didPass)
        XCTAssertTrue(result.summary.isDetailed)
    }

    /// Only the frameworks whose output is actually read may claim per-test
    /// detail. This is the promise the UI relies on.
    func testOnlyRecognisedFrameworksClaimIndividualTests() {
        for framework in TestFramework.allCases {
            XCTAssertEqual(
                framework.reportsIndividualTests, framework != .unknown, framework.rawValue
            )
        }
    }
}

/// The failure message a runner printed, matched back to the test it belongs
/// to. Without it a red row says only that something broke, which is the one
/// thing the user already knew.
final class TestFailureMessageTests: XCTestCase {
    func testXCTestFailuresReachTheirCase() {
        let output = """
        Test Case '-[UncoilTests.HandoffTests testPromptIsBuilt]' started.
        /Users/x/Tests/HandoffTests.swift:42: error: -[UncoilTests.HandoffTests testPromptIsBuilt] : XCTAssertEqual failed: ("a") is not equal to ("b")
        Test Case '-[UncoilTests.HandoffTests testPromptIsBuilt]' failed (0.010 seconds).
        Test Case '-[UncoilTests.HandoffTests testOther]' passed (0.001 seconds).
        """
        let parsed = TestOutputParser.parse(output, framework: .swift, exitCode: 1)
        let failed = parsed.cases.first { $0.outcome == .failed }
        XCTAssertEqual(failed?.message, #"XCTAssertEqual failed: ("a") is not equal to ("b")"#)
        XCTAssertNil(parsed.cases.first { $0.outcome == .passed }?.message)
    }

    func testPytestShortSummaryIsUsed() {
        let output = """
        tests/test_cart.py::test_total FAILED                                    [ 50%]
        tests/test_cart.py::test_empty PASSED                                    [100%]
        =========================== short test summary info ============================
        FAILED tests/test_cart.py::test_total - AssertionError: assert 3 == 4
        """
        let parsed = TestOutputParser.parse(output, framework: .pytest, exitCode: 1)
        XCTAssertEqual(
            parsed.cases.first { $0.outcome == .failed }?.message,
            "AssertionError: assert 3 == 4"
        )
    }

    /// go writes the reason in the test's own output events. The `=== RUN` and
    /// `--- FAIL` framing carries nothing the row does not already show, and it
    /// would be all a short message had room for.
    func testGoFailureKeepsOnlyTheReason() {
        let output = """
        {"Action":"run","Test":"TestTotal"}
        {"Action":"output","Test":"TestTotal","Output":"=== RUN   TestTotal\\n"}
        {"Action":"output","Test":"TestTotal","Output":"    cart_test.go:12: want 4, got 3\\n"}
        {"Action":"output","Test":"TestTotal","Output":"--- FAIL: TestTotal (0.00s)\\n"}
        {"Action":"fail","Test":"TestTotal","Elapsed":0.001}
        """
        let parsed = TestOutputParser.parse(output, framework: .go, exitCode: 1)
        XCTAssertEqual(parsed.cases.first?.message, "cart_test.go:12: want 4, got 3")
    }

    func testCargoFailureBlockIsRead() {
        let output = """
        test cart::total ... FAILED

        failures:

        ---- cart::total stdout ----
        thread 'cart::total' panicked at src/cart.rs:12:
        assertion failed: left == right
        """
        let parsed = TestOutputParser.parse(output, framework: .cargo, exitCode: 101)
        XCTAssertEqual(
            parsed.cases.first?.message,
            "thread 'cart::total' panicked at src/cart.rs:12:\nassertion failed: left == right"
        )
    }

    /// A framework whose failures are not parsed leaves the message empty
    /// rather than showing an unrelated line that happened to be nearby.
    func testAnUnparsedFrameworkLeavesNoMessage() {
        let parsed = TestOutputParser.parse("✕ renders the cart\n", framework: .jest, exitCode: 1)
        XCTAssertEqual(parsed.cases.first?.outcome, .failed)
        XCTAssertNil(parsed.cases.first?.message)
    }
}
