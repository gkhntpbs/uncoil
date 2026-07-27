import XCTest
@testable import Uncoil

final class BumblebeeBinaryTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilBumblebee-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func locator(
        present: Set<BumblebeeBinarySource>,
        pathValue: String? = "/usr/local/bin/bumblebee"
    ) -> BumblebeeLocator {
        var locator = BumblebeeLocator(
            pinnedPath: "/Applications/Uncoil.app/Contents/Helpers/bumblebee",
            managedDirectory: base
        )
        locator.pathLookup = { pathValue }
        locator.exists = { candidate in
            if candidate == locator.pinnedPath { return present.contains(.pinned) }
            if candidate == locator.managedPath { return present.contains(.managed) }
            return present.contains(.path)
        }
        return locator
    }

    func testThePinnedBinaryWinsOverEverythingElse() {
        let resolved = locator(present: [.pinned, .managed, .path]).resolve()
        XCTAssertEqual(resolved?.source, .pinned)
        XCTAssertTrue(resolved?.source.isVersionKnownInAdvance ?? false)
    }

    func testAManagedBinaryIsPreferredOverPATH() {
        XCTAssertEqual(locator(present: [.managed, .path]).resolve()?.source, .managed)
    }

    func testPATHIsTheLastResort() {
        let resolved = locator(present: [.path]).resolve()
        XCTAssertEqual(resolved?.source, .path)
        XCTAssertEqual(resolved?.path, "/usr/local/bin/bumblebee")
        XCTAssertFalse(
            resolved?.source.isVersionKnownInAdvance ?? true,
            "whatever is on PATH is whatever the user happens to have"
        )
    }

    func testNoBinaryAnywhereIsReportedAsMissing() {
        XCTAssertNil(locator(present: [], pathValue: nil).resolve())
        XCTAssertTrue(locator(present: [], pathValue: nil).available().isEmpty)
    }

    func testEverySourceFoundIsListedForTheUI() {
        XCTAssertEqual(
            locator(present: [.managed, .path]).available().map(\.source), [.managed, .path]
        )
    }

    func testEverySourceHasALabel() {
        for source in BumblebeeBinarySource.allCases {
            XCTAssertFalse(source.label.isEmpty, source.rawValue)
        }
    }
}

final class BumblebeeVersionAndSelfTestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testTheJSONVersionFormIsRead() {
        let version = BumblebeeVersion.parse(
            #"{"version":"1.4.2","build":"a1b2c3d","catalog":"2026.07.01"}"#
        )
        XCTAssertEqual(version?.version, "1.4.2")
        XCTAssertEqual(version?.buildRevision, "a1b2c3d")
        XCTAssertEqual(version?.catalogVersion, "2026.07.01")
        XCTAssertTrue(version?.label.contains("build a1b2c3d") ?? false)
    }

    func testTheTextVersionFormIsRead() {
        let version = BumblebeeVersion.parse("bumblebee 1.4.2 (build a1b2c3d)")
        XCTAssertEqual(version?.version, "1.4.2")
        XCTAssertEqual(version?.buildRevision, "a1b2c3d")
    }

    func testUnreadableVersionOutputIsNil() {
        XCTAssertNil(BumblebeeVersion.parse(""))
        XCTAssertNil(BumblebeeVersion.parse("command not found"))
    }

    func testAFailingSelfTestMakesResultsUntrustworthy() {
        let failed = BumblebeeSelfTest.parse(
            #"{"ok":false,"detail":"catalog imzası doğrulanamadı"}"#, exitCode: 1, now: now
        )
        XCTAssertFalse(failed.passed)
        XCTAssertFalse(failed.resultsAreTrustworthy)
        XCTAssertEqual(failed.detail, "catalog imzası doğrulanamadı")
    }

    func testANonZeroExitIsAFailureEvenWhenTheOutputSaysOK() {
        let mixed = BumblebeeSelfTest.parse(#"{"ok":true}"#, exitCode: 2, now: now)
        XCTAssertFalse(
            mixed.passed,
            "a binary that says ok and exits non-zero is not something to trust"
        )
    }

    func testAPassingSelfTestIsTrusted() {
        XCTAssertTrue(
            BumblebeeSelfTest.parse("all checks passed", exitCode: 0, now: now)
                .resultsAreTrustworthy
        )
    }
}

final class BumblebeeOutputParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFindingsAndSummaryAreReadFromNDJSON() {
        let events = BumblebeeOutputParser.parseStdout(
            """
            {"type":"finding","id":"BB-100","rule":"known-malicious-version","severity":"blocked","message":"zararlı sürüm","path":"pkg/x","extension_id":"acme:x"}
            {"type":"finding","rule":"mcp-inventory","severity":"low","message":"envanter"}
            {"type":"scan_summary","scanned":42,"findings":2,"duration_seconds":1.5,"catalog_version":"2026.07.01"}
            """,
            now: now
        )
        XCTAssertEqual(events.count, 3)
        guard case .finding(let first) = events[0] else { return XCTFail("expected a finding") }
        XCTAssertEqual(first.severity, .blocked)
        XCTAssertEqual(first.origin, .bumblebee, "Bumblebee's findings stay Bumblebee's")
        XCTAssertEqual(first.extensionID, "acme:x")
        guard case .summary(let summary) = events[2] else { return XCTFail("expected a summary") }
        XCTAssertEqual(summary.scanned, 42)
        XCTAssertEqual(summary.catalogVersion, "2026.07.01")
    }

    func testAnUnknownLineIsKeptRatherThanDropped() {
        let events = BumblebeeOutputParser.parseStdout("bu JSON değil\n{}", now: now)
        XCTAssertEqual(events.count, 2)
        for event in events {
            guard case .unknown = event else {
                return XCTFail("an unrecognised line must be visible: \(event)")
            }
        }
    }

    func testStderrDiagnosticsAreReadAsJSONOrText() {
        let diagnostics = BumblebeeOutputParser.parseStderr(
            """
            {"level":"warn","message":"parser SKILL.md okuyamadı"}
            düz metin uyarı
            """
        )
        XCTAssertEqual(diagnostics, ["parser SKILL.md okuyamadı", "düz metin uyarı"])
    }

    func testSeverityNamesMapOntoUncoilsScale() {
        XCTAssertEqual(BumblebeeOutputParser.severity("critical"), .blocked)
        XCTAssertEqual(BumblebeeOutputParser.severity("high"), .high)
        XCTAssertEqual(BumblebeeOutputParser.severity("medium"), .needsReview)
        XCTAssertEqual(BumblebeeOutputParser.severity("low"), .low)
        XCTAssertEqual(
            BumblebeeOutputParser.severity("bilinmeyen"), .info,
            "an unknown severity is information, never silently promoted"
        )
    }
}

