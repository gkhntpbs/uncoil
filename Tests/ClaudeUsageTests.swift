import XCTest
@testable import Uncoil

/// Claude's usage payload.
final class ClaudeUsageParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func snapshot(_ text: String) throws -> UsageSnapshot {
        try ClaudeUsageParser.snapshot(
            from: try json(text), accountID: nil, identity: nil,
            source: .claudeOAuthAPI, now: now
        )
    }

    func testTheSessionAndWeekWindowsAreRead() throws {
        let snapshot = try snapshot("""
        {
          "five_hour": {"utilization": 0.34, "resets_at": "2026-08-10T18:00:00Z"},
          "seven_day": {"utilization": 0.71, "resets_at": "2026-08-14T00:00:00Z"}
        }
        """)
        XCTAssertEqual(try XCTUnwrap(snapshot.primaryWindow).usedPercent, 34, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.secondaryWindow).remainingPercent, 29, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.primaryWindow?.resetsAt,
            ISO8601DateFormatter().date(from: "2026-08-10T18:00:00Z")
        )
    }

    func testAPercentageFormIsReadToo() throws {
        let snapshot = try snapshot(#"{"five_hour": {"used_percent": 34}}"#)
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 34)
    }

    /// The case the spec calls out: losing the whole provider because the
    /// short-term half is absent would hide a limit that is present.
    func testTheWeeklyWindowSurvivesAMissingSessionWindow() throws {
        let snapshot = try snapshot(#"{"seven_day": {"utilization": 0.5}}"#)
        XCTAssertNil(snapshot.primaryWindow)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 50)
        XCTAssertTrue(snapshot.hasQuota)
    }

    /// Model-scoped weeks are optional. A plan that does not separate them has
    /// neither, and that must not read as a fault.
    func testModelScopedWeeksAreOptional() throws {
        let without = try snapshot(#"{"five_hour": {"utilization": 0.1}}"#)
        XCTAssertTrue(without.extraWindows.isEmpty)

        let with = try snapshot("""
        {
          "five_hour": {"utilization": 0.1},
          "seven_day_sonnet": {"utilization": 0.2},
          "seven_day_opus": {"utilization": 0.95}
        }
        """)
        XCTAssertEqual(with.extraWindows.count, 2)
        XCTAssertEqual(with.mostConstrainedWindow?.modelID, "opus")
        XCTAssertEqual(with.mostConstrainedWindow?.title, "Weekly limit · Opus")
    }

    /// The same Opus week arrives twice on some plans, once under its own key
    /// and once in the list. Two rows would read as two separate limits.
    func testAScopedLimitAlreadyShownIsNotShownTwice() throws {
        let snapshot = try snapshot("""
        {
          "five_hour": {"utilization": 0.1},
          "seven_day_opus": {"utilization": 0.9},
          "limits": [{"model": "opus", "weekly_scoped": {"utilization": 0.9}}]
        }
        """)
        XCTAssertEqual(snapshot.extraWindows.filter { $0.modelID == "opus" }.count, 1)
    }

    /// A model nobody has heard of yet still gets a window.
    func testAnUnknownModelInTheListIsKept() throws {
        let snapshot = try snapshot("""
        {
          "five_hour": {"utilization": 0.1},
          "limits": [{"model": "claude-next", "weekly_scoped": {"utilization": 0.4}}]
        }
        """)
        XCTAssertEqual(snapshot.extraWindows.first?.modelID, "claude-next")
    }

    /// `extra_usage` is spend. It says nothing about how much of the limit is
    /// left, and the moment the two are added the number cannot be read at all.
    func testExtraUsageIsCreditsNotQuota() throws {
        let snapshot = try snapshot("""
        {"five_hour": {"utilization": 0.1}, "extra_usage": {"remaining": 20.0, "currency": "USD"}}
        """)
        XCTAssertEqual(snapshot.credits?.balance, 20)
        XCTAssertEqual(snapshot.allWindows.count, 1)
    }

    /// Some organisation and education subscriptions authenticate and report no
    /// numbers. That is a fact about the plan, not a failure, and it must never
    /// become a fabricated percentage.
    func testAnAccountWithNoQuotaSaysSoRatherThanShowingZero() throws {
        let snapshot = try snapshot(#"{"account": {"plan": "enterprise"}}"#)
        XCTAssertEqual(snapshot.unavailable, .planReportsNoQuota)
        XCTAssertFalse(snapshot.hasQuota)
    }

    func testIdentityIsReadFromAProfile() throws {
        let identity = ClaudeUsageParser.identity(from: try json("""
        {"account": {"email": "a@b.com"}, "organization": {"name": "Acme", "billing_type": "max"}}
        """))
        XCTAssertEqual(identity?.email, "a@b.com")
        XCTAssertEqual(identity?.organization, "Acme")
        XCTAssertEqual(identity?.plan, "max")
    }
}

// MARK: - Credentials

final class ClaudeAuthTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testAClaudeOAuthCredentialIsRead() throws {
        let auth = try ClaudeAuth.parse(try json("""
        {"claudeAiOauth": {"accessToken": "tok", "expiresAt": 1700000000000, "scopes": ["user:profile"]}}
        """))
        XCTAssertEqual(auth.accessToken, "tok")
        XCTAssertEqual(auth.expiry, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(auth.scopes, ["user:profile"])
    }

    /// The Keychain item can hold OAuth state for an MCP server the user
    /// authorised, in the same JSON, under a different key. Sending that token
    /// to Anthropic's API fails in a way that reads as "your Claude login is
    /// broken", which is the wrong thing to tell someone.
    func testMCPOAuthStateIsNotMistakenForAClaudeLogin() throws {
        let raw = try json("""
        {"mcpOAuth": {"some-server": {"accessToken": "not-ours", "expiresAt": 1700000000000}}}
        """)
        XCTAssertThrowsError(try ClaudeAuth.parse(raw)) { error in
            XCTAssertEqual((error as? UsageFetchError)?.kind, .credentialsMissing)
        }
    }

    func testAScopeStringIsSplitIntoScopes() throws {
        let auth = try ClaudeAuth.parse(try json("""
        {"claudeAiOauth": {"accessToken": "tok", "scope": "user:profile user:inference"}}
        """))
        XCTAssertEqual(auth.scopes, ["user:profile", "user:inference"])
    }
}

// MARK: - The CLI panel

/// The `/usage` panel parser.
///
/// The fixtures below are written from the shape the panel is documented to
/// have — two labelled sections and a percentage under each — not captured from
/// a real terminal. They are therefore a test of the parser's *rules*: that it
/// reads the label it was asked for, refuses to borrow a number from the next
/// section, and produces nothing rather than a guess.
final class ClaudeUsagePanelParserTests: XCTestCase {

    func testEscapeSequencesAreRemoved() {
        let raw = "\u{001B}[1mCurrent session\u{001B}[0m\r\n\u{001B}[38;5;33m████\u{001B}[0m 23% used"
        let parsed = ClaudeUsagePanelParser.parse(raw)
        XCTAssertEqual(parsed.session?.usedPercent, 23)
    }

    func testBothSectionsAreRead() {
        let raw = """
        Current session
        ████░░░░░░ 23% used
        Resets 3:00pm (Europe/Istanbul)

        Current week (all models)
        ██░░░░░░░░ 12% used
        Resets Nov 5
        """
        let parsed = ClaudeUsagePanelParser.parse(raw)
        XCTAssertEqual(parsed.session?.usedPercent, 23)
        XCTAssertEqual(parsed.session?.resetNote, "Resets 3:00pm (Europe/Istanbul)")
        XCTAssertEqual(parsed.week?.usedPercent, 12)
        XCTAssertEqual(parsed.week?.resetNote, "Resets Nov 5")
    }

    /// "77% left" and "23% used" describe the same account. Reading either as
    /// the other inverts the number a threshold is compared against.
    func testAPanelStatedAsRemainingIsNormalisedToUsed() {
        let parsed = ClaudeUsagePanelParser.parse("""
        Current session
        77% left
        """)
        XCTAssertEqual(parsed.session?.usedPercent, 23)
        XCTAssertEqual(parsed.session?.remainingPercent, 77)
    }

    /// The failure that would look entirely plausible: a missing section
    /// silently borrowing the number belonging to the one after it.
    func testAMissingSectionDoesNotBorrowTheNextSectionsNumber() {
        let parsed = ClaudeUsagePanelParser.parse("""
        Current session

        Current week
        12% used
        """)
        XCTAssertNil(parsed.session)
        XCTAssertEqual(parsed.week?.usedPercent, 12)
    }

    func testModelLinesBecomeTheirOwnWindows() {
        let parsed = ClaudeUsagePanelParser.parse("""
        Current week (all models)
        12% used
        Opus 47% used
        Sonnet 8% used
        """)
        XCTAssertEqual(parsed.extras.count, 2)
        XCTAssertEqual(parsed.extras.first?.modelID, "opus")
        XCTAssertEqual(parsed.extras.first?.usedPercent, 47)
    }

    /// A panel that cannot be read yields nothing. It never yields a zero,
    /// which is what an empty result would mean to everything downstream.
    func testAnUnreadablePanelYieldsNoWindows() {
        let parsed = ClaudeUsagePanelParser.parse("Welcome to Claude Code!\n\n> ")
        XCTAssertNil(parsed.session)
        XCTAssertNil(parsed.week)
        XCTAssertTrue(parsed.extras.isEmpty)
        XCTAssertNil(parsed.failure)
    }

    /// An expired login is worth stopping and reporting; a panel that merely
    /// did not render is worth trying again. Collapsing the two either nags
    /// about a transient miss or stays quiet about a login that has to be
    /// redone.
    func testAnExpiredLoginIsReportedAsSuch() {
        let parsed = ClaudeUsagePanelParser.parse("Your credentials have expired. Please run /login.")
        XCTAssertEqual(parsed.failure?.kind, .credentialsExpired)
        XCTAssertNil(parsed.session)
    }

    func testAPlanWithoutUsageLimitsIsReportedAsSuch() {
        let parsed = ClaudeUsagePanelParser.parse("Usage is not available for your plan.")
        XCTAssertEqual(parsed.failure?.kind, .planReportsNoQuota)
        // Terminal: another route would say the same thing.
        XCTAssertEqual(parsed.failure?.continuesToFallback, false)
    }

    func testThePanelIsDetectedFromEitherLabel() {
        XCTAssertTrue(ClaudeUsagePanelParser.panelIsPresent("… Current session …"))
        XCTAssertTrue(ClaudeUsagePanelParser.panelIsPresent("\u{001B}[1mCurrent week\u{001B}[0m"))
        XCTAssertFalse(ClaudeUsagePanelParser.panelIsPresent("Welcome to Claude Code"))
    }
}
