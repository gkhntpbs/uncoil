import XCTest
@testable import Uncoil

/// What the real `bumblebee` v0.1.2 binary accepts and emits.
///
/// The strings here were captured from the released binary rather than invented:
/// this is the one place Uncoil has to match a command line it does not own, and
/// the earlier mismatch (`--json`, `--ndjson`, `--lock-file`) made every scan fail
/// with "flag provided but not defined".
final class BumblebeeCLIContractTests: XCTestCase {
    func testScanArgumentsUseProfilesAndRootFlags() {
        XCTAssertEqual(
            BumblebeeRunner.scanArguments(kind: .manual, paths: ["/a", "/b"], catalogPath: nil),
            ["scan", "--profile", "project", "--root", "/a", "--root", "/b"]
        )
        XCTAssertEqual(
            BumblebeeRunner.scanArguments(kind: .dailyBaseline, paths: [], catalogPath: nil),
            ["scan", "--profile", "baseline"]
        )
        XCTAssertEqual(
            BumblebeeRunner.scanArguments(kind: .deep, paths: ["/a"], catalogPath: "/c"),
            ["scan", "--profile", "deep", "--exposure-catalog", "/c", "--root", "/a"]
        )
    }

    /// Without a catalog the scanner emits inventory and never a finding, so the
    /// catalog has to be on the command line whenever there is one.
    func testTheExposureCatalogIsPassedWhenThereIsOne() {
        let arguments = BumblebeeRunner.scanArguments(
            kind: .manual, paths: ["/a"], catalogPath: "/tools/threat_intel"
        )
        XCTAssertTrue(
            arguments.contains("--exposure-catalog") && arguments.contains("/tools/threat_intel"),
            "\(arguments)"
        )
    }

    func testVersionIsReadFromWhatTheBinaryActuallyPrints() {
        let output = """
        bumblebee v0.1.2
        commit: cc57710eeaf685e7b89924a36c8583cad0a378fe
        built:  2026-06-18T15:03:13Z
        go:     go1.25.11
        """
        let version = BumblebeeVersion.parse(output)
        XCTAssertEqual(version?.version, "v0.1.2")
        XCTAssertEqual(version?.buildRevision, "cc57710eeaf685e7b89924a36c8583cad0a378fe")
    }

    func testTheScanSummaryRecordIsUnderstood() {
        let line = """
        {"record_type":"scan_summary","scanner_version":"v0.1.2","profile":"project",\
        "status":"complete","counts":{"finding":2,"package":37},"files_considered":120,\
        "timed_out":false,"duration_ms":1500}
        """
        let events = BumblebeeOutputParser.parseStdout(line, now: Date(timeIntervalSince1970: 0))
        guard case .summary(let summary) = events.first else {
            return XCTFail("özet satırı anlaşılmadı: \(events)")
        }
        XCTAssertEqual(summary.scanned, 37)
        XCTAssertEqual(summary.findings, 2)
        XCTAssertEqual(summary.durationSeconds, 1.5)
        XCTAssertFalse(summary.truncated)
    }

    /// A run that stopped early is not the current state, however many records it
    /// managed to emit first.
    func testAnIncompleteSummaryIsMarkedTruncated() {
        let line = """
        {"record_type":"scan_summary","status":"partial","counts":{"finding":0,"package":1},\
        "timed_out":true}
        """
        let events = BumblebeeOutputParser.parseStdout(line, now: Date(timeIntervalSince1970: 0))
        guard case .summary(let summary) = events.first else {
            return XCTFail("özet satırı anlaşılmadı")
        }
        XCTAssertTrue(summary.truncated)
    }

    func testAPackageRecordIsInventoryNotAFinding() {
        let line = """
        {"record_type":"package","ecosystem":"mcp","package_name":"@figma/mcp","version":"",\
        "source_file":"/Users/x/.cursor/mcp.json"}
        """
        let events = BumblebeeOutputParser.parseStdout(line, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(events, [.package])
    }

    func testAFindingRecordBecomesAFindingWithItsCatalogRuleAndFile() {
        let line = """
        {"record_type":"finding","record_id":"finding:abc","finding_type":"package_exposure",\
        "severity":"high","catalog_id":"glassworm-npm-foo","catalog_name":"foo (GlassWorm)",\
        "ecosystem":"npm","package_name":"foo","version":"1.3.0",\
        "source_file":"/Users/x/node_modules/foo/package.json",\
        "evidence":"exact name+version match (version=1.3.0)"}
        """
        let events = BumblebeeOutputParser.parseStdout(line, now: Date(timeIntervalSince1970: 0))
        guard case .finding(let finding) = events.first else {
            return XCTFail("bulgu satırı anlaşılmadı: \(events)")
        }
        XCTAssertEqual(finding.origin, .bumblebee)
        XCTAssertEqual(finding.severity, .high)
        XCTAssertEqual(finding.rule, "glassworm-npm-foo")
        XCTAssertEqual(finding.path, "/Users/x/node_modules/foo/package.json")
        XCTAssertTrue(finding.message.contains("foo@1.3.0"), finding.message)
        XCTAssertTrue(finding.message.contains("GlassWorm"), finding.message)
    }

    /// The catalog directory ships next to the binary; when it is not there, no
    /// catalog is claimed.
    func testTheCatalogIsFoundNextToTheBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilCatalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = BumblebeeBinary(
            source: .managed, path: root.appendingPathComponent("bumblebee").path
        )
        let locator = BumblebeeLocator(managedDirectory: root)
        XCTAssertNil(locator.catalogDirectory(for: binary))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("threat_intel", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            locator.catalogDirectory(for: binary),
            root.appendingPathComponent("threat_intel").path
        )
    }
}