final class BumblebeeRunnerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let binary = BumblebeeBinary(source: .managed, path: "/tmp/bumblebee")

    private func runner(
        lock: BumblebeeScanLock = BumblebeeScanLock(),
        outputs: [String: BumblebeeRunner.Output]
    ) -> BumblebeeRunner {
        runner(binary: binary, lock: lock, outputs: outputs)
    }

    private func runner(
        binary: BumblebeeBinary?,
        lock: BumblebeeScanLock = BumblebeeScanLock(),
        outputs: [String: BumblebeeRunner.Output]
    ) -> BumblebeeRunner {
        BumblebeeRunner(
            binary: binary,
            run: { invocation in
                let key = invocation.arguments.first ?? ""
                guard let output = outputs[key] else {
                    return .init(stdout: "", stderr: "", exitCode: 0, timedOut: false)
                }
                return output
            },
            lock: lock
        )
    }

    private var passingSelfTest: BumblebeeRunner.Output {
        .init(stdout: #"{"ok":true,"detail":"tamam"}"#, stderr: "", exitCode: 0, timedOut: false)
    }

    private var versionOutput: BumblebeeRunner.Output {
        .init(
            stdout: #"{"version":"1.4.2","build":"abc1234"}"#, stderr: "",
            exitCode: 0, timedOut: false
        )
    }

    func testAScanRecordsItsVersionSelfTestAndSummary() async throws {
        let runner = runner(outputs: [
            "selftest": passingSelfTest,
            "version": versionOutput,
            "scan": .init(
                stdout: """
                {"type":"finding","rule":"known-package-exposure","severity":"high","message":"paket açığı"}
                {"type":"scan_summary","scanned":7,"findings":1}
                """,
                stderr: #"{"message":"parser diagnostic"}"#,
                exitCode: 0,
                timedOut: false
            ),
        ])
        let result = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
        XCTAssertTrue(result.isUsableAsCurrentState)
        XCTAssertNil(result.unusableReason)
        XCTAssertEqual(result.version?.buildRevision, "abc1234")
        XCTAssertEqual(result.selfTest?.passed, true)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.summary?.scanned, 7)
        XCTAssertEqual(result.diagnostics, ["parser diagnostic"])
    }

    func testAScanWithoutASummaryIsNotTheCurrentState() async throws {
        let runner = runner(outputs: [
            "selftest": passingSelfTest,
            "version": versionOutput,
            "scan": .init(
                stdout: #"{"type":"finding","rule":"x","severity":"low","message":"y"}"#,
                stderr: "", exitCode: 0, timedOut: false
            ),
        ])
        let result = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
        XCTAssertFalse(result.isUsableAsCurrentState)
        XCTAssertTrue(result.unusableReason?.contains("scan_summary") ?? false)
    }

    func testATimedOutScanIsNotTheCurrentStateEither() async throws {
        let runner = runner(outputs: [
            "selftest": passingSelfTest,
            "version": versionOutput,
            "scan": .init(
                stdout: #"{"type":"scan_summary","scanned":1,"findings":0}"#,
                stderr: "", exitCode: 0, timedOut: true
            ),
        ])
        let result = try await runner.scan(kind: .beforeUpdate, paths: ["/repo"], now: now)
        XCTAssertFalse(result.isUsableAsCurrentState)
        XCTAssertTrue(result.unusableReason?.contains("timed out") ?? false)
    }

    func testAFailedSelfTestStopsTheScanBeforeItRuns() async {
        var scanned = false
        var runner = self.runner(outputs: [
            "selftest": .init(
                stdout: #"{"ok":false,"detail":"bozuk"}"#, stderr: "", exitCode: 1, timedOut: false
            ),
        ])
        let inner = runner.run
        runner.run = { invocation in
            if invocation.arguments.first == "scan" { scanned = true }
            return try await inner(invocation)
        }
        do {
            _ = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
            XCTFail("a failed self-test must stop the scan")
        } catch {
            XCTAssertEqual(
                error as? BumblebeeRunner.RunError, .selfTestFailed("bozuk")
            )
        }
        XCTAssertFalse(scanned, "and it must not have run at all")
    }

    func testAMissingBinaryIsReportedRatherThanInstalled() async {
        let runner = runner(binary: BumblebeeBinary?.none, outputs: [:])
        do {
            _ = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? BumblebeeRunner.RunError, .notInstalled)
            XCTAssertTrue(
                (error as? BumblebeeRunner.RunError)?.errorDescription?.contains("approval") ?? false,
                "installing it is the user's decision"
            )
        }
    }

    func testTwoScansCannotRunAtOnce() async throws {
        let lock = BumblebeeScanLock()
        lock.acquire(.dailyBaseline)
        let runner = runner(lock: lock, outputs: ["selftest": passingSelfTest])
        do {
            _ = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
            XCTFail("expected alreadyRunning")
        } catch {
            XCTAssertEqual(
                error as? BumblebeeRunner.RunError, .alreadyRunning(.dailyBaseline)
            )
        }
        lock.release()
        XCTAssertTrue(lock.tryAcquire(.manual))
        XCTAssertFalse(lock.tryAcquire(.deep), "the lock is not re-entrant")
    }

    func testTheLockIsFreedAfterAScan() async throws {
        let lock = BumblebeeScanLock()
        let runner = runner(lock: lock, outputs: [
            "selftest": passingSelfTest,
            "version": versionOutput,
            "scan": .init(
                stdout: #"{"type":"scan_summary","scanned":1,"findings":0}"#,
                stderr: "", exitCode: 0, timedOut: false
            ),
        ])
        _ = try await runner.scan(kind: .manual, paths: ["/repo"], now: now)
        XCTAssertNil(lock.current, "a finished scan does not hold the lock")
    }

    func testDeepScansGetTheLongestBudgetAndQuickOnesTheShortest() {
        XCTAssertTrue(BumblebeeScanKind.beforeInstall.isQuick)
        XCTAssertEqual(BumblebeeScanKind.beforeInstall.timeout, 30)
        XCTAssertEqual(BumblebeeScanKind.deep.timeout, 900)
        XCTAssertFalse(BumblebeeScanKind.deep.isQuick)
        for kind in BumblebeeScanKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, kind.rawValue)
            XCTAssertGreaterThan(kind.timeout, 0, kind.rawValue)
        }
    }

    func testOnlySomeScansBecomeTheBaselineAndSomeRunInTheDaemon() {
        XCTAssertTrue(BumblebeeScanKind.dailyBaseline.updatesBaseline)
        XCTAssertTrue(BumblebeeScanKind.dailyBaseline.runsInDaemon)
        XCTAssertTrue(BumblebeeScanKind.deep.runsInDaemon)
        XCTAssertFalse(
            BumblebeeScanKind.beforeInstall.updatesBaseline,
            "a scan of something not installed yet is not the baseline"
        )
        XCTAssertFalse(BumblebeeScanKind.manual.runsInDaemon)
    }
}

