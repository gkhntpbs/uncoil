import XCTest
@testable import Uncoil

final class ExtensionSourceCapabilityTests: XCTestCase {
    private let managed = ExtensionSource.managedGitHub(
        repository: "acme/skills", subpath: nil, tracking: .branch("main")
    )
    private let bundled = ExtensionSource.bundled(identifier: "uncoil.review")
    private let local = ExtensionSource.local(path: "/Users/x/skills/mine")
    private let external = ExtensionSource.detectedExternal(path: "/Users/x/.claude/skills/other")
    private let remote = ExtensionSource.remoteMCP(url: "https://mcp.test/sse", transport: .http)

    func testManagedGitHubGetsTheFullSet() {
        let capabilities = managed.capabilities
        XCTAssertTrue(capabilities.canCheckForUpdates)
        XCTAssertTrue(capabilities.canUpdate)
        XCTAssertTrue(capabilities.canRollback)
        XCTAssertTrue(capabilities.canCompareCommits)
        XCTAssertTrue(capabilities.canScan)
        XCTAssertTrue(capabilities.canManageFiles)
        XCTAssertEqual(capabilities.versionSource, .git)
        XCTAssertFalse(capabilities.isReadOnly)
    }

    func testBundledIsTiedToTheAppAndNotUserEditable() {
        let capabilities = bundled.capabilities
        XCTAssertEqual(capabilities.versionSource, .appBundle)
        XCTAssertTrue(capabilities.isReadOnly, "the next app update would undo any edit")
        XCTAssertFalse(capabilities.canUpdate, "it updates with the app, not on its own")
        XCTAssertFalse(capabilities.canManageFiles)
        XCTAssertTrue(capabilities.canRun)
        XCTAssertTrue(capabilities.canScan)
    }

    func testLocalRunsAndScansButIsNeverUpdated() {
        let capabilities = local.capabilities
        XCTAssertTrue(capabilities.canRun)
        XCTAssertTrue(capabilities.canAssign)
        XCTAssertTrue(capabilities.canScan)
        XCTAssertFalse(capabilities.canCheckForUpdates, "there is nothing to update from")
        XCTAssertFalse(capabilities.canUpdate)
        XCTAssertFalse(capabilities.canRollback)
        XCTAssertTrue(capabilities.canLinkToRepository)
        XCTAssertEqual(capabilities.versionSource, .none)
        XCTAssertTrue(local.label.contains("Unmanaged"), local.label)
    }

    func testDetectedExternalIsReadOnlyUntilAdopted() {
        let capabilities = external.capabilities
        XCTAssertTrue(capabilities.isReadOnly)
        XCTAssertTrue(capabilities.canAdopt)
        XCTAssertFalse(capabilities.canRun, "Uncoil does not run what it did not install")
        XCTAssertFalse(capabilities.canAssign)
        XCTAssertFalse(capabilities.canManageFiles, "no silent ownership")
        XCTAssertTrue(external.label.contains("Unmanaged"), external.label)
    }

    func testRemoteMCPHasNoLocalGitStory() {
        let capabilities = remote.capabilities
        XCTAssertEqual(
            capabilities.versionSource, .server,
            "a repo version is a different fact and must not stand in for it"
        )
        XCTAssertFalse(capabilities.canCheckForUpdates)
        XCTAssertFalse(capabilities.canUpdate)
        XCTAssertFalse(capabilities.canRollback)
        XCTAssertFalse(capabilities.canCompareCommits)
        XCTAssertFalse(capabilities.canScan, "there are no local files to scan")
        XCTAssertTrue(capabilities.canHealthCheck)
        XCTAssertTrue(capabilities.canRun)
    }

    func testOnlyManagedSourcesAreUpdatableAndOwned() {
        for source in [managed, bundled, local, external, remote] {
            XCTAssertEqual(
                source.capabilities.canUpdate, source.isManaged, source.label
            )
        }
        XCTAssertTrue(bundled.isOwnedByUncoil)
        XCTAssertFalse(local.isOwnedByUncoil)
    }

