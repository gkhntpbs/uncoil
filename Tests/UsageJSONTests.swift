import XCTest
@testable import Uncoil

/// The tolerant field reader every provider parser is built on.
///
/// The tolerance is the feature under test. These payloads are not published
/// schemas — they are the wire format between a vendor's CLI and its own
/// backend — and the same quantity arrives under different names from different
/// routes of the *same* provider. A parser pinned to one spelling reports a CLI
/// update as "usage unavailable", which is the failure hardest to tell from a
/// real one.
final class UsageJSONTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func object(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try XCTUnwrap(value.objectValue)
    }

    // MARK: - Spellings

    func testBothCasingsOfTheSameFieldAreRead() throws {
        let snake = try object(#"{"used_percent": 42}"#)
        let camel = try object(#"{"usedPercent": 42}"#)
        XCTAssertEqual(UsageJSON.double(snake, ["used_percent", "usedPercent"]), 42)
        XCTAssertEqual(UsageJSON.double(camel, ["used_percent", "usedPercent"]), 42)
    }

    /// A numeric string is still a number; refusing it drops a window we can
    /// read for the sake of a type distinction JSON does not make.
    func testANumericStringIsReadAsANumber() throws {
        let json = try object(#"{"used_percent": "87.5"}"#)
        XCTAssertEqual(UsageJSON.double(json, ["used_percent"]), 87.5)
    }

    /// The invariant that keeps a missing field from becoming a reading: absent
    /// is nil, never zero.
    func testAMissingFieldIsNilRatherThanZero() throws {
        let json = try object(#"{"other": 1}"#)
        XCTAssertNil(UsageJSON.double(json, ["used_percent"]))
    }

    func testAnExplicitNullIsTreatedAsAbsent() throws {
        let json = try object(#"{"used_percent": null, "usedPercent": 12}"#)
        XCTAssertEqual(UsageJSON.double(json, ["used_percent", "usedPercent"]), 12)
    }

    // MARK: - Dates

    func testAnISOTimestampIsParsed() throws {
        let json = try object(#"{"resets_at": "2026-08-10T12:00:00Z"}"#)
        let date = UsageJSON.date(json, absolute: ["resets_at"], relativeSeconds: [], now: now)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z"))
    }

    func testFractionalSecondsAreAccepted() throws {
        let json = try object(#"{"resets_at": "2026-08-10T12:00:00.250Z"}"#)
        XCTAssertNotNil(UsageJSON.date(json, absolute: ["resets_at"], relativeSeconds: [], now: now))
    }

    /// The relative form is measured from the moment the response was produced,
    /// so it has to be added to the time of the reading — not to whenever
    /// somebody later looks at the screen.
    func testASecondsUntilResetIsAnchoredToTheReading() throws {
        let json = try object(#"{"resets_in_seconds": 3600}"#)
        let date = UsageJSON.date(json, absolute: ["resets_at"], relativeSeconds: ["resets_in_seconds"], now: now)
        XCTAssertEqual(date, now.addingTimeInterval(3600))
    }

    func testMillisecondEpochsAreToldApartFromSeconds() {
        XCTAssertEqual(
            UsageJSON.epochDate(1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            UsageJSON.epochDate(1_700_000_000_000),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Windows

    func testAWindowIsReadFromUsedPercent() throws {
        let json = try object(#"{"used_percent": 30, "window_minutes": 300, "resets_in_seconds": 60}"#)
        let window = try XCTUnwrap(UsageJSON.window(json, id: "w", title: "Session", now: now))
        XCTAssertEqual(window.usedPercent, 30)
        XCTAssertEqual(window.windowMinutes, 300)
        XCTAssertEqual(window.resetsAt, now.addingTimeInterval(60))
    }

    func testAWindowIsReadFromRemainingPercent() throws {
        let json = try object(#"{"remaining_percent": 30}"#)
        let window = try XCTUnwrap(UsageJSON.window(json, id: "w", title: "Session", now: now))
        XCTAssertEqual(window.usedPercent, 70)
    }

    func testAWindowIsReadFromARemainingFraction() throws {
        let json = try object(#"{"remainingFraction": 0.25}"#)
        let window = try XCTUnwrap(UsageJSON.window(json, id: "w", title: "Session", now: now))
        XCTAssertEqual(window.usedPercent, 75, accuracy: 0.001)
    }

    /// A reset time with no percentage is not a window. Showing it would put a
    /// countdown on screen beside nothing to count down.
    func testAWindowWithNoPercentageIsNotAWindow() throws {
        let json = try object(#"{"resets_at": "2026-08-10T12:00:00Z"}"#)
        XCTAssertNil(UsageJSON.window(json, id: "w", title: "Session", now: now))
    }

    /// Fields nobody has seen yet must not stop the ones we can read.
    func testUnknownFieldsAreIgnored() throws {
        let json = try object("""
        {"used_percent": 10, "quantum_budget": {"nested": [1, 2]}, "future_flag": true}
        """)
        let window = try XCTUnwrap(UsageJSON.window(json, id: "w", title: "Session", now: now))
        XCTAssertEqual(window.usedPercent, 10)
    }

    // MARK: - Titles

    func testAWindowIsNamedFromItsLength() {
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: 300, fallback: "x"), "5-hour limit")
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: 10080, fallback: "x"), "Weekly limit")
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: 20160, fallback: "x"), "2-week limit")
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: 180, fallback: "x"), "3-hour limit")
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: 90, fallback: "x"), "90-minute limit")
        XCTAssertEqual(UsageJSON.titleForWindow(minutes: nil, fallback: "Session limit"), "Session limit")
    }
}