final class BumblebeeScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNoScanEverMeansOneIsDue() {
        XCTAssertTrue(BumblebeeSchedule.isStale(lastScanAt: nil, now: now))
        XCTAssertEqual(BumblebeeSchedule.atLaunch(lastScanAt: nil, now: now), .launchIfStale)
    }

    func testARecentScanMeansNothingRunsAtLaunch() {
        let recent = now.addingTimeInterval(-60 * 60)
        XCTAssertFalse(BumblebeeSchedule.isStale(lastScanAt: recent, now: now))
        XCTAssertNil(BumblebeeSchedule.atLaunch(lastScanAt: recent, now: now))
    }

    func testAScanOlderThanADayIsStale() {
        let old = now.addingTimeInterval(-25 * 60 * 60)
        XCTAssertTrue(BumblebeeSchedule.isStale(lastScanAt: old, now: now))
    }

    func testTheNextBaselineIsADayAfterTheLast() {
        let last = now.addingTimeInterval(-3_600)
        XCTAssertEqual(
            BumblebeeSchedule.nextBaseline(after: last, now: now),
            last.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(
            BumblebeeSchedule.nextBaseline(after: nil, now: now), now,
            "with no baseline yet, now is when it is due"
        )
    }
}

final class BumblebeeCoverageTests: XCTestCase {
    private func package(_ kind: ExtensionKind, source: ExtensionSource) -> ExtensionPackage {
        ExtensionPackage(id: "x", kind: kind, name: "x", source: source, state: .active)
    }

    func testEveryCoverageGapIsStatedWithARemedy() {
        XCTAssertEqual(BumblebeeCoverage.all.count, 3)
        for gap in BumblebeeCoverage.all {
            XCTAssertFalse(gap.message.isEmpty, gap.id)
            XCTAssertFalse(gap.remedy.isEmpty, gap.id)
        }
        XCTAssertTrue(
            BumblebeeCoverage.looseSkillFolders.message.contains("SKILL.md")
        )
        XCTAssertTrue(BumblebeeCoverage.codexTOML.message.contains("Codex's TOML"))
    }

    func testWhatIsOutsideBumblebeesReachIsLabelled() {
        let remote = package(.mcpServer, source: .remoteMCP(url: "https://x", transport: .http))
        XCTAssertFalse(BumblebeeCoverage.isCovered(remote))
        XCTAssertEqual(BumblebeeCoverage.label(for: remote), "Not covered by Bumblebee")

        let skill = package(.skill, source: .local(path: "/tmp/x"))
        XCTAssertFalse(
            BumblebeeCoverage.isCovered(skill),
            "a loose SKILL.md folder is not scanned directly"
        )

        let mcp = package(
            .mcpServer,
            source: .managedGitHub(repository: "a/b", subpath: nil, tracking: .branch("main"))
        )
        XCTAssertTrue(BumblebeeCoverage.isCovered(mcp))
        XCTAssertNil(BumblebeeCoverage.label(for: mcp))
    }

    func testACleanResultIsNeverPresentedAsSafe() {
        let caption = BumblebeeCoverage.cleanResultCaption(scanned: 12)
        XCTAssertTrue(caption.contains("12"))
        XCTAssertTrue(
            caption.contains("does not mean “entirely safe”"),
            "the phrase only ever appears negated: \(caption)"
        )
        XCTAssertTrue(caption.contains("reach is limited"), caption)
    }
}

