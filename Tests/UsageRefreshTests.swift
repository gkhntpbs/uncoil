import XCTest
@testable import Uncoil

/// When the next refresh is due.
///
/// Pure, so the behaviour that matters — backing off, not hammering a rejected
/// credential, waking just after a reset — is tested without a network, a timer
/// or a clock that has to actually pass.
final class UsageRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Cadence

    /// A limit only moves when the agent is working. Polling an idle account as
    /// often as a busy one spends requests re-reading a number that cannot have
    /// changed.
    func testAnActiveAccountIsCheckedMoreOftenThanAnIdleOne() {
        XCTAssertLessThan(
            UsageRefreshPolicy.interval(for: .active),
            UsageRefreshPolicy.interval(for: .idle)
        )
        XCTAssertLessThan(
            UsageRefreshPolicy.interval(for: .idle),
            UsageRefreshPolicy.interval(for: .background)
        )
    }

    func testAnAccountNeverCheckedIsDueImmediately() {
        let state = UsageRefreshState()
        XCTAssertTrue(UsageRefreshPolicy.shouldRefresh(state: state, activity: .idle, now: now))
    }

    func testAJustCheckedAccountIsNotDueAgain() {
        let state = UsageRefreshState(lastAttempt: now, lastSuccess: now)
        XCTAssertFalse(UsageRefreshPolicy.shouldRefresh(state: state, activity: .active, now: now))
        XCTAssertTrue(UsageRefreshPolicy.shouldRefresh(
            state: state, activity: .active,
            now: now.addingTimeInterval(UsageRefreshPolicy.activeInterval + 1)
        ))
    }

    // MARK: - Backoff

    func testFailuresBackOffAndTheDelayGrows() {
        let one = UsageRefreshState(lastAttempt: now, consecutiveFailures: 1)
        let three = UsageRefreshState(lastAttempt: now, consecutiveFailures: 3)

        let first = UsageRefreshPolicy.nextRefresh(state: one, activity: .active)
        let third = UsageRefreshPolicy.nextRefresh(state: three, activity: .active)
        XCTAssertEqual(first, now.addingTimeInterval(UsageRefreshPolicy.backoffBase))
        XCTAssertGreaterThan(try XCTUnwrap(third), try XCTUnwrap(first))
    }

    /// Without a ceiling a long outage would push the next attempt past any
    /// point at which someone is still watching.
    func testBackoffIsCapped() {
        let state = UsageRefreshState(lastAttempt: now, consecutiveFailures: 40)
        XCTAssertEqual(
            UsageRefreshPolicy.nextRefresh(state: state, activity: .active),
            now.addingTimeInterval(UsageRefreshPolicy.backoffCeiling)
        )
    }

    // MARK: - Authentication

    /// A rejected credential has no schedule. It is fixed by the user logging
    /// in again, and until then every timed attempt is noise that can only make
    /// things worse.
    func testARejectedCredentialStopsAutomaticRetriesEntirely() {
        let state = UsageRefreshState(lastAttempt: now, authenticationBlocked: true)
        XCTAssertNil(UsageRefreshPolicy.nextRefresh(state: state, activity: .active))
        XCTAssertFalse(UsageRefreshPolicy.shouldRefresh(
            state: state, activity: .active, now: now.addingTimeInterval(86_400)
        ))
    }

    /// A person pressing refresh is telling us something changed; a button that
    /// stays broken because of an old failure fails exactly when it is needed.
    func testAskingByHandClearsTheBlock() {
        let blocked = UsageRefreshState(lastAttempt: now, consecutiveFailures: 5, authenticationBlocked: true)
        let cleared = UsageRefreshPolicy.unblocked(blocked)
        XCTAssertFalse(cleared.authenticationBlocked)
        XCTAssertEqual(cleared.consecutiveFailures, 0)
        XCTAssertNotNil(UsageRefreshPolicy.nextRefresh(state: cleared, activity: .active))
    }

    /// A user who logs in again is picked up without having to say they did.
    func testASuccessClearsTheBlock() {
        let blocked = UsageRefreshState(lastAttempt: now, consecutiveFailures: 3, authenticationBlocked: true)
        let outcome = UsageFetchOutcome(
            snapshot: UsageSnapshot(provider: .codex, source: .codexOAuthAPI, updatedAt: now),
            attempts: []
        )
        let updated = UsageRefreshPolicy.after(state: blocked, outcome: outcome, now: now)
        XCTAssertFalse(updated.authenticationBlocked)
        XCTAssertEqual(updated.consecutiveFailures, 0)
        XCTAssertEqual(updated.lastSuccess, now)
    }

    func testAnAuthenticationFailureSetsTheBlock() {
        let outcome = UsageFetchOutcome(
            snapshot: nil,
            attempts: [UsageAttempt(
                source: .codexOAuthAPI, skipped: false, succeeded: false,
                error: UsageFetchError(.credentialsExpired), duration: 0
            )]
        )
        let updated = UsageRefreshPolicy.after(state: .init(), outcome: outcome, now: now)
        XCTAssertTrue(updated.authenticationBlocked)
    }

    /// A timeout is not an authentication problem and must not be treated as
    /// one, or a flaky network would silently stop the monitor for good.
    func testATransientFailureDoesNotSetTheBlock() {
        let outcome = UsageFetchOutcome(
            snapshot: nil,
            attempts: [UsageAttempt(
                source: .codexOAuthAPI, skipped: false, succeeded: false,
                error: UsageFetchError(.timedOut), duration: 0
            )]
        )
        let updated = UsageRefreshPolicy.after(state: .init(), outcome: outcome, now: now)
        XCTAssertFalse(updated.authenticationBlocked)
        XCTAssertEqual(updated.consecutiveFailures, 1)
    }

    // MARK: - Resets

    /// A reset is the one moment the numbers are known to move, so it is worth
    /// waiting for rather than polling through.
    func testARefreshIsScheduledJustAfterAReset() {
        let reset = now.addingTimeInterval(120)
        let state = UsageRefreshState(lastAttempt: now, lastSuccess: now, nextReset: reset)
        XCTAssertEqual(
            UsageRefreshPolicy.nextRefresh(state: state, activity: .active),
            reset.addingTimeInterval(UsageRefreshPolicy.postResetDelay)
        )
    }

    /// A reset far beyond the ordinary cadence must not delay the poll.
    func testADistantResetDoesNotPushTheScheduleOut() {
        let state = UsageRefreshState(
            lastAttempt: now, lastSuccess: now, nextReset: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(
            UsageRefreshPolicy.nextRefresh(state: state, activity: .active),
            now.addingTimeInterval(UsageRefreshPolicy.activeInterval)
        )
    }

    func testTheEarliestResetIsTheOneRecorded() {
        let snapshot = UsageSnapshot(
            provider: .claude,
            primaryWindow: UsageWindow(
                id: "p", title: "Session", usedPercent: 1, resetsAt: now.addingTimeInterval(600)
            ),
            secondaryWindow: UsageWindow(
                id: "s", title: "Week", usedPercent: 1, resetsAt: now.addingTimeInterval(60)
            ),
            source: .claudeOAuthAPI, updatedAt: now
        )
        let updated = UsageRefreshPolicy.after(
            state: .init(), outcome: UsageFetchOutcome(snapshot: snapshot, attempts: []), now: now
        )
        XCTAssertEqual(updated.nextReset, now.addingTimeInterval(60))
    }
}
