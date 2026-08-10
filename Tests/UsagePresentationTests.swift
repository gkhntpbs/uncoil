import XCTest
@testable import Uncoil

/// What the chip and the card actually say.
///
/// Worth testing separately from the model because this is where a correct
/// snapshot can still be described wrongly — a countdown that runs backwards, a
/// figure that claims to be current, an "unavailable" that reads as empty.
final class UsagePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Severity

    /// Three bands, and the boundaries are inclusive downwards so that exactly
    /// 15% is already critical rather than one point away from it.
    func testTheBandsSplitWhereTheyAreDocumented() {
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(100), .healthy)
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(41), .healthy)
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(40), .low)
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(16), .low)
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(15), .critical)
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(0), .critical)
    }

    /// No number is not a band. Tinting an unknown limit green or red would be
    /// answering a question nobody could answer.
    func testAnUnknownLimitHasNoBand() {
        XCTAssertEqual(UsageDisplay.Severity.forRemaining(nil), .unknown)
        XCTAssertEqual(UsageDisplay.severity(of: nil), .unknown)
        XCTAssertEqual(
            UsageDisplay.severity(of: .unavailable(
                provider: .claude, reason: .noCredentials, source: .cache, updatedAt: now
            )),
            .unknown
        )
    }

    /// The chip shows whichever window binds first, not the first one listed.
    func testTheHeadlineIsTheWindowClosestToRunningOut() {
        let snapshot = UsageSnapshot(
            provider: .claude,
            primaryWindow: UsageWindow(id: "s", title: "Session", usedPercent: 34),
            secondaryWindow: UsageWindow(id: "w", title: "Week", usedPercent: 78),
            extraWindows: [UsageWindow(id: "o", title: "Opus", usedPercent: 92)],
            source: .claudeOAuthAPI, updatedAt: now
        )
        XCTAssertEqual(UsageDisplay.headlineRemaining(snapshot), 8)
        XCTAssertEqual(UsageDisplay.severity(of: snapshot), .critical)
    }

    /// Rounded down: a limit is not a place to be generous with rounding, and
    /// the number is there to warn.
    func testTheHeadlineRoundsDown() {
        let snapshot = UsageSnapshot(
            provider: .codex,
            primaryWindow: UsageWindow(id: "s", title: "Session", usedPercent: 91.2),
            source: .codexOAuthAPI, updatedAt: now
        )
        XCTAssertEqual(UsageDisplay.headlineRemaining(snapshot), 8)
    }

    func testThereIsNoHeadlineWithoutAWindow() {
        XCTAssertNil(UsageDisplay.headlineRemaining(nil))
        XCTAssertNil(UsageDisplay.headlineRemaining(.unavailable(
            provider: .codex, reason: .planReportsNoQuota, source: .cache, updatedAt: now
        )))
    }

    // MARK: - Time

    func testResetTimesAreCoarseAndReadable() {
        XCTAssertEqual(
            UsageDisplay.relativeReset(now.addingTimeInterval(2 * 3600 + 14 * 60), now: now),
            "in 2h 14m"
        )
        XCTAssertEqual(UsageDisplay.relativeReset(now.addingTimeInterval(3 * 3600), now: now), "in 3h")
        XCTAssertEqual(UsageDisplay.relativeReset(now.addingTimeInterval(3 * 86_400), now: now), "in 3d")
        XCTAssertEqual(UsageDisplay.relativeReset(now.addingTimeInterval(300), now: now), "in 5m")
    }

    /// A reset already past reads as due, not as a negative number. The
    /// provider's clock and ours are not the same clock, and "-4s" would be
    /// reporting that difference as news.
    func testAResetInThePastReadsAsDue() {
        XCTAssertEqual(UsageDisplay.relativeReset(now.addingTimeInterval(-600), now: now), "now")
        XCTAssertEqual(UsageDisplay.relativeReset(now.addingTimeInterval(-1), now: now), "now")
    }

    func testFreshnessIsStatedInThePast() {
        XCTAssertEqual(UsageDisplay.relativeAge(now.addingTimeInterval(-140), now: now), "2m ago")
        XCTAssertEqual(UsageDisplay.relativeAge(now.addingTimeInterval(-10), now: now), "just now")
    }

    /// An instant is preferred; where the provider gave only a phrase, its own
    /// words are quoted rather than parsed into a date on a guess.
    func testAWindowWithOnlyAPhraseKeepsThePhrase() {
        let window = UsageWindow(
            id: "w", title: "Session", usedPercent: 20, resetNote: "Resets 3:00pm"
        )
        XCTAssertEqual(UsageDisplay.resetLine(window, now: now), "Resets 3:00pm")
    }

    func testAWindowWithAnInstantCountsDown() {
        let window = UsageWindow(
            id: "w", title: "Session", usedPercent: 20,
            resetsAt: now.addingTimeInterval(3600), resetNote: "Resets 3:00pm"
        )
        XCTAssertEqual(UsageDisplay.resetLine(window, now: now), "Resets in 1h")
    }

    func testAWindowWithNeitherSaysNothing() {
        XCTAssertNil(UsageDisplay.resetLine(
            UsageWindow(id: "w", title: "Session", usedPercent: 20), now: now
        ))
    }

    // MARK: - Provenance

    /// "From your Claude account · 1m ago" under the words "No usage figures"
    /// claims a reading that was never made.
    func testAnUnavailableSnapshotSaysItWasCheckedRatherThanRead() {
        let snapshot = UsageSnapshot.unavailable(
            provider: .gemini, reason: .accountTierUnsupported,
            source: .geminiCodeAssistAPI, updatedAt: now.addingTimeInterval(-90)
        )
        XCTAssertEqual(UsageDisplay.provenance(snapshot, now: now), "Checked 1m ago")
    }

    func testAReadSnapshotNamesItsSource() {
        let snapshot = UsageSnapshot(
            provider: .codex,
            primaryWindow: UsageWindow(id: "s", title: "Session", usedPercent: 10),
            source: .codexAppServerRPC, updatedAt: now.addingTimeInterval(-300)
        )
        XCTAssertEqual(
            UsageDisplay.provenance(snapshot, now: now),
            "from the Codex app-server · 5m ago"
        )
    }

    // MARK: - Explanations

    /// Each reason is a different situation and only two of them are the user's
    /// to fix. One shared sentence would send someone to check a login that is
    /// working perfectly well.
    func testEveryReasonHasItsOwnSentence() {
        let reasons: [UsageUnavailability] = [
            .noCredentials, .credentialsRejected, .planReportsNoQuota,
            .accountTierUnsupported, .authenticationTypeUnsupported,
            .providerUnsupported, .allStrategiesFailed,
        ]
        let sentences = reasons.map { UsageDisplay.explanation($0, provider: .claude) }
        XCTAssertEqual(Set(sentences).count, reasons.count)
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
        }
        let shortForms = reasons.map(UsageDisplay.shortReason)
        XCTAssertEqual(Set(shortForms).count, reasons.count)
    }

    /// The two that are not the user's fault say so, because the natural
    /// reading of "no usage figures" is "something of mine is broken".
    func testTheReasonsThatAreNotTheUsersFaultSayNothingIsWrong() {
        XCTAssertTrue(
            UsageDisplay.explanation(.planReportsNoQuota, provider: .claude)
                .contains("Nothing is wrong")
        )
        XCTAssertTrue(
            UsageDisplay.explanation(.accountTierUnsupported, provider: .gemini)
                .contains("unaffected")
        )
    }

    // MARK: - The tooltip

    func testTheTooltipCarriesTheBindingWindowAndItsReset() {
        let snapshot = UsageSnapshot(
            provider: .claude,
            primaryWindow: UsageWindow(id: "s", title: "Session limit", usedPercent: 34),
            secondaryWindow: UsageWindow(
                id: "w", title: "Weekly limit", usedPercent: 92,
                resetsAt: now.addingTimeInterval(3 * 86_400)
            ),
            source: .claudeOAuthAPI, updatedAt: now
        )
        let help = UsageDisplay.chipHelp(snapshot, now: now)
        XCTAssertTrue(help.contains("Weekly limit"))
        XCTAssertTrue(help.contains("8% left"))
        XCTAssertTrue(help.contains("in 3d"))
    }

    func testTheTooltipSaysWhenAFigureIsBeingKeptRatherThanRefreshed() {
        let snapshot = UsageSnapshot(
            provider: .codex,
            primaryWindow: UsageWindow(id: "s", title: "Session limit", usedPercent: 50),
            source: .codexOAuthAPI, updatedAt: now.addingTimeInterval(-1_200)
        ).markedStale(error: "timedOut")
        XCTAssertTrue(UsageDisplay.chipHelp(snapshot, now: now).contains("not refreshed"))
    }

    func testTheTooltipExplainsAnEmptyChip() {
        let snapshot = UsageSnapshot.unavailable(
            provider: .codex, reason: .noCredentials, source: .cache, updatedAt: now
        )
        let help = UsageDisplay.chipHelp(snapshot, now: now)
        XCTAssertTrue(help.contains("unavailable"))
        XCTAssertTrue(help.contains("Not signed in"))
        // Never a number.
        XCTAssertFalse(help.contains("%"))
    }

    func testTheTooltipBeforeAnythingHasBeenReadSaysSo() {
        XCTAssertEqual(UsageDisplay.chipHelp(nil, now: now), "Usage has not been read yet.")
    }
}