@MainActor
final class ExtensionLockFileTests: XCTestCase {
    private var base: URL!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private var packages: [ExtensionPackage] {
        var managed = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: "review", tracking: .tag("v1.2.0")
            ),
            state: .active
        )
        managed.activeRevision = InstalledRevision(
            id: "rev-1", commitSHA: "a1b2c3d4", contentHash: "hash-1",
            path: "/store/revisions/rev-1", installedAt: now
        )
        var manual = ExtensionPackage(
            id: "local:mine", kind: .skill, name: "mine",
            source: .local(path: "/Users/x/skills/mine"), state: .active
        )
        manual.activeRevision = InstalledRevision(
            id: "rev-local", commitSHA: nil, contentHash: "hash-2",
            path: "/Users/x/skills/mine", installedAt: now
        )
        let disabled = ExtensionPackage(
            id: "acme/skills:off", kind: .skill, name: "off",
            source: .managedGitHub(
                repository: "acme/skills", subpath: "off", tracking: .branch("main")
            ),
            state: .quarantined
        )
        let server = ExtensionPackage(
            id: "acme/mcp:srv", kind: .mcpServer, name: "srv",
            source: .managedGitHub(
                repository: "acme/mcp", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        return [managed, manual, disabled, server]
    }

    func testTheSkillLockCarriesSourceCommitAndPath() throws {
        let lock = ExtensionLockFiles.skillLock(packages: packages, generatedAt: now)
        XCTAssertEqual(lock.skills.map(\.name), ["mine", "review"])
        let review = try XCTUnwrap(lock.skills.first { $0.name == "review" })
        XCTAssertEqual(review.repository, "acme/skills")
        XCTAssertEqual(review.commit, "a1b2c3d4")
        XCTAssertEqual(review.ref, "tag v1.2.0")
        XCTAssertEqual(review.path, "/store/revisions/rev-1")
        XCTAssertFalse(review.isManual)
    }

    func testAManualSkillIsMarkedAsSuch() throws {
        let lock = ExtensionLockFiles.skillLock(packages: packages, generatedAt: now)
        let mine = try XCTUnwrap(lock.skills.first { $0.name == "mine" })
        XCTAssertTrue(
            mine.isManual,
            "a hand-added folder is not something Uncoil vouches for"
        )
        XCTAssertNil(mine.commit)
    }

    func testOnlyActiveSkillsAreInTheLock() {
        let lock = ExtensionLockFiles.skillLock(packages: packages, generatedAt: now)
        XCTAssertFalse(lock.skills.contains { $0.name == "off" }, "quarantined stays out")
        XCTAssertFalse(lock.skills.contains { $0.name == "srv" }, "and MCP servers are not skills")
    }

    func testUncoilsOwnLockKeepsMoreThanBumblebeeNeeds() throws {
        let lock = ExtensionLockFiles.extensionsLock(
            packages: packages,
            agents: { _ in [.claudeCode, .codex] },
            appVersion: "1.0.0",
            generatedAt: now
        )
        XCTAssertEqual(lock.entries.count, 4, "every package, whatever its state")
        let review = try XCTUnwrap(lock.entries.first { $0.name == "review" })
        XCTAssertEqual(review.tracking, "tag v1.2.0")
        XCTAssertEqual(review.revisionID, "rev-1")
        XCTAssertEqual(review.contentHash, "hash-1")
        XCTAssertEqual(review.agents, ["claudeCode", "codex"])
        XCTAssertEqual(
            lock.entries.first { $0.name == "off" }?.state, .quarantined,
            "the state is part of what a restore needs to reproduce"
        )
    }

    func testBothLocksRoundTripThroughTheirFiles() throws {
        let skillURL = base.appendingPathComponent(".agents/.skill-lock.json")
        let extensionsURL = base.appendingPathComponent("extensions.lock.json")
        let skillLock = ExtensionLockFiles.skillLock(packages: packages, generatedAt: now)
        let extensionsLock = ExtensionLockFiles.extensionsLock(
            packages: packages, agents: { _ in [] }, appVersion: "1.0.0", generatedAt: now
        )
        try ExtensionLockFiles.write(skillLock, to: skillURL)
        try ExtensionLockFiles.write(extensionsLock, to: extensionsURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                ExtensionLockFiles.SkillLock.self,
                from: try XCTUnwrap(FileManager.default.contents(atPath: skillURL.path))
            ),
            skillLock
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionLockFiles.ExtensionsLock.self,
                from: try XCTUnwrap(FileManager.default.contents(atPath: extensionsURL.path))
            ),
            extensionsLock
        )
    }

    func testTheDefaultSkillLockPathIsWhereBumblebeeLooks() {
        XCTAssertTrue(
            ExtensionLockFiles.defaultSkillLockURL(home: URL(fileURLWithPath: "/Users/x"))
                .path.hasSuffix(".agents/.skill-lock.json")
        )
    }
}

final class ThreatCatalogTests: XCTestCase {
    private var base: URL!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilCatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func store() -> ThreatCatalogStore {
        ThreatCatalogStore(directory: base.appendingPathComponent("catalog", isDirectory: true))
    }

    private func payload(_ entries: String) -> String {
        """
        { "schema_version": 1, "entries": [\(entries)] }
        """
    }

    private var oneRule: String {
        #"{"id":"BB-1","severity":"high","title":"zararlı paket"}"#
    }

    func testAValidCatalogRecordsItsVersionAndCommit() throws {
        let catalog = try ThreatCatalogStore.validate(
            payload(oneRule), catalogVersion: "2026.07.01",
            repositoryCommit: "a1b2c3d4e5f6", repository: "bumblebee/catalog", now: now
        )
        XCTAssertEqual(catalog.catalogVersion, "2026.07.01")
        XCTAssertEqual(catalog.repositoryCommit, "a1b2c3d4e5f6")
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertTrue(catalog.label.contains("a1b2c3d4e5f6"))
    }

    func testTheCatalogVersionIsIndependentOfTheBinaryVersion() throws {
        let catalog = try ThreatCatalogStore.validate(
            payload(oneRule), catalogVersion: "2026.07.01",
            repositoryCommit: nil, repository: nil, now: now
        )
        let binaryVersion = BumblebeeVersion(
            version: "1.4.2", buildRevision: "abc", catalogVersion: "2026.06.01"
        )
        XCTAssertNotEqual(
            catalog.catalogVersion, binaryVersion.catalogVersion,
            "the two are tracked separately, so a stale pairing is visible"
        )
    }

