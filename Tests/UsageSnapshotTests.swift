import XCTest
@testable import Uncoil

/// The normalised model, and the invariants the rest of the layer leans on.
///
/// These matter more than they look. A percentage here eventually decides
/// whether work is handed to another agent, so "what does this type do with a
/// number it was not given" is the question every provider parser is written
/// against.
final class UsageSnapshotTests: XCTestCase {

    // MARK: - The two halves

    func testRemainingIsDerivedFromUsed() {
        let window = UsageWindow(id: "w", title: "Session", usedPercent: 87.5)
        XCTAssertEqual(window.remainingPercent, 12.5, accuracy: 0.001)
    }

    func testAFractionOfRemainingBecomesUsed() {
        let window = UsageWindow.fromRemainingFraction(
            id: "w", title: "Pro", remainingFraction: 0.83
        )
        XCTAssertEqual(window.usedPercent, 17, accuracy: 0.001)
        XCTAssertEqual(window.remainingPercent, 83, accuracy: 0.001)
    }

    /// Zero remaining is a real reading and has to survive intact — it is the
    /// state the whole feature exists to notice.
    func testZeroRemainingIsPreserved() {
        let window = UsageWindow(id: "w", title: "Session", usedPercent: 100)
        XCTAssertEqual(window.remainingPercent, 0)
    }

    func testFullyUnusedIsPreserved() {
        let window = UsageWindow.fromRemainingFraction(
            id: "w", title: "Pro", remainingFraction: 1
        )
        XCTAssertEqual(window.usedPercent, 0)
        XCTAssertEqual(window.remainingPercent, 100)
    }

    /// A provider that reports 103% has not given a percentage. Clamping is the
    /// only reading that does not produce a negative remainder downstream.
    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(UsageWindow(id: "a", title: "t", usedPercent: 143).usedPercent, 100)
        XCTAssertEqual(UsageWindow(id: "b", title: "t", usedPercent: -12).usedPercent, 0)
        XCTAssertEqual(UsageWindow(id: "d", title: "t", usedPercent: .infinity).usedPercent, 100)
    }

    /// A value that is not a number should never reach the window — the reader
    /// drops it first. The backstop errs towards exhausted rather than plenty:
    /// an early warning about a limit that is fine costs a glance, while a
    /// fabricated "100% remaining" would let work run into a wall the app said
    /// was not there.
    func testANonNumberIsNotReadAsAFullAllowance() throws {
        let json = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"used_percent": "not a number"}"#.utf8)
        )
        XCTAssertNil(UsageJSON.window(
            try XCTUnwrap(json.objectValue), id: "w", title: "t", now: Date()
        ))
        XCTAssertEqual(UsageWindow(id: "c", title: "t", usedPercent: .nan).remainingPercent, 0)
    }

    // MARK: - Which window binds

    /// An account is limited by whichever window runs out first, whether that
    /// is the session, the week, or one model's own allowance.
    func testTheMostConstrainedWindowIsTheOneWithLeastLeft() {
        let snapshot = UsageSnapshot(
            provider: .claude,
            primaryWindow: UsageWindow(id: "session", title: "Session", usedPercent: 40),
            secondaryWindow: UsageWindow(id: "week", title: "Week", usedPercent: 60),
            extraWindows: [UsageWindow(id: "opus", title: "Opus", usedPercent: 92)],
            source: .claudeOAuthAPI,
            updatedAt: .init(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.mostConstrainedWindow?.id, "opus")
        XCTAssertEqual(snapshot.allWindows.count, 3)
    }

    // MARK: - Unavailable is not a number

    /// The distinction the whole layer is arranged around: an account we cannot
    /// read is not an account at 0%, and not one at 100% either.
    func testAnUnavailableSnapshotCarriesNoWindows() {
        let snapshot = UsageSnapshot.unavailable(
            provider: .gemini,
            reason: .accountTierUnsupported,
            source: .geminiCodeAssistAPI,
            updatedAt: .init(timeIntervalSince1970: 0)
        )
        XCTAssertFalse(snapshot.hasQuota)
        XCTAssertNil(snapshot.mostConstrainedWindow)
        XCTAssertEqual(snapshot.unavailable, .accountTierUnsupported)
    }

    // MARK: - Staleness

    func testMarkingStaleKeepsTheNumbersAndAddsTheReason() {
        let original = UsageSnapshot(
            provider: .codex,
            primaryWindow: UsageWindow(id: "p", title: "Session", usedPercent: 20),
            source: .codexOAuthAPI,
            updatedAt: .init(timeIntervalSince1970: 1000)
        )
        let stale = original.markedStale(error: "timedOut")

        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.error, "timedOut")
        XCTAssertEqual(stale.primaryWindow?.usedPercent, 20)
        // The numbers are as old as they were; the failed refresh did not make
        // them newer.
        XCTAssertEqual(stale.updatedAt, original.updatedAt)
    }

    func testAgeIsMeasuredFromWhenTheNumbersWereTaken() {
        let snapshot = UsageSnapshot(
            provider: .codex, source: .codexOAuthAPI,
            updatedAt: .init(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(snapshot.age(now: .init(timeIntervalSince1970: 1_600)), 600)
    }

    // MARK: - Round trip

    /// The snapshot is cached, so it has to survive being written and read.
    func testASnapshotSurvivesACodableRoundTrip() throws {
        let snapshot = UsageSnapshot(
            provider: .claude,
            accountID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
            identity: UsageIdentity(email: "x@example.com", plan: "max", organization: nil),
            primaryWindow: UsageWindow(
                id: "p", title: "Session", usedPercent: 12,
                resetsAt: .init(timeIntervalSince1970: 5_000), resetNote: "Resets 3:00pm",
                windowMinutes: 300
            ),
            credits: UsageCredits(balance: 4.5, currency: "USD", summary: nil),
            source: .claudeOAuthAPI,
            updatedAt: .init(timeIntervalSince1970: 1_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data), snapshot)
    }
}