    func testALocalSourceCanBeAttachedToARepositoryLater() {
        let linked = local.linkedToRepository("acme/skills", tracking: .tag("v1.2.0"))
        guard case .managedGitHub(let repository, _, let tracking) = linked else {
            return XCTFail("expected a managed source, got \(String(describing: linked))")
        }
        XCTAssertEqual(repository, "acme/skills")
        XCTAssertEqual(tracking, .tag("v1.2.0"))
        XCTAssertEqual(linked?.capabilities.canUpdate, true)

        XCTAssertNil(
            external.linkedToRepository("acme/skills"),
            "an unadopted external install is not linked to anything"
        )
        XCTAssertNil(bundled.linkedToRepository("acme/skills"))
        XCTAssertNil(remote.linkedToRepository("acme/skills"))
    }

    func testEveryVersionSourceHasALabel() {
        for source in [managed, bundled, local, external, remote] {
            XCTAssertFalse(source.capabilities.versionSource.label.isEmpty, source.label)
        }
    }
}

final class BundledExtensionCatalogTests: XCTestCase {
    private var resources: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilBundled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: resources)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, to name: String) throws -> String {
        let url = resources.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return try XCTUnwrap(BundledExtensionCatalog.digest(at: url))
    }

    private func writeManifest(_ manifest: BundledExtensionCatalog.Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: resources.appendingPathComponent(BundledExtensionCatalog.manifestName)
        )
    }

    private func catalog(appVersion: String = "1.0.0") -> BundledExtensionCatalog {
        BundledExtensionCatalog(resourcesDirectory: resources, appVersion: appVersion)
    }

    func testBundledExtensionsAreListedAndMarkedBundled() throws {
        let hash = try write("# Review skill\n", to: "bundled/review.md")
        try writeManifest(.init(appVersion: "1.0.0", entries: [
            .init(
                identifier: "uncoil.review", name: "review", kind: .skill,
                relativePath: "bundled/review.md", sha256: hash, summary: "Kod incelemesi"
            ),
        ]))
        let result = catalog().packages(now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(result.failures.isEmpty)
        let package = try XCTUnwrap(result.packages.first)
        XCTAssertEqual(package.source, .bundled(identifier: "uncoil.review"))
        XCTAssertTrue(package.source.capabilities.isReadOnly)
        XCTAssertEqual(package.name, "review")
    }

    func testAModifiedBundledFileIsReportedRatherThanRun() throws {
        let hash = try write("# Review skill\n", to: "bundled/review.md")
        try writeManifest(.init(appVersion: "1.0.0", entries: [
            .init(
                identifier: "uncoil.review", name: "review", kind: .skill,
                relativePath: "bundled/review.md", sha256: hash
            ),
        ]))
        _ = try write("# Değiştirilmiş\n", to: "bundled/review.md")

        let result = catalog().packages()
        XCTAssertTrue(result.packages.isEmpty, "a modified bundled file is not offered")
        guard case .modified(let path, _, _) = try XCTUnwrap(result.failures.first) else {
            return XCTFail("expected a modification, got \(result.failures)")
        }
        XCTAssertEqual(path, "bundled/review.md")
        XCTAssertTrue(result.failures[0].message.contains("çalıştırılmamalı"))
    }

    func testAMissingBundledFileIsReported() throws {
        try writeManifest(.init(appVersion: "1.0.0", entries: [
            .init(
                identifier: "uncoil.gone", name: "gone", kind: .skill,
                relativePath: "bundled/gone.md", sha256: "beklenen"
            ),
        ]))
        let result = catalog().packages()
        XCTAssertEqual(result.failures, [.missing("bundled/gone.md")])
    }

    func testTheManifestIsTiedToTheAppVersion() throws {
        try writeManifest(.init(appVersion: "1.0.0", entries: []))
        let manifest = try XCTUnwrap(catalog().loadManifest())
        XCTAssertTrue(catalog(appVersion: "1.0.0").isCurrent(manifest))
        XCTAssertFalse(
            catalog(appVersion: "1.1.0").isCurrent(manifest),
            "bundled extensions move with the app, so a stale manifest is visible"
        )
    }

    func testNoManifestMeansNoBundledExtensionsRatherThanACrash() {
        let result = catalog().packages()
        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(catalog().loadManifest())
    }

    func testADirectoryIsHashedFromItsContents() throws {
        _ = try write("a", to: "bundled/pack/one.md")
        _ = try write("b", to: "bundled/pack/two.md")
        let before = try XCTUnwrap(
            BundledExtensionCatalog.digest(at: resources.appendingPathComponent("bundled/pack"))
        )
        _ = try write("b değişti", to: "bundled/pack/two.md")
        let after = try XCTUnwrap(
            BundledExtensionCatalog.digest(at: resources.appendingPathComponent("bundled/pack"))
        )
        XCTAssertNotEqual(before, after)
    }
}

