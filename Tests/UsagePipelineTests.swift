import XCTest
@testable import Uncoil

/// A strategy whose behaviour the test decides.
private struct StubStrategy: UsageFetchStrategy {
    var source: UsageSource
    var available: Bool = true
    var result: Result<UsageSnapshot, UsageFetchError>
    var recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UsageSource] = []

        func record(_ source: UsageSource) {
            lock.lock(); calls.append(source); lock.unlock()
        }

        var attempted: [UsageSource] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    func isAvailable() -> Bool { available }

    func fetch() async throws -> UsageSnapshot {
        recorder.record(source)
        return try result.get()
    }
}

private func snapshot(_ source: UsageSource, used: Double = 10) -> UsageSnapshot {
    UsageSnapshot(
        provider: .codex,
        primaryWindow: UsageWindow(id: "p", title: "Session", usedPercent: used),
        source: source,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

/// The ordering, the fallbacks, and the two rules that stop it.
final class UsagePipelineTests: XCTestCase {
    private let clock = { Date(timeIntervalSince1970: 1_700_000_000) }

    func testThePreferredStrategyWinsAndTheRestAreNotRun() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: [
                StubStrategy(source: .codexOAuthAPI, result: .success(snapshot(.codexOAuthAPI)), recorder: recorder),
                StubStrategy(source: .codexAppServerRPC, result: .success(snapshot(.codexAppServerRPC)), recorder: recorder),
            ],
            clock: clock
        )
        XCTAssertEqual(outcome.snapshot?.source, .codexOAuthAPI)
        XCTAssertEqual(recorder.attempted, [.codexOAuthAPI])
    }

    /// The case the whole ordering exists for: a route that cannot answer hands
    /// over instead of failing the provider.
    func testAFailedPreferredRouteFallsThroughToTheNext() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: [
                StubStrategy(
                    source: .codexOAuthAPI,
                    result: .failure(UsageFetchError(.credentialsExpired)),
                    recorder: recorder
                ),
                StubStrategy(
                    source: .codexAppServerRPC,
                    result: .success(snapshot(.codexAppServerRPC)),
                    recorder: recorder
                ),
            ],
            clock: clock
        )
        XCTAssertEqual(outcome.snapshot?.source, .codexAppServerRPC)
        XCTAssertEqual(recorder.attempted, [.codexOAuthAPI, .codexAppServerRPC])
        XCTAssertEqual(outcome.attempts.count, 2)
        XCTAssertFalse(outcome.attempts[0].succeeded)
        XCTAssertTrue(outcome.attempts[1].succeeded)
    }

    /// An unavailable route is a skip, not a failure: nothing is installed, and
    /// reporting that as an error would fill diagnostics with non-events.
    func testAnUnavailableStrategyIsSkippedWithoutBeingRun() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: [
                StubStrategy(
                    source: .codexOAuthAPI, available: false,
                    result: .success(snapshot(.codexOAuthAPI)), recorder: recorder
                ),
                StubStrategy(
                    source: .codexAppServerRPC,
                    result: .success(snapshot(.codexAppServerRPC)), recorder: recorder
                ),
            ],
            clock: clock
        )
        XCTAssertEqual(recorder.attempted, [.codexAppServerRPC])
        XCTAssertTrue(outcome.attempts[0].skipped)
        // The last non-skipped attempt is the useful diagnostic, not the skip.
        XCTAssertNil(outcome.lastError)
    }

    /// A verdict about the account stops the pipeline. Falling through would
    /// turn "this plan reports no quota" into "everything failed", which reads
    /// as transient and invites a retry loop against an answer that will not
    /// change.
    func testATerminalVerdictStopsThePipelineAndBecomesTheResult() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .gemini, accountID: nil,
            strategies: [
                StubStrategy(
                    source: .geminiCodeAssistAPI,
                    result: .failure(UsageFetchError(.accountTierUnsupported, detail: "free-tier")),
                    recorder: recorder
                ),
                StubStrategy(
                    source: .codexAppServerRPC,
                    result: .success(snapshot(.codexAppServerRPC)), recorder: recorder
                ),
            ],
            clock: clock
        )
        XCTAssertEqual(recorder.attempted, [.geminiCodeAssistAPI])
        XCTAssertEqual(outcome.snapshot?.unavailable, .accountTierUnsupported)
        // A reason, never a number.
        XCTAssertFalse(outcome.snapshot?.hasQuota ?? true)
    }

    func testAnAuthenticationTypeVerdictIsAlsoTerminal() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .gemini, accountID: nil,
            strategies: [
                StubStrategy(
                    source: .geminiCodeAssistAPI,
                    result: .failure(UsageFetchError(.authenticationTypeUnsupported)),
                    recorder: recorder
                ),
            ],
            clock: clock
        )
        XCTAssertEqual(outcome.snapshot?.unavailable, .authenticationTypeUnsupported)
    }

    func testWhenEveryRouteFailsThereIsNoSnapshot() async {
        let recorder = StubStrategy.Recorder()
        let outcome = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: [
                StubStrategy(source: .codexOAuthAPI, result: .failure(UsageFetchError(.timedOut)), recorder: recorder),
                StubStrategy(source: .codexAppServerRPC, result: .failure(UsageFetchError(.processFailed)), recorder: recorder),
            ],
            clock: clock
        )
        XCTAssertNil(outcome.snapshot)
        XCTAssertEqual(outcome.lastError?.kind, .processFailed)
    }

    func testNoStrategiesAtAllProducesNothingRatherThanAZero() async {
        let outcome = await UsageFetchPipeline.run(
            provider: .terminal, accountID: nil, strategies: [], clock: clock
        )
        XCTAssertNil(outcome.snapshot)
        XCTAssertTrue(outcome.attempts.isEmpty)
    }
}