    func testAnInvalidOrIncompleteCatalogIsRefused() {
        XCTAssertThrowsError(
            try ThreatCatalogStore.validate(
                "bu JSON değil", catalogVersion: "v", repositoryCommit: nil,
                repository: nil, now: now
            )
        )
        XCTAssertThrowsError(
            try ThreatCatalogStore.validate(
                payload(#"{"id":"BB-1"}"#), catalogVersion: "v",
                repositoryCommit: nil, repository: nil, now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? ThreatCatalogStore.CatalogError, .missingFields(["severity"])
            )
        }
        XCTAssertThrowsError(
            try ThreatCatalogStore.validate(
                #"{ "schema_version": 99, "entries": [] }"#, catalogVersion: "v",
                repositoryCommit: nil, repository: nil, now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? ThreatCatalogStore.CatalogError, .unsupportedSchema(99)
            )
        }
    }

    func testACatalogRepositoryWithAScriptIsRefused() throws {
        let root = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("catalog.json"))
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: root.appendingPathComponent("install.sh"))

        XCTAssertThrowsError(try ThreatCatalogStore.rejectExecutables(in: root)) { error in
            guard case .executableInCatalog(let paths) =
                try? XCTUnwrap(error as? ThreatCatalogStore.CatalogError) else {
                return XCTFail("expected executableInCatalog, got \(error)")
            }
            XCTAssertEqual(paths, ["install.sh"])
        }
        XCTAssertEqual(ThreatCatalogStore.catalogJSONFiles(in: root), ["catalog.json"])
    }

    func testOnlyJSONIsTakenFromTheCatalogRepository() throws {
        let root = base.appendingPathComponent("repo2", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("rules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("rules/a.json"))
        try Data("# okuma".utf8).write(to: root.appendingPathComponent("README.md"))
        XCTAssertEqual(ThreatCatalogStore.catalogJSONFiles(in: root), ["rules/a.json"])
        XCTAssertNoThrow(try ThreatCatalogStore.rejectExecutables(in: root))
    }

    func testInstallingKeepsThePreviousCatalogAndDiffsTheRules() throws {
        let store = self.store()
        let first = try ThreatCatalogStore.validate(
            payload(oneRule), catalogVersion: "2026.06.01",
            repositoryCommit: "c1", repository: "bumblebee/catalog", now: now
        )
        let firstUpdate = try store.install(first)
        XCTAssertEqual(firstUpdate.addedRules, ["BB-1"])
        XCTAssertTrue(firstUpdate.shouldRescan, "a new rule set means the last scan is out of date")

        let second = try ThreatCatalogStore.validate(
            payload(
                #"{"id":"BB-1","severity":"blocked","title":"zararlı paket"},"#
                    + #"{"id":"BB-2","severity":"low","title":"yeni kural"}"#
            ),
            catalogVersion: "2026.07.01", repositoryCommit: "c2",
            repository: "bumblebee/catalog", now: now
        )
        let update = try store.install(second)
        XCTAssertEqual(update.previousVersion, "2026.06.01")
        XCTAssertEqual(update.addedRules, ["BB-2"])
        XCTAssertEqual(update.changedRules, ["BB-1"], "a severity change is a change")
        XCTAssertTrue(update.summary.contains("+1 rules"), update.summary)
        XCTAssertEqual(store.current()?.catalogVersion, "2026.07.01")
        XCTAssertEqual(store.previous()?.catalogVersion, "2026.06.01")
    }

    func testRollbackPutsThePreviousCatalogBack() throws {
        let store = self.store()
        _ = try store.install(try ThreatCatalogStore.validate(
            payload(oneRule), catalogVersion: "v1", repositoryCommit: nil,
            repository: nil, now: now
        ))
        _ = try store.install(try ThreatCatalogStore.validate(
            payload(#"{"id":"BB-9","severity":"low","title":"başka"}"#),
            catalogVersion: "v2", repositoryCommit: nil, repository: nil, now: now
        ))
        let restored = try store.rollback()
        XCTAssertEqual(restored.catalogVersion, "v1")
        XCTAssertEqual(store.current()?.catalogVersion, "v1")
        XCTAssertThrowsError(try store.rollback(), "there is nothing left to go back to")
    }

    func testAnUnchangedCatalogAsksForNoRescan() throws {
        let store = self.store()
        let catalog = try ThreatCatalogStore.validate(
            payload(oneRule), catalogVersion: "v1", repositoryCommit: nil,
            repository: nil, now: now
        )
        _ = try store.install(catalog)
        let update = try store.install(catalog)
        XCTAssertTrue(update.isEmpty)
        XCTAssertFalse(update.shouldRescan)
        XCTAssertEqual(update.summary, "No rule change")
    }
}

@MainActor
final class BumblebeeRegistryRecordTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilBBRegistry-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        registry = ExtensionRegistry(
            layout: layout,
            store: SkillStore(
                layout: layout,
                canonicalRoot: base.appendingPathComponent("canonical", isDirectory: true)
            )
        )
        registry.upsert(ExtensionPackage(
            id: "acme/skills:x", kind: .skill, name: "x",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        ))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func result(
        usable: Bool,
        findings: [SecurityFinding] = []
    ) -> BumblebeeScanResult {
        BumblebeeScanResult(
            kind: .dailyBaseline,
            findings: findings,
            diagnostics: [],
            summary: usable ? BumblebeeScanSummary(scanned: 3, findings: findings.count) : nil,
            unknownLines: [],
            exitCode: 0,
            timedOut: false,
            selfTest: BumblebeeSelfTest(passed: true, detail: "ok", ranAt: now),
            version: BumblebeeVersion(
                version: "1.4.2", buildRevision: "abc1234", catalogVersion: "2026.07.01"
            ),
            startedAt: now,
            finishedAt: now
        )
    }

    private func bumblebeeFinding() -> SecurityFinding {
        SecurityFinding(
            id: "bumblebee:BB-1", origin: .bumblebee, severity: .high,
            rule: "known-package-exposure", message: "paket açığı",
            extensionID: "acme/skills:x", foundAt: now
        )
    }

    func testAUsableScanIsRecordedWithItsVersion() {
        XCTAssertTrue(registry.record(scan: result(usable: true, findings: [bumblebeeFinding()])))
        XCTAssertEqual(registry.bumblebeeVersion?.buildRevision, "abc1234")
        XCTAssertEqual(registry.lastBumblebeeScanAt, now)
        XCTAssertEqual(registry.findings.filter { $0.origin == .bumblebee }.count, 1)
        XCTAssertNotNil(registry.overview.lastBumblebeeScan)
        XCTAssertNotNil(registry.overview.bumblebeeSummary)
    }

    func testAnUnusableScanIsNotTakenAsTheCurrentState() {
        registry.setFindings([bumblebeeFinding()], forExtension: "acme/skills:x")
        XCTAssertFalse(registry.record(scan: result(usable: false)))
        XCTAssertEqual(
            registry.findings.filter { $0.origin == .bumblebee }.count, 1,
            "the findings on record are untouched by a scan that did not finish"
        )
        XCTAssertNil(registry.lastBumblebeeScanAt)
        XCTAssertTrue(
            registry.auditEvents.contains { $0.detail.contains("was not used") },
            "and the attempt is recorded"
        )
        XCTAssertEqual(
            registry.bumblebeeVersion?.version, "1.4.2",
            "the binary it came from is still worth knowing"
        )
    }

    func testUncoilsOwnFindingsSurviveABumblebeeScan() {
        let mine = SecurityFinding(
            id: "uncoil:1", origin: .uncoil, severity: .needsReview, rule: "file.obfuscated",
            message: "minified", extensionID: "acme/skills:x", foundAt: now
        )
        registry.setFindings([mine], forExtension: "acme/skills:x")
        _ = registry.record(scan: result(usable: true, findings: [bumblebeeFinding()]))
        XCTAssertTrue(
            registry.findings.contains { $0.origin == .uncoil },
            "the two origins are never mixed, and one does not clear the other"
        )
        XCTAssertTrue(registry.findings.contains { $0.origin == .bumblebee })
    }

    func testBothLockFilesAreWrittenAndTheSharedOneIsOptIn() throws {
        let home = base.appendingPathComponent("home", isDirectory: true)
        XCTAssertTrue(registry.writeLockFiles(home: home, appVersion: "1.0.0", now: now))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".agents/.skill-lock.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.locks.appendingPathComponent("extensions.lock.json").path
        ))

        // Without a home, only Uncoil's own lock is written — a registry made by a
        // test leaves nothing in the real home directory.
        let other = base.appendingPathComponent("other-home", isDirectory: true)
        XCTAssertTrue(registry.writeLockFiles(home: nil, now: now))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: other.appendingPathComponent(".agents/.skill-lock.json").path
        ))
    }
}

