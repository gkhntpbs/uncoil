import XCTest
@testable import Uncoil

/// Codex's rate-limit payloads, and the `auth.json` the request is made with.
///
/// The fixtures are constructed from the documented shape rather than captured
/// from a live account, and they are written to exercise the readings that
/// differ from one another — a window missing, a window at zero, a model-scoped
/// extra — rather than to assert one blessed layout.
final class CodexUsageParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func snapshot(_ text: String) throws -> UsageSnapshot {
        try CodexUsageParser.snapshot(
            from: try json(text), accountID: nil, identity: nil,
            source: .codexOAuthAPI, now: now
        )
    }

    // MARK: - The real payload

    /// The shape the endpoint actually returns, taken from a live account with
    /// every value replaced by a representative one.
    ///
    /// It differs from the documented shape in three ways that all cost
    /// something, and none of which any invented fixture would have found:
    /// the window's length is in *seconds* under a different name, the reset is
    /// offered as `reset_after_seconds` as well as an epoch, and the account's
    /// own email and plan sit at the top level beside the limits.
    private static let liveShape = """
    {
      "account_id": "acct_1",
      "email": "someone@example.com",
      "plan_type": "pro",
      "additional_rate_limits": null,
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "limit_window_seconds": 18000,
          "reset_after_seconds": 9000,
          "reset_at": 1700009000,
          "used_percent": 3
        },
        "secondary_window": null
      },
      "credits": {
        "balance": "12.50",
        "has_credits": true,
        "unlimited": false
      }
    }
    """

    func testTheLivePayloadIsReadInFull() throws {
        let snapshot = try snapshot(Self.liveShape)

        // Seconds, not minutes: five hours, and named as such.
        XCTAssertEqual(snapshot.primaryWindow?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primaryWindow?.title, "5-hour limit")
        XCTAssertEqual(snapshot.primaryWindow?.remainingPercent, 97)
        XCTAssertEqual(
            snapshot.primaryWindow?.resetsAt, Date(timeIntervalSince1970: 1_700_009_000)
        )
        // A null window is simply absent, not a window at zero.
        XCTAssertNil(snapshot.secondaryWindow)
        XCTAssertTrue(snapshot.extraWindows.isEmpty)
        // The balance arrives as a string; a numeric string is still a number.
        XCTAssertEqual(snapshot.credits?.balance, 12.5)
    }

    /// The account's own details are in the usage response. Throwing them away
    /// left the card unable to say whose numbers it was showing.
    func testTheLivePayloadCarriesTheAccountsIdentity() throws {
        let identity = try XCTUnwrap(CodexUsageParser.identity(from: try json(Self.liveShape)))
        XCTAssertEqual(identity.email, "someone@example.com")
        XCTAssertEqual(identity.plan, "pro")
    }

    /// When only a relative reset is offered, it is anchored to the reading.
    func testAResetAfterSecondsIsRead() throws {
        let snapshot = try snapshot("""
        {"rate_limit": {"primary_window": {"used_percent": 10, "reset_after_seconds": 600}}}
        """)
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt, now.addingTimeInterval(600))
    }

    // MARK: - The ordinary case

    func testBothWindowsAreRead() throws {
        let snapshot = try snapshot("""
        {
          "rate_limit": {
            "primary_window":   {"used_percent": 23.5, "window_minutes": 300,   "resets_in_seconds": 7200},
            "secondary_window": {"used_percent": 61.0, "window_minutes": 10080, "resets_in_seconds": 200000}
          }
        }
        """)

        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 23.5)
        XCTAssertEqual(snapshot.primaryWindow?.title, "5-hour limit")
        XCTAssertEqual(snapshot.primaryWindow?.resetsAt, now.addingTimeInterval(7200))
        XCTAssertEqual(snapshot.secondaryWindow?.remainingPercent, 39)
        XCTAssertEqual(snapshot.secondaryWindow?.title, "Weekly limit")
        XCTAssertNil(snapshot.unavailable)
    }

    /// The app-server returns the same thing without the wrapper.
    func testAFlatPayloadIsReadTheSameWay() throws {
        let snapshot = try snapshot("""
        {"primaryWindow": {"usedPercent": 10}, "secondaryWindow": {"usedPercent": 20}}
        """)
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 10)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 20)
    }

    // MARK: - Partial payloads

    /// A weekly plan with no session block still has a limit, and it is the one
    /// that binds. Dropping the provider over the absent half would hide it.
    func testAMissingSessionWindowKeepsTheWeeklyOne() throws {
        let snapshot = try snapshot(#"{"rate_limit": {"secondary_window": {"used_percent": 61}}}"#)
        XCTAssertNil(snapshot.primaryWindow)
        XCTAssertEqual(snapshot.secondaryWindow?.usedPercent, 61)
        XCTAssertTrue(snapshot.hasQuota)
    }

    func testAMissingWeeklyWindowKeepsTheSessionOne() throws {
        let snapshot = try snapshot(#"{"rate_limit": {"primary_window": {"used_percent": 5}}}"#)
        XCTAssertEqual(snapshot.primaryWindow?.usedPercent, 5)
        XCTAssertNil(snapshot.secondaryWindow)
    }

    /// An authenticated account the provider reports nothing for. Recorded as a
    /// reason, never as a number — and terminal, so the pipeline does not spend
    /// a process asking a second route the same question.
    func testAnEmptyPayloadIsUnavailableRatherThanZero() throws {
        let snapshot = try snapshot(#"{"rate_limit": {}}"#)
        XCTAssertEqual(snapshot.unavailable, .planReportsNoQuota)
        XCTAssertFalse(snapshot.hasQuota)
        XCTAssertNil(snapshot.primaryWindow)
    }

    func testAnExhaustedWindowIsReportedAsExhausted() throws {
        let snapshot = try snapshot(#"{"rate_limit": {"primary_window": {"used_percent": 100}}}"#)
        XCTAssertEqual(snapshot.primaryWindow?.remainingPercent, 0)
        XCTAssertNil(snapshot.unavailable)
    }

    func testAnUntouchedWindowIsReportedAsFull() throws {
        let snapshot = try snapshot(#"{"rate_limit": {"primary_window": {"used_percent": 0}}}"#)
        XCTAssertEqual(snapshot.primaryWindow?.remainingPercent, 100)
        XCTAssertNil(snapshot.unavailable)
    }

    func testAPayloadThatIsNotAnObjectFails() {
        XCTAssertThrowsError(try snapshot("[1, 2, 3]")) { error in
            XCTAssertEqual((error as? UsageFetchError)?.kind, .malformedResponse)
        }
    }

    // MARK: - Extra limits

    /// The list is where a limit that did not exist when this was written will
    /// appear, so it is kept rather than folded into the two named windows.
    func testModelScopedLimitsAreKept() throws {
        let snapshot = try snapshot("""
        {
          "rate_limit": {"primary_window": {"used_percent": 10}},
          "additional_rate_limits": [
            {"model": "gpt-5-codex", "used_percent": 88, "window_minutes": 10080},
            {"name": "Deep research", "window": {"used_percent": 4}}
          ]
        }
        """)

        XCTAssertEqual(snapshot.extraWindows.count, 2)
        XCTAssertEqual(snapshot.extraWindows.first?.modelID, "gpt-5-codex")
        XCTAssertEqual(snapshot.extraWindows.first?.title, "gpt-5-codex limit")
        XCTAssertEqual(snapshot.extraWindows.last?.title, "Deep research")
        // The account is limited by whichever binds first, and here that is the
        // model rather than the session.
        XCTAssertEqual(snapshot.mostConstrainedWindow?.modelID, "gpt-5-codex")
    }

    /// A payload with nothing but extras is still a payload with quota.
    func testExtrasAloneStillCount() throws {
        let snapshot = try snapshot("""
        {"additional_rate_limits": [{"model": "o3", "used_percent": 50}]}
        """)
        XCTAssertTrue(snapshot.hasQuota)
        XCTAssertNil(snapshot.unavailable)
    }

    // MARK: - Credits and identity

    /// Money is kept out of the windows: adding a balance to a percentage
    /// answers "how much is left" in two currencies at once.
    func testCreditsAreReadIntoTheirOwnField() throws {
        let snapshot = try snapshot("""
        {
          "rate_limit": {"primary_window": {"used_percent": 10}},
          "credits": {"balance": 12.5, "currency": "USD"}
        }
        """)
        XCTAssertEqual(snapshot.credits?.balance, 12.5)
        XCTAssertEqual(snapshot.credits?.currency, "USD")
        XCTAssertEqual(snapshot.allWindows.count, 1)
    }

    func testIdentityIsReadFromAnAccountReply() throws {
        let identity = CodexUsageParser.identity(from: try json("""
        {"account": {"email": "someone@example.com", "plan": "pro"}}
        """))
        XCTAssertEqual(identity?.email, "someone@example.com")
        XCTAssertEqual(identity?.plan, "pro")
    }

    func testAnAccountReplyWithNothingUsableYieldsNoIdentity() throws {
        XCTAssertNil(CodexUsageParser.identity(from: try json(#"{"account": {}}"#)))
    }
}

/// `auth.json`, which decides whether the preferred route can run at all.
final class CodexAuthTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testTokensAreReadFromTheNestedShape() throws {
        let auth = try CodexAuth.parse(try json("""
        {"tokens": {"access_token": "abc", "account_id": "acct_1", "expires_at": 1700000000000}}
        """))
        XCTAssertEqual(auth.accessToken, "abc")
        XCTAssertEqual(auth.accountID, "acct_1")
        XCTAssertEqual(auth.expiry, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A user who has not logged in again since an upgrade still has a valid
    /// login; the older layout has to keep working.
    func testTokensAreAlsoReadFromTheFlatShape() throws {
        let auth = try CodexAuth.parse(try json(#"{"access_token": "abc"}"#))
        XCTAssertEqual(auth.accessToken, "abc")
    }

    /// An API-key-only file is a working configuration that this route cannot
    /// answer for: the usage endpoint is tied to the ChatGPT login, not a key.
    func testAnApiKeyOnlyFileIsReportedAsNoCredential() throws {
        XCTAssertThrowsError(try CodexAuth.parse(try json(#"{"OPENAI_API_KEY": "sk-x"}"#))) { error in
            XCTAssertEqual((error as? UsageFetchError)?.kind, .credentialsMissing)
        }
    }
}