// MARK: - Error classification

final class UsageFetchErrorTests: XCTestCase {

    /// A failure of the route continues; a verdict about the account stops.
    func testRouteFailuresContinueAndAccountVerdictsDoNot() {
        XCTAssertTrue(UsageFetchError(.timedOut).continuesToFallback)
        XCTAssertTrue(UsageFetchError(.credentialsExpired).continuesToFallback)
        XCTAssertTrue(UsageFetchError(.malformedResponse).continuesToFallback)
        XCTAssertFalse(UsageFetchError(.accountTierUnsupported).continuesToFallback)
        XCTAssertFalse(UsageFetchError(.planReportsNoQuota).continuesToFallback)
        XCTAssertFalse(UsageFetchError(.cancelled).continuesToFallback)
    }

    func testTheDefaultCanBeOverriddenExplicitly() {
        XCTAssertFalse(UsageFetchError(.timedOut, continuesToFallback: false).continuesToFallback)
    }

    /// The summary is the thing that reaches a log, so it must carry no body.
    func testTheSummaryIsShort() {
        XCTAssertEqual(UsageFetchError(.timedOut).summary, "timedOut")
        XCTAssertEqual(UsageFetchError(.transport, detail: "HTTP 500").summary, "transport: HTTP 500")
    }
}

// MARK: - Status mapping

final class UsageHTTPResponseTests: XCTestCase {

    /// 401 and 403 are told apart deliberately: a rejected token may be fixed
    /// by another route holding a different one.
    func testStatusesMapOntoThePipelinesVocabulary() {
        XCTAssertEqual(UsageHTTPResponse(statusCode: 401, body: Data()).failure().kind, .credentialsExpired)
        XCTAssertEqual(UsageHTTPResponse(statusCode: 403, body: Data()).failure().kind, .unauthorized)
        XCTAssertEqual(UsageHTTPResponse(statusCode: 504, body: Data()).failure().kind, .timedOut)
        XCTAssertEqual(UsageHTTPResponse(statusCode: 500, body: Data()).failure().kind, .transport)
    }

    func testABodyThatIsNotJSONIsAMalformedResponse() {
        let response = UsageHTTPResponse(statusCode: 200, body: Data("<html>nope</html>".utf8))
        XCTAssertThrowsError(try response.json()) { error in
            XCTAssertEqual((error as? UsageFetchError)?.kind, .malformedResponse)
        }
    }
}

// MARK: - Redaction

final class UsageCredentialsRedactionTests: XCTestCase {

    /// Redacting only the tokens we happen to hold would miss the one in a
    /// response nobody expected to contain one — which is the case that ends up
    /// in a bug report.
    func testCredentialShapesAreRemovedFromDiagnostics() {
        let text = """
        Authorization: Bearer sk-abc123def456ghi789
        {"access_token": "ya29.aVeryLongTokenValueHere", "refresh_token": "1//abcdefghijklmnop"}
        Cookie: sessionKey=sk-ant-sid01-abcdefghijklmnop
        """
        let redacted = UsageCredentials.redacted(text)

        XCTAssertFalse(redacted.contains("sk-abc123def456ghi789"))
        XCTAssertFalse(redacted.contains("ya29.aVeryLongTokenValueHere"))
        XCTAssertFalse(redacted.contains("1//abcdefghijklmnop"))
        XCTAssertTrue(redacted.contains("«redacted»"))
    }

    func testOrdinaryTextIsLeftAlone() {
        let text = "codexOAuthAPI: ok\nSession limit: 82% remaining"
        XCTAssertEqual(UsageCredentials.redacted(text), text)
    }
}