@MainActor
final class BumblebeeScanCoordinatorTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilScans-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        registry = ExtensionRegistry(
            layout: layout,
            store: SkillStore(
                layout: layout,
                canonicalRoot: base.appendingPathComponent("canonical", isDirectory: true)
            )
        )
        var package = ExtensionPackage(
            id: "acme/mcp:srv", kind: .mcpServer, name: "srv",
            source: .managedGitHub(
                repository: "acme/mcp", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = InstalledRevision(
            id: "rev-1", commitSHA: "c1", contentHash: "h",
            path: layout.revisions.appendingPathComponent("rev-1").path, installedAt: now
        )
        registry.upsert(package)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func locator(installed: Bool) -> BumblebeeLocator {
        var locator = BumblebeeLocator(pinnedPath: nil, managedDirectory: base)
        locator.pathLookup = { installed ? "/tmp/bumblebee" : nil }
        locator.exists = { _ in installed }
        return locator
    }

    private func coordinator(
        installed: Bool = true,
        lock: BumblebeeScanLock = BumblebeeScanLock(),
        record: @escaping (BumblebeeRunner.Invocation) -> Void = { _ in }
    ) -> BumblebeeScanCoordinator {
        BumblebeeScanCoordinator(
            registry: registry,
            locator: locator(installed: installed),
            lock: lock,
            makeRunner: { binary, lock in
                BumblebeeRunner(
                    binary: binary,
                    run: { invocation in
                        record(invocation)
                        switch invocation.arguments.first {
                        case "selftest":
                            return .init(
                                stdout: #"{"ok":true}"#, stderr: "", exitCode: 0, timedOut: false
                            )
                        case "version":
                            return .init(
                                stdout: #"{"version":"1.4.2"}"#, stderr: "",
                                exitCode: 0, timedOut: false
                            )
                        default:
                            return .init(
                                stdout: #"{"type":"scan_summary","scanned":1,"findings":0}"#,
                                stderr: "", exitCode: 0, timedOut: false
                            )
                        }
                    },
                    lock: lock
                )
            }
        )
    }

    func testWithNoBinaryEveryTriggerSaysSoAndRunsNothing() async {
        let coordinator = coordinator(installed: false)
        XCTAssertFalse(coordinator.isInstalled)
        for outcome in [
            await coordinator.scanManually(now: now),
            await coordinator.scanBeforeInstall(path: base.path, now: now),
            await coordinator.deepScan(now: now),
        ] {
            XCTAssertEqual(outcome, .notInstalled)
            XCTAssertTrue(outcome.message.contains("approval"), outcome.message)
        }
    }

    func testALaunchScanOnlyRunsWhenTheLastOneIsStale() async {
        var kinds: [String] = []
        let coordinator = coordinator(record: { invocation in
            if invocation.arguments.first == "scan" { kinds.append("scan") }
        })
        // Nothing scanned yet: due.
        let first = await coordinator.scanAtLaunchIfStale(now: now)
        XCTAssertTrue(first.didRun, first.message)
        XCTAssertEqual(kinds.count, 1)

        // The registry now has a recent scan, so a second launch skips.
        let second = await coordinator.scanAtLaunchIfStale(now: now.addingTimeInterval(60))
        guard case .skipped = second else {
            return XCTFail("a recent scan is not redone: \(second)")
        }
        XCTAssertEqual(kinds.count, 1)
    }

    func testTheDailyBaselineWaitsForItsDueTime() async {
        let coordinator = coordinator()
        _ = await coordinator.scanManually(now: now)
        let tooSoon = await coordinator.scanDailyBaselineIfDue(now: now.addingTimeInterval(3_600))
        guard case .skipped(let reason) = tooSoon else {
            return XCTFail("expected a skip: \(tooSoon)")
        }
        XCTAssertTrue(reason.contains("baseline"))

        let due = await coordinator.scanDailyBaselineIfDue(
            now: now.addingTimeInterval(25 * 60 * 60)
        )
        XCTAssertTrue(due.didRun, due.message)
    }

    func testEachTriggerPassesTheRightPaths() async {
        var scanned: [[String]] = []
        let coordinator = coordinator(record: { invocation in
            guard invocation.arguments.first == "scan" else { return }
            scanned.append(invocation.arguments.filter { $0.hasPrefix("/") })
        })
        _ = await coordinator.scanBeforeInstall(path: "/dış/kurulum", now: now)
        _ = await coordinator.scanProjects(roots: ["/repo/a", "/repo/b"], now: now)
        _ = await coordinator.scanManually(now: now)

        XCTAssertTrue(scanned[0].contains("/dış/kurulum"))
        XCTAssertTrue(scanned[1].contains("/repo/a") && scanned[1].contains("/repo/b"))
        XCTAssertTrue(
            scanned[2].contains { $0.contains("rev-1") },
            "a store-wide scan covers the revisions Uncoil installed: \(scanned[2])"
        )
    }

    func testAProjectScanWithNoProjectsIsSkipped() async {
        let outcome = await coordinator().scanProjects(roots: [], now: now)
        guard case .skipped = outcome else { return XCTFail("expected a skip") }
    }

    func testAScanIsSkippedWhileAnotherIsRunning() async {
        let lock = BumblebeeScanLock()
        lock.acquire(.deep)
        let outcome = await coordinator(lock: lock).scanManually(now: now)
        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected a skip: \(outcome)")
        }
        XCTAssertTrue(reason.contains("Deep scan"), reason)
    }

    func testOnlyWhatBumblebeeCoversIsSentToIt() {
        var remote = ExtensionPackage(
            id: "remote:srv", kind: .mcpServer, name: "remote",
            source: .remoteMCP(url: "https://x.test", transport: .http), state: .active
        )
        remote.activeRevision = InstalledRevision(
            id: "rev-remote", commitSHA: nil, contentHash: "h",
            path: "/tmp/remote", installedAt: now
        )
        registry.upsert(remote)
        let paths = coordinator().managedPaths()
        XCTAssertFalse(
            paths.contains("/tmp/remote"),
            "a remote server has no local files to scan"
        )
        XCTAssertTrue(paths.contains { $0.contains("rev-1") })
    }

    func testAScanResultReachesTheRegistry() async {
        let coordinator = coordinator()
        _ = await coordinator.scanManually(now: now)
        XCTAssertEqual(registry.lastBumblebeeScanAt, now)
        XCTAssertEqual(registry.bumblebeeVersion?.version, "1.4.2")
        XCTAssertEqual(registry.bumblebeeSelfTest?.passed, true)
    }
}

