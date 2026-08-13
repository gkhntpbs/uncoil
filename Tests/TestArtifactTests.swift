import XCTest
@testable import Uncoil

/// The files a run leaves behind: which ones count as this run's, which step
/// each belongs to, and which directory the app is willing to read at all.
final class TestArtifactTests: XCTestCase {
    private func entry(_ name: String, _ offset: TimeInterval, from base: Date)
        -> TestArtifactCollector.Entry {
        TestArtifactCollector.Entry(
            url: URL(fileURLWithPath: "/tmp/shots/\(name)"),
            modifiedAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - The time window

    /// A screenshot from yesterday's run is still on disk, and attaching it to
    /// today's failure would be a lie told with a picture.
    func testOnlyFilesWrittenDuringTheRunAreCollected() {
        let started = Date()
        let artifacts = TestArtifactCollector.collect(
            entries: [
                entry("old.png", -3600, from: started),
                entry("during.png", 2, from: started),
                entry("after-the-fact.png", 600, from: started),
            ],
            startedAt: started, finishedAt: started.addingTimeInterval(10)
        )
        XCTAssertEqual(artifacts.map(\.name), ["during.png"])
    }

    /// A suite that writes its first screenshot in the same instant it starts
    /// would otherwise lose it to clock granularity.
    func testTheWindowStartsSlightlyBeforeTheRun() {
        let started = Date()
        let artifacts = TestArtifactCollector.collect(
            entries: [entry("first.png", -0.4, from: started)],
            startedAt: started, finishedAt: started.addingTimeInterval(5)
        )
        XCTAssertEqual(artifacts.count, 1)
    }

    func testKindComesFromTheExtension() {
        XCTAssertEqual(TestArtifactCollector.kind(for: URL(fileURLWithPath: "/a/b.PNG")), .image)
        XCTAssertEqual(TestArtifactCollector.kind(for: URL(fileURLWithPath: "/a/b.mp4")), .video)
        XCTAssertEqual(TestArtifactCollector.kind(for: URL(fileURLWithPath: "/a/b.json")), .other)
        XCTAssertFalse(TestArtifact.Kind.video.isPreviewable)
    }

    // MARK: - Attachment

    func testAnArtifactGoesToTheStepWhoseNameItCarries() {
        let started = Date()
        let artifacts = TestArtifactCollector.collect(
            entries: [entry("smoke-01-anasayfa.png", 1, from: started)],
            startedAt: started, finishedAt: nil
        )
        let cases = [
            TestCaseResult(suite: "Smoke", name: "smoke 01 anasayfa", outcome: .passed),
            TestCaseResult(suite: "Smoke", name: "checkoutFlow", outcome: .failed),
        ]
        let result = TestArtifactCollector.attach(artifacts, to: cases)
        XCTAssertEqual(result.cases[0].artifacts.map(\.name), ["smoke-01-anasayfa.png"])
        XCTAssertTrue(result.cases[1].artifacts.isEmpty)
        XCTAssertTrue(result.unattached.isEmpty)
    }

    /// A file nobody claims is still shown — under the run rather than under a
    /// step it has nothing to do with.
    func testAnUnclaimedArtifactStaysWithTheRun() {
        let started = Date()
        let artifacts = TestArtifactCollector.collect(
            entries: [entry("report.html", 1, from: started)],
            startedAt: started, finishedAt: nil
        )
        let result = TestArtifactCollector.attach(
            artifacts, to: [TestCaseResult(suite: "", name: "checkoutFlow", outcome: .passed)]
        )
        XCTAssertTrue(result.cases[0].artifacts.isEmpty)
        XCTAssertEqual(result.unattached.map(\.name), ["report.html"])
    }

    /// A step called `test` would otherwise swallow every file in the folder.
    func testVeryShortStepNamesClaimNothing() {
        let started = Date()
        let artifacts = TestArtifactCollector.collect(
            entries: [entry("a-screenshot.png", 1, from: started)],
            startedAt: started, finishedAt: nil
        )
        let result = TestArtifactCollector.attach(
            artifacts, to: [TestCaseResult(suite: "", name: "a", outcome: .passed)]
        )
        XCTAssertTrue(result.cases[0].artifacts.isEmpty)
        XCTAssertEqual(result.unattached.count, 1)
    }

    // MARK: - The directory

    func testTheArtifactsPathIsResolvedAgainstTheProject() {
        let root = URL(fileURLWithPath: "/projects/app")
        let suite = TestSuiteConfiguration(
            id: "e2e", command: "maestro test", artifacts: "build/screenshots"
        )
        XCTAssertEqual(
            TestArtifactCollector.directory(for: suite, projectRoot: root)?.path,
            "/projects/app/build/screenshots"
        )
    }

    /// The field is editable by an agent, so it must not be able to point the
    /// app at somewhere outside the project it belongs to.
    func testAPathThatClimbsOutOfTheProjectIsRefused() {
        let root = URL(fileURLWithPath: "/projects/app")
        for path in ["../../etc", "/etc", "build/../../secrets"] {
            let suite = TestSuiteConfiguration(id: "e2e", command: "true", artifacts: path)
            XCTAssertNil(
                TestArtifactCollector.directory(for: suite, projectRoot: root),
                "\(path) should not resolve"
            )
        }
    }

    func testASuiteWithNoArtifactsPathHasNoDirectory() {
        let suite = TestSuiteConfiguration(id: "unit", command: "swift test")
        XCTAssertNil(
            TestArtifactCollector.directory(
                for: suite, projectRoot: URL(fileURLWithPath: "/projects/app")
            )
        )
    }

    // MARK: - Round trip

    /// The field is written to `.uncoil/tests.json` and read back, and an agent
    /// that adds it by hand has to reach the app.
    func testTheArtifactsPathSurvivesTheConfigFile() throws {
        let data = Data("""
        {"version": 1, "suites": [
          {"id": "e2e", "command": "maestro test", "artifacts": "build/shots"}
        ]}
        """.utf8)
        let suite = try XCTUnwrap(TestConfigFile.parse(data).suites.first)
        XCTAssertEqual(suite.artifacts, "build/shots")
        let encoded = try JSONEncoder().encode(suite)
        let decoded = try JSONDecoder().decode(TestSuiteConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.artifacts, "build/shots")
    }

    /// Results written before artifacts existed have no such key, and failing
    /// to decode them would drop the last result of every suite on update.
    func testAnOlderRecordStillDecodes() throws {
        let data = Data("""
        {
          "id": "1", "suiteID": "unit", "startedAt": 0, "finishedAt": 1,
          "summary": {"passed": 1, "failed": 0, "skipped": 0, "isDetailed": true},
          "cases": [{"suite": "S", "name": "testOne", "outcome": "passed"}],
          "logTail": ""
        }
        """.utf8)
        let record = try JSONDecoder().decode(TestRunRecord.self, from: data)
        XCTAssertTrue(record.artifacts.isEmpty)
        XCTAssertTrue(record.cases[0].artifacts.isEmpty)
        XCTAssertEqual(record.summary.passed, 1)
    }

    // MARK: - Formatting

    func testLongDurationsAreWrittenAsMinutes() {
        XCTAssertEqual(TestStepFormat.duration(0.003), "3ms")
        XCTAssertEqual(TestStepFormat.duration(0.25), "250ms")
        XCTAssertEqual(TestStepFormat.duration(42), "42.0s")
        XCTAssertEqual(TestStepFormat.duration(423), "7:03")
    }
}

/// Reading a run as it happens. The live view and the finished record go
/// through the same parser, so the only thing that can differ between them is
/// how the output was cut up on the way in.
final class TestLiveParserTests: XCTestCase {
    /// Output arrives in whatever chunks the pipe flushed, and a chunk that
    /// ends mid-line used to be a test nobody saw.
    func testALineSplitAcrossChunksIsStillRead() {
        var parser = TestLiveParser(framework: .swift)
        XCTAssertTrue(parser.consume("Test Case 'Suite.testOne' pas").isEmpty)
        let cases = parser.consume("sed (0.002 seconds).\n")
        XCTAssertEqual(cases.map(\.name), ["testOne"])
    }

    func testEachTestIsReportedOnce() {
        var parser = TestLiveParser(framework: .swift)
        var seen: [TestCaseResult] = []
        for chunk in [
            "Test Case 'Suite.testOne' started.\nTest Case 'Suite.testOne' passed (0.1 seconds).\n",
            "Test Case 'Suite.testTwo' failed (0.2 seconds).\n",
        ] {
            seen += parser.consume(chunk)
        }
        XCTAssertEqual(seen.map(\.name), ["testOne", "testTwo"])
        XCTAssertEqual(seen.map(\.outcome), [.passed, .failed])
    }

    /// A framework whose output is not parsed reports nothing live, and the
    /// screen falls back to showing the output itself.
    func testAnUnparsedFrameworkStreamsNoSteps() {
        var parser = TestLiveParser(framework: .unknown)
        XCTAssertTrue(parser.consume("running the suite\ndone\n").isEmpty)
    }

    func testTheLiveSummaryCountsWhatHasArrived() {
        var state = TestSuiteState(isRunning: true)
        state.liveCases = [
            TestCaseResult(suite: "", name: "one", outcome: .passed),
            TestCaseResult(suite: "", name: "two", outcome: .failed),
            TestCaseResult(suite: "", name: "three", outcome: .skipped),
        ]
        XCTAssertEqual(state.liveSummary.total, 3)
        XCTAssertEqual(state.liveSummary.failed, 1)
        XCTAssertTrue(state.liveSummary.isDetailed)
        XCTAssertFalse(TestSuiteState().liveSummary.isDetailed)
    }
}

/// Which steps the list shows, and which filter it starts on.
final class TestStepFilterTests: XCTestCase {
    private let cases = [
        TestCaseResult(suite: "S", name: "one", outcome: .passed),
        TestCaseResult(suite: "S", name: "two", outcome: .failed),
        TestCaseResult(suite: "S", name: "three", outcome: .skipped),
    ]

    /// A red run leads with what failed; a green one has nothing to lead with.
    func testTheDefaultFollowsTheRun() {
        XCTAssertEqual(
            TestStepList.defaultFilter(for: TestRunSummary(passed: 9, failed: 1, isDetailed: true)),
            .failed
        )
        XCTAssertEqual(
            TestStepList.defaultFilter(for: TestRunSummary(passed: 9, isDetailed: true)),
            .all
        )
    }

    /// The regression this guards: `All` used to be indistinguishable from
    /// "nothing chosen", so choosing it on a failed run showed the failures.
    func testAllShowsEveryStep() {
        XCTAssertEqual(TestStepList.visible(cases, filter: .all).count, 3)
        XCTAssertEqual(TestStepList.visible(cases, filter: .failed).map(\.name), ["two"])
        XCTAssertEqual(TestStepList.visible(cases, filter: .skipped).map(\.name), ["three"])
        XCTAssertNil(TestStepList.Filter.all.outcome)
    }
}

/// When the whole suite is offered to an agent instead of one test.
final class TestSuiteRepairOfferTests: XCTestCase {
    private func record(_ cases: [TestCaseResult], summary: TestRunSummary) -> TestRunRecord {
        TestRunRecord(
            id: "1", suiteID: "unit", startedAt: Date(), finishedAt: Date(), exitCode: 1,
            summary: summary, cases: cases, logTail: ""
        )
    }

    /// A green run has nothing to hand over.
    func testAPassingRunOffersNothing() {
        XCTAssertFalse(TestStepList.showsSuiteRepair(for: record(
            [TestCaseResult(suite: "S", name: "one", outcome: .passed)],
            summary: TestRunSummary(passed: 1, isDetailed: true)
        )))
    }

    /// Some tests failed: each red row carries its own handle, and it says
    /// which test it means — better than one button for the lot.
    func testSomeFailuresAreHandedOverOneAtATime() {
        XCTAssertFalse(TestStepList.showsSuiteRepair(for: record(
            [
                TestCaseResult(suite: "S", name: "one", outcome: .failed),
                TestCaseResult(suite: "S", name: "two", outcome: .passed),
            ],
            summary: TestRunSummary(passed: 1, failed: 1, isDetailed: true)
        )))
    }

    /// Everything failed — picking one of them would be arbitrary.
    func testAWhollyFailedRunIsOfferedAsOne() {
        XCTAssertTrue(TestStepList.showsSuiteRepair(for: record(
            [
                TestCaseResult(suite: "S", name: "one", outcome: .failed),
                TestCaseResult(suite: "S", name: "two", outcome: .failed),
            ],
            summary: TestRunSummary(failed: 2, isDetailed: true)
        )))
    }

    /// The suite failed without naming a test — an unparsed framework, or one
    /// that died before it reported anything. There is no row to click.
    func testARunWithNoStepsIsOfferedAsOne() {
        XCTAssertTrue(TestStepList.showsSuiteRepair(for: record(
            [], summary: TestRunSummary(failed: 1)
        )))
    }
}

/// The plan a runner announces before it starts, which is what turns a live
/// count into a fraction.
final class TestDeclaredTotalTests: XCTestCase {
    func testPytestCollectionIsRead() {
        XCTAssertEqual(
            TestOutputParser.declaredTotal(
                in: "collected 15 items\n\ntests/test_a.py::test_one PASSED\n",
                framework: .pytest
            ),
            15
        )
        XCTAssertEqual(
            TestOutputParser.declaredTotal(
                in: "collected 15 items / 2 deselected / 13 selected\n", framework: .pytest
            ),
            15
        )
    }

    func testCargoAnnouncesItsCount() {
        XCTAssertEqual(
            TestOutputParser.declaredTotal(in: "running 8 tests\n", framework: .cargo), 8
        )
    }

    /// A framework that announces nothing gets no fraction, rather than one
    /// made up from a number that was never stated.
    func testAFrameworkThatSaysNothingGivesNothing() {
        XCTAssertNil(
            TestOutputParser.declaredTotal(
                in: "Test Suite 'All tests' started at 2026-01-01\n", framework: .swift
            )
        )
        XCTAssertNil(TestOutputParser.declaredTotal(in: "running tests", framework: .cargo))
    }
}