@MainActor
final class ExtensionAdoptionTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var service: ExtensionAdoptionService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilAdopt-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        service = ExtensionAdoptionService(layout: layout)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func external(_ files: [String: String]) throws -> URL {
        let root = base.appendingPathComponent("external/skill", isDirectory: true)
        for (name, contents) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func finding(_ severity: SecurityFinding.Severity) -> SecurityFinding {
        SecurityFinding(
            id: "f1", origin: .uncoil, severity: severity, rule: "risky-command.sudo",
            message: "sudo çağrısı var", foundAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testThePlanShowsTheDiffAndTakesABackupBeforeAnythingMoves() throws {
        let root = try external(["SKILL.md": "# dış skill\n", "run.sh": "echo hi\n"])
        let plan = try service.plan(name: "external-skill", kind: .skill, externalPath: root.path)

        XCTAssertEqual(plan.changedFiles.map(\.path).sorted(), ["SKILL.md", "run.sh"])
        XCTAssertTrue(plan.changes.allSatisfy { $0.kind == .added })
        XCTAssertNotNil(plan.backupPath)
        XCTAssertTrue(plan.isAdoptable)
        XCTAssertTrue(plan.summary.contains("2 yeni"), plan.summary)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destinationPath),
            "planning moves no files"
        )
    }

    func testAdoptingCopiesTheFilesInAndMarksThemUnmanagedNotInvented() throws {
        let root = try external(["SKILL.md": "# dış skill\n"])
        let plan = try service.plan(name: "external-skill", kind: .skill, externalPath: root.path)
        let package = try service.adopt(plan, now: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: plan.destinationPath + "/SKILL.md"
        ))
        guard case .local = package.source else {
            return XCTFail("adopting invents no repository: \(package.source)")
        }
        XCTAssertTrue(package.source.capabilities.canLinkToRepository)
        XCTAssertFalse(package.source.capabilities.canUpdate)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "the external install is left where it was"
        )
    }

    func testAdoptionIsRefusedWhileAFindingBlocksIt() throws {
        let root = try external(["SKILL.md": "# dış skill\n"])
        let plan = try service.plan(
            name: "external-skill", kind: .skill, externalPath: root.path,
            findings: [finding(.blocked)]
        )
        XCTAssertFalse(plan.isAdoptable)
        XCTAssertThrowsError(try service.adopt(plan)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("sudo"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationPath))
    }

    func testAHighFindingWarnsButDoesNotBlock() throws {
        let root = try external(["SKILL.md": "# dış skill\n"])
        let plan = try service.plan(
            name: "external-skill", kind: .skill, externalPath: root.path,
            findings: [finding(.high)]
        )
        XCTAssertTrue(plan.isAdoptable, "the user decides on a warning; a block is a block")
        XCTAssertEqual(plan.findings.count, 1)
    }

    func testAdoptingOverAnExistingCopyShowsWhatWouldChangeAndCanBeUndone() throws {
        let root = try external(["SKILL.md": "# ilk\n"])
        let first = try service.plan(name: "s", kind: .skill, externalPath: root.path)
        _ = try service.adopt(first)

        // The external install moves on, and one of Uncoil's files is not in it.
        try Data("# ikinci\n".utf8).write(to: root.appendingPathComponent("SKILL.md"))
        try Data("x".utf8).write(
            to: URL(fileURLWithPath: first.destinationPath).appendingPathComponent("extra.md")
        )
        let second = try service.plan(name: "s", kind: .skill, externalPath: root.path)
        XCTAssertEqual(
            second.changes.first { $0.path == "SKILL.md" }?.kind, .modified
        )
        XCTAssertEqual(
            second.changes.first { $0.path == "extra.md" }?.kind, .removed,
            "a file only Uncoil has would be left behind, and that is shown"
        )

        _ = try service.adopt(second)
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: second.destinationPath)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# ikinci\n"
        )

        try service.rollback(second)
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: second.destinationPath)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# ilk\n",
            "the backup put the previous copy back"
        )
    }

    func testRollingBackAFirstAdoptionRemovesWhatWasAdded() throws {
        let root = try external(["SKILL.md": "# dış\n"])
        let plan = try service.plan(name: "s", kind: .skill, externalPath: root.path)
        _ = try service.adopt(plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destinationPath))

        try service.rollback(plan)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destinationPath),
            "there was nothing before, so nothing is what it goes back to"
        )
    }

    func testPlanningAnExternalPathThatIsNotThereFails() {
        XCTAssertThrowsError(
            try service.plan(name: "s", kind: .skill, externalPath: "/does/not/exist")
        )
    }
}