/// Aşama 17.1 — every Bumblebee finding type Uncoil has to handle.
final class BumblebeeFindingKindTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func finding(
        rule: String,
        severity: SecurityFinding.Severity = .needsReview,
        origin: SecurityFinding.Origin = .bumblebee
    ) -> SecurityFinding {
        SecurityFinding(
            id: rule, origin: origin, severity: severity, rule: rule,
            message: rule, extensionID: "x", foundAt: now
        )
    }

    func testEveryFindingTypeIsRecognisedFromItsRule() {
        let cases: [(String, BumblebeeFindingKind)] = [
            ("known-package-exposure", .knownPackageExposure),
            ("advisory.CVE-2026-1234", .knownPackageExposure),
            ("vulnerable-dependency", .knownPackageExposure),
            ("known-malicious-version", .knownMaliciousVersion),
            ("known_bad_package", .knownMaliciousVersion),
            ("suspicious-editor-extension", .suspiciousEditorExtension),
            ("vscode-extension-risk", .suspiciousEditorExtension),
            ("mcp-inventory", .mcpInventory),
            ("inventory.mcp.servers", .mcpInventory),
            ("agent-skill-inventory", .agentSkillInventory),
            ("inventory.skills", .agentSkillInventory),
            ("parser-diagnostic", .parserDiagnostic),
            ("parse-error.toml", .parserDiagnostic),
            ("unsupported-configuration", .unsupportedConfiguration),
            ("coverage.not-supported", .unsupportedConfiguration),
        ]
        for (rule, expected) in cases {
            XCTAssertEqual(BumblebeeFindingKind.from(rule: rule), expected, rule)
        }
    }

    func testAnUnknownRuleStaysVisibleRatherThanBeingDropped() {
        XCTAssertEqual(
            BumblebeeFindingKind.from(rule: "bb-9999-brand-new-rule"), .other
        )
        XCTAssertTrue(
            BumblebeeFindingKind.other.isActionable,
            "a finding nobody classified is still a finding"
        )
        XCTAssertEqual(BumblebeeFindingKind.other.defaultSeverity, .needsReview)
    }

    func testEveryKindHasALabelAndARemedy() {
        for kind in BumblebeeFindingKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, kind.rawValue)
            XCTAssertFalse(kind.remedy.isEmpty, kind.rawValue)
        }
    }

    func testInventoryAndDiagnosticsAreNotProblemsToActOn() {
        XCTAssertTrue(BumblebeeFindingKind.mcpInventory.isInventory)
        XCTAssertTrue(BumblebeeFindingKind.agentSkillInventory.isInventory)
        XCTAssertFalse(BumblebeeFindingKind.mcpInventory.isActionable)
        XCTAssertTrue(BumblebeeFindingKind.parserDiagnostic.isAboutTheScanner)
        XCTAssertTrue(BumblebeeFindingKind.unsupportedConfiguration.isAboutTheScanner)
        XCTAssertFalse(BumblebeeFindingKind.parserDiagnostic.isActionable)
    }

    func testAMaliciousVersionBlocksAndAnExposureIsHigh() {
        XCTAssertEqual(BumblebeeFindingKind.knownMaliciousVersion.defaultSeverity, .blocked)
        XCTAssertEqual(BumblebeeFindingKind.knownPackageExposure.defaultSeverity, .high)
        XCTAssertEqual(BumblebeeFindingKind.mcpInventory.defaultSeverity, .info)
    }

    func testOnlyBumblebeeFindingsGetABumblebeeKind() {
        XCTAssertEqual(
            finding(rule: "known-malicious-version").bumblebeeKind, .knownMaliciousVersion
        )
        XCTAssertNil(
            finding(rule: "file.obfuscated", origin: .uncoil).bumblebeeKind,
            "Uncoil's own findings have their own rule names"
        )
    }

    func testTheSummaryCountsOnlyWhatTheUserShouldActOn() {
        let summary = BumblebeeFindingSummary(findings: [
            finding(rule: "known-malicious-version", severity: .blocked),
            finding(rule: "known-package-exposure", severity: .high),
            finding(rule: "mcp-inventory", severity: .info),
            finding(rule: "agent-skill-inventory", severity: .info),
            finding(rule: "file.obfuscated", origin: .uncoil),
        ])
        XCTAssertEqual(summary.actionableCount, 2)
        XCTAssertEqual(summary.inventoryCount, 2)
        XCTAssertFalse(summary.hasParserDiagnostics)
        XCTAssertEqual(
            summary.byKind[.knownMaliciousVersion]?.count, 1
        )
        XCTAssertNil(
            summary.byKind.keys.first { $0 == .other && summary.byKind[$0]?.isEmpty == false }
                .flatMap { _ -> BumblebeeFindingKind? in nil },
            "Uncoil's own finding is not classified as a Bumblebee kind"
        )
        XCTAssertEqual(
            summary.byKind.values.flatMap { $0 }.count, 4,
            "the Uncoil finding is left out of the Bumblebee breakdown"
        )
    }

    func testAScanWithParserDiagnosticsIsNeverCalledClean() {
        let summary = BumblebeeFindingSummary(findings: [
            finding(rule: "parser-diagnostic", severity: .info),
        ])
        XCTAssertTrue(summary.hasParserDiagnostics)
        XCTAssertEqual(summary.actionableCount, 0)
        let caption = summary.caption(scanned: 10)
        XCTAssertTrue(caption.contains("could not be read"), caption)
        XCTAssertFalse(caption.contains("no findings"), caption)
    }

    func testACleanScanSaysWhatItDoesNotMean() {
        let caption = BumblebeeFindingSummary(findings: []).caption(scanned: 5)
        XCTAssertTrue(caption.contains("does not mean"), caption)
    }

    func testTheKindsShownAreOnlyTheOnesPresent() {
        let summary = BumblebeeFindingSummary(findings: [
            finding(rule: "mcp-inventory", severity: .info),
        ])
        XCTAssertEqual(summary.kinds, [.mcpInventory])
    }
}

