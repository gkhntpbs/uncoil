import XCTest
@testable import Uncoil

/// A driver answers in ticks and crosses. What it means is Uncoil's to say, so
/// the reading of it is pinned here rather than left to the settings page.
final class DriverReportTests: XCTestCase {
    func testReadsTickAndCross() {
        let report = DriverReport.requirements(in: """
        ✓ Accessibility
        ✗ Screen Recording
        """)
        XCTAssertEqual(report, [
            DriverRequirement(name: "Accessibility", isGranted: true),
            DriverRequirement(name: "Screen Recording", isGranted: false),
        ])
    }

    func testReadsTheWordAfterAColon() {
        let report = DriverReport.requirements(in: """
        Accessibility: granted
        Screen Recording: denied
        """)
        XCTAssertEqual(report.map(\.isGranted), [true, false])
        XCTAssertEqual(report.map(\.name), ["Accessibility", "Screen Recording"])
    }

    /// The glyph and the word can disagree in shape but not in meaning; when
    /// both are present the spelled-out value is the one that was written on
    /// purpose.
    func testTheStatedValueWinsOverTheGlyph() {
        let report = DriverReport.requirement(in: "✓ Accessibility: denied")
        XCTAssertEqual(report?.isGranted, false)
    }

    func testReadsAVerdictAtTheEndOfTheLine() {
        let report = DriverReport.requirement(in: "- screen recording ....... denied")
        XCTAssertEqual(report?.name, "screen recording")
        XCTAssertEqual(report?.isGranted, false)
    }

    /// Failing to read a line costs one row; reading it wrongly costs the
    /// user's trust in every other row. Prose is skipped.
    func testProseIsNotARequirement() {
        XCTAssertNil(DriverReport.requirement(in: "Permissions status for cua-driver"))
        XCTAssertNil(DriverReport.requirement(in: ""))
        XCTAssertNil(DriverReport.requirement(in: "   "))
    }

    /// "unknown" is a real answer, and it is not "granted".
    func testUnknownStaysUnknown() {
        XCTAssertNil(DriverReport.requirement(in: "Accessibility: unknown")?.isGranted)
    }

    func testSentenceTakesTheFirstMeaningfulLine() {
        let text = "\n✗ could not reach the daemon\n  at Object.<anonymous> (/x/y.js:1:1)"
        XCTAssertEqual(DriverReport.sentence(text), "could not reach the daemon")
    }

    func testSentenceOfNothingIsNothing() {
        XCTAssertNil(DriverReport.sentence("\n\n  \n"))
    }
}