final class RemoteMCPProbeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func evaluate(_ status: Int, _ body: String = "") -> RemoteMCPStatus {
        RemoteMCPProbe.evaluate(
            .init(statusCode: status, body: body),
            url: "https://mcp.test/sse", transport: .http, now: now
        )
    }

    func testAServerReportsItsOwnVersionAndCapabilities() {
        let status = evaluate(200, """
        {
          "result": {
            "serverInfo": { "name": "acme-mcp", "version": "2.3.1" },
            "capabilities": { "tools": {}, "resources": {} }
          }
        }
        """)
        XCTAssertEqual(status.reachability, .reachable)
        XCTAssertEqual(status.serverName, "acme-mcp")
        XCTAssertEqual(status.serverVersion, "2.3.1")
        XCTAssertEqual(status.reportedCapabilities, ["resources", "tools"])
        XCTAssertEqual(status.versionLabel, "2.3.1")
    }

    func testAuthenticationIsItsOwnAnswerNotAFailure() {
        for code in [401, 403] {
            let status = evaluate(code)
            guard case .authenticationRequired(let message) = status.reachability else {
                return XCTFail("\(code) should read as authentication required")
            }
            XCTAssertTrue(message.contains("\(code)"))
            XCTAssertFalse(status.reachability.isHealthy)
        }
    }

    func testAnErrorStatusIsUnreachable() {
        guard case .unreachable = evaluate(503).reachability else {
            return XCTFail("503 is unreachable")
        }
    }

    func testAReachableServerThatSaysNothingHasNoVersion() {
        let status = evaluate(200, "merhaba")
        XCTAssertEqual(status.reachability, .reachable)
        XCTAssertNil(status.serverVersion)
        XCTAssertEqual(
            status.versionLabel, "sunucu sürüm bildirmedi",
            "an unreported version is never filled in from a repository"
        )
    }

    func testAStdioEndpointIsALocalProcessNotAnHTTPProbe() async {
        let probe = RemoteMCPProbe { _ in
            XCTFail("a STDIO endpoint must not be probed over HTTP")
            return .init(statusCode: 200, body: "")
        }
        let status = await probe.probe(url: "uncoil-mcp", transport: .stdio, now: now)
        XCTAssertEqual(status.reachability, .localProcess)
    }

    func testAnInvalidURLIsReportedWithoutSending() async {
        let probe = RemoteMCPProbe { _ in
            XCTFail("nothing should be sent")
            return .init(statusCode: 200, body: "")
        }
        let status = await probe.probe(url: "not a url", transport: .http, now: now)
        guard case .unreachable(let message) = status.reachability else {
            return XCTFail("expected unreachable")
        }
        XCTAssertTrue(message.contains("URL"))
    }

    func testATransportErrorIsReportedAsUnreachable() async {
        let probe = RemoteMCPProbe { _ in
            throw RemoteMCPProbe.ProbeError.transport("ağ yok")
        }
        let status = await probe.probe(url: "https://mcp.test", transport: .http, now: now)
        guard case .unreachable(let message) = status.reachability else {
            return XCTFail("expected unreachable")
        }
        XCTAssertEqual(message, "ağ yok")
    }

    func testCapabilityDiffReportsBothDirections() {
        let diff = RemoteMCPCapabilityDiff.between(
            known: ["tools", "prompts"], reported: ["tools", "resources"]
        )
        XCTAssertEqual(diff.added, ["resources"])
        XCTAssertEqual(diff.removed, ["prompts"])
        XCTAssertEqual(diff.unchanged, ["tools"])
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(diff.summary.contains("+resources"))
        XCTAssertTrue(diff.summary.contains("-prompts"))

        let same = RemoteMCPCapabilityDiff.between(known: ["tools"], reported: ["tools"])
        XCTAssertTrue(same.isEmpty)
        XCTAssertEqual(same.summary, "Değişiklik yok")
    }
}