@MainActor
final class BumblebeeDaemonHandoffTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilHandoff-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        registry = ExtensionRegistry(layout: layout, store: SkillStore(layout: layout))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func coordinator() -> BumblebeeScanCoordinator {
        var locator = BumblebeeLocator(pinnedPath: nil, managedDirectory: base)
        locator.pathLookup = { nil }
        locator.exists = { _ in false }
        return BumblebeeScanCoordinator(registry: registry, locator: locator)
    }

    private func writeDaemonResult(_ text: String) throws {
        try Data(text.utf8).write(
            to: layout.scans.appendingPathComponent("daemon-baseline.ndjson")
        )
    }

    func testAResultTheDaemonLeftBehindReachesTheRegistry() throws {
        // The app recorded a passing self-test before it quit, which is what the
        // daemon's result is judged against.
        registry.record(scan: BumblebeeScanResult(
            kind: .manual, findings: [], diagnostics: [],
            summary: BumblebeeScanSummary(scanned: 0, findings: 0),
            unknownLines: [], exitCode: 0, timedOut: false,
            selfTest: BumblebeeSelfTest(passed: true, detail: "ok", ranAt: now),
            version: BumblebeeVersion(version: "1.4.2", buildRevision: nil, catalogVersion: nil),
            startedAt: now, finishedAt: now
        ))

        try writeDaemonResult("""
        {"type":"finding","rule":"known-package-exposure","severity":"high","message":"paket açığı"}
        {"type":"scan_summary","scanned":4,"findings":1}
        """)
        let outcome = coordinator().importDaemonResult(now: now.addingTimeInterval(3_600))
        XCTAssertTrue(outcome.didRun, outcome.message)
        XCTAssertEqual(registry.findings.filter { $0.origin == .bumblebee }.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.scans.appendingPathComponent("daemon-baseline.ndjson").path
            ),
            "the file is consumed, so the same result is not imported twice"
        )
    }

    func testADaemonResultWithoutATrustedSelfTestIsNotTheCurrentState() throws {
        try writeDaemonResult(#"{"type":"scan_summary","scanned":1,"findings":0}"#)
        let outcome = coordinator().importDaemonResult(now: now)
        // It ran, but with no self-test on record it is not taken as current.
        guard case .ran(_, let usable) = outcome else {
            return XCTFail("expected a run: \(outcome)")
        }
        XCTAssertFalse(usable)
        XCTAssertNil(registry.lastBumblebeeScanAt)
    }

    func testNothingToImportIsSaidPlainly() {
        let outcome = coordinator().importDaemonResult(now: now)
        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected a skip: \(outcome)")
        }
        XCTAssertTrue(reason.contains("no result"), reason)
    }

    func testSchedulingIsRefusedWithoutABinary() {
        let outcome = coordinator().scheduleInDaemon(client: .shared, now: now)
        XCTAssertEqual(
            outcome, .notInstalled,
            "Uncoil hands the daemon a path, it does not install one"
        )
    }
}
