import XCTest
@testable import Uncoil

/// Gemini's quota buckets, and the refusal that must never be read as an empty
/// allowance.
final class GeminiUsageParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func snapshot(_ text: String) throws -> UsageSnapshot {
        try GeminiUsageParser.snapshot(
            from: try json(text), accountID: nil, identity: nil,
            source: .geminiCodeAssistAPI, now: now
        )
    }

    func testAFractionRemainingBecomesAPercentageUsed() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [{"modelId": "gemini-2.5-pro", "remainingFraction": 0.83}]}
        """)
        XCTAssertEqual(try XCTUnwrap(snapshot.primaryWindow).remainingPercent, 83, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.primaryWindow).usedPercent, 17, accuracy: 0.001)
        XCTAssertEqual(snapshot.primaryWindow?.modelID, "gemini-2.5-pro")
    }

    /// A model with a generous daily allowance and an exhausted per-minute one
    /// is exhausted. Reporting the generous number reports the limit that is
    /// not biting.
    func testTheMostConstrainedBucketWinsPerModel() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [
          {"modelId": "gemini-2.5-pro", "remainingFraction": 0.9},
          {"modelId": "gemini-2.5-pro", "remainingFraction": 0.05},
          {"modelId": "gemini-2.5-pro", "remainingFraction": 0.4}
        ]}
        """)
        XCTAssertEqual(snapshot.allWindows.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.primaryWindow).remainingPercent, 5, accuracy: 0.001)
    }

    func testProAndFlashLeadAndEverythingElseIsKept() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [
          {"modelId": "gemini-2.5-pro",   "remainingFraction": 0.5},
          {"modelId": "gemini-2.5-flash", "remainingFraction": 0.8},
          {"modelId": "gemini-embedding", "remainingFraction": 0.99}
        ]}
        """)
        XCTAssertEqual(snapshot.primaryWindow?.modelID, "gemini-2.5-pro")
        XCTAssertEqual(snapshot.secondaryWindow?.modelID, "gemini-2.5-flash")
        XCTAssertEqual(snapshot.extraWindows.map(\.modelID), ["gemini-embedding"])
        // Nothing is shown twice and nothing is lost.
        XCTAssertEqual(snapshot.allWindows.count, 3)
    }

    /// A model released after this code was written has to keep its own window
    /// rather than being dropped into a family it does not match.
    func testAnUnfamiliarModelKeepsItsOwnWindow() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [{"modelId": "gemini-9-ultra", "remainingFraction": 0.25}]}
        """)
        XCTAssertNil(snapshot.primaryWindow)
        XCTAssertNil(snapshot.secondaryWindow)
        XCTAssertEqual(snapshot.extraWindows.first?.modelID, "gemini-9-ultra")
        XCTAssertTrue(snapshot.hasQuota)
    }

    func testAResetTimeIsRead() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [
          {"modelId": "gemini-2.5-pro", "remainingFraction": 0.5, "resetTime": "2026-08-11T00:00:00Z"}
        ]}
        """)
        XCTAssertEqual(
            snapshot.primaryWindow?.resetsAt,
            ISO8601DateFormatter().date(from: "2026-08-11T00:00:00Z")
        )
    }

    func testAnExhaustedBucketIsReportedAsExhausted() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [{"modelId": "gemini-2.5-pro", "remainingFraction": 0}]}
        """)
        XCTAssertEqual(snapshot.primaryWindow?.remainingPercent, 0)
        XCTAssertNil(snapshot.unavailable)
    }

    func testABucketWithoutAFractionIsSkippedRatherThanZeroed() throws {
        let snapshot = try snapshot("""
        {"quotaBuckets": [{"modelId": "gemini-2.5-pro", "resetTime": "2026-08-11T00:00:00Z"}]}
        """)
        XCTAssertEqual(snapshot.unavailable, .planReportsNoQuota)
        XCTAssertFalse(snapshot.hasQuota)
    }

    // MARK: - The account response

    func testTheProjectAndTierAreRead() throws {
        let account = GeminiUsageParser.account(from: try json("""
        {"cloudaicompanionProject": "proj-123", "currentTier": {"id": "standard-tier"}}
        """))
        XCTAssertEqual(account.projectID, "proj-123")
        XCTAssertEqual(account.tier, "standard-tier")
        XCTAssertFalse(account.ineligible)
    }

    /// Only what the response says outright. Treating "free" as ineligible
    /// would be Uncoil inventing Google's policy and reporting it as fact.
    func testEligibilityIsNotInferredFromATierName() throws {
        let account = GeminiUsageParser.account(from: try json("""
        {"currentTier": {"id": "free-tier"}}
        """))
        XCTAssertFalse(account.ineligible)
    }

    func testAnIneligibleTierIsRecognised() throws {
        let account = GeminiUsageParser.account(from: try json("""
        {"currentTier": {"id": "ineligible-consumer"}}
        """))
        XCTAssertTrue(account.ineligible)
    }

    /// Google's withdrawal of the consumer tiers arrives as a refusal, not as
    /// an empty quota. An account with a full allowance can receive it, so
    /// reading it as 0% would be a lie that goes on to drive a decision.
    func testAWithdrawnTierIsDetectedInAnErrorBody() {
        let bodies = [
            #"{"error": {"message": "Unsupported client for this account."}}"#,
            #"{"error": {"message": "This account is not eligible for Code Assist."}}"#,
            #"{"error": {"status": "PERMISSION_DENIED", "message": "no longer supported"}}"#,
        ]
        for body in bodies {
            XCTAssertTrue(
                GeminiUsageParser.indicatesUnsupportedTier(Data(body.utf8)),
                "should have been recognised: \(body)"
            )
        }
        XCTAssertFalse(
            GeminiUsageParser.indicatesUnsupportedTier(Data(#"{"error": "internal"}"#.utf8))
        )
    }
}

// MARK: - Authentication mode

/// An API key and a Vertex configuration are working setups this route cannot
/// read. Saying so beats showing an empty figure for an account that is fine.
final class GeminiAuthModeTests: XCTestCase {
    private func settings(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-gemini-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testOAuthIsRecognised() throws {
        let url = try settings(#"{"security": {"auth": {"selectedType": "oauth-personal"}}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(GeminiAuthMode.read(settingsAt: url), .oauthPersonal)
    }

    func testAnApiKeyIsRecognised() throws {
        let url = try settings(#"{"security": {"auth": {"selectedType": "gemini-api-key"}}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(GeminiAuthMode.read(settingsAt: url), .apiKey)
    }

    func testVertexIsRecognised() throws {
        let url = try settings(#"{"selectedType": "vertex-ai"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(GeminiAuthMode.read(settingsAt: url), .vertexAI)
    }

    /// No settings file is the ordinary state of a CLI logged in with Google,
    /// so it must not be read as a broken configuration.
    func testAMissingSettingsFileMeansOAuth() {
        let url = URL(fileURLWithPath: "/nonexistent/uncoil/settings.json")
        XCTAssertEqual(GeminiAuthMode.read(settingsAt: url), .oauthPersonal)
    }
}

// MARK: - The CLI's OAuth client

/// A refresh token is only exchangeable by the client it was issued to, so the
/// CLI's own client configuration has to be found. There is no published
/// constant; it is a literal in the installed package.
final class GeminiOAuthClientTests: XCTestCase {

    func testTheClientPairIsExtractedFromSource() {
        let source = """
        const OAUTH_CLIENT_ID = '123-abc.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'GOCSPX-example';
        """
        let client = GeminiOAuthClient.extract(from: source)
        XCTAssertEqual(client?.clientID, "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(client?.clientSecret, "GOCSPX-example")
    }

    /// The CLI's build output has used more than one declaration form, so the
    /// pattern is written against the shape rather than the keyword.
    func testAPropertyAssignmentFormIsAlsoMatched() {
        let source = #"{ OAUTH_CLIENT_ID: "id-1", OAUTH_CLIENT_SECRET: "secret-1" }"#
        let client = GeminiOAuthClient.extract(from: source)
        XCTAssertEqual(client?.clientID, "id-1")
        XCTAssertEqual(client?.clientSecret, "secret-1")
    }

    func testAHalfPresentPairIsNotAClient() {
        XCTAssertNil(GeminiOAuthClient.extract(from: "const OAUTH_CLIENT_ID = 'only-the-id';"))
    }

    /// The override exists so a machine where the search fails is a setting
    /// away from working rather than a rebuild away.
    func testTheEnvironmentOverrideWins() {
        let client = GeminiOAuthClient.resolve(
            environment: [
                "UNCOIL_GEMINI_OAUTH_CLIENT_ID": "env-id",
                "UNCOIL_GEMINI_OAUTH_CLIENT_SECRET": "env-secret",
            ],
            binaryPath: nil
        )
        XCTAssertEqual(client?.clientID, "env-id")
    }

    func testNothingIsInventedWhenTheClientCannotBeFound() {
        XCTAssertNil(GeminiOAuthClient.resolve(environment: [:], binaryPath: "/nonexistent/gemini"))
    }
}
