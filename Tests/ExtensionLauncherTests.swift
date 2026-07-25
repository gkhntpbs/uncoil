import XCTest
@testable import Uncoil

// MARK: - Manifest

final class ExtensionLaunchManifestTests: XCTestCase {
    func testRuntimeIsInferredFromTheEntrypoint() {
        XCTAssertEqual(.node, ExtensionLaunchManifest.Runtime.inferred(fromEntrypoint: "server.js"))
        XCTAssertEqual(.node, ExtensionLaunchManifest.Runtime.inferred(fromEntrypoint: "dist/index.mjs"))
        XCTAssertEqual(.python, ExtensionLaunchManifest.Runtime.inferred(fromEntrypoint: "main.py"))
        XCTAssertEqual(.shell, ExtensionLaunchManifest.Runtime.inferred(fromEntrypoint: "run.sh"))
        XCTAssertEqual(.binary, ExtensionLaunchManifest.Runtime.inferred(fromEntrypoint: "server"))
    }

    func testInterpreterIsNilOnlyForBinaries() {
        XCTAssertNil(ExtensionLaunchManifest.Runtime.binary.interpreter)
        XCTAssertEqual(ExtensionLaunchManifest.Runtime.node.interpreter, "node")
        XCTAssertEqual(ExtensionLaunchManifest.Runtime.python.interpreter, "python3")
        XCTAssertEqual(ExtensionLaunchManifest.Runtime.shell.interpreter, "/bin/sh")
    }

    func testManifestRoundTripsAndCarriesNoSecretValues() throws {
        let manifest = ExtensionLaunchManifest(entries: [
            .init(
                extensionID: "acme/mcp", name: "acme", revisionPath: "/active/acme",
                entrypoint: "server.js", runtime: .node,
                environment: ["ACME_REGION": "eu"],
                secretKeys: ["ACME_TOKEN"], revisionID: "rev-1"
            ),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ACME_TOKEN"), "the name is needed")
        XCTAssertTrue(text.contains("ACME_REGION"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExtensionLaunchManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.entry(id: "acme/mcp")?.entrypoint, "server.js")
        XCTAssertNil(decoded.entry(id: "nope"))
    }

    func testRunRecordDistinguishesCleanExitFromCrash() {
        var record = ExtensionRunRecord(
            extensionID: "a", revisionID: "r", pid: 42,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(record.isRunning)
        record.endedAt = Date(timeIntervalSince1970: 5)
        record.exitCode = 0
        XCTAssertFalse(record.isRunning)
        XCTAssertFalse(record.crashed)

        record.exitCode = 1
        XCTAssertTrue(record.crashed)
        record.exitCode = nil
        record.signal = SIGSEGV
        XCTAssertTrue(record.crashed)
    }
}

// MARK: - Launcher service

@MainActor
final class ExtensionLauncherServiceTests: XCTestCase {
    private var layout: ExtensionStoreLayout!
    private var service: ExtensionLauncherService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        layout = ExtensionStoreLayout(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("UncoilLauncher-\(UUID().uuidString)", isDirectory: true)
        )
        try layout.ensure()
        service = ExtensionLauncherService(
            layout: layout, launcherPath: "/Helpers/uncoil-extension"
        )
    }

    private func package(
        _ id: String,
        name: String,
        state: ExtensionState = .active
    ) -> ExtensionPackage {
        ExtensionPackage(
            id: id, kind: .mcpServer, name: name,
            source: .managedGitHub(repository: "acme/mcp", subpath: nil, tracking: .branch("main")),
            state: state,
            activeRevision: InstalledRevision(
                id: "rev-1", commitSHA: "abc", contentHash: "h",
                path: layout.revision("rev-1").path, installedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    func testAgentConfigGetsTheFixedLauncherCommandNotTheRealBinary() {
        let definition = service.definition(
            for: package("acme/mcp", name: "acme"), secretKeys: ["ACME_TOKEN"]
        )
        XCTAssertEqual(definition.command, "/Helpers/uncoil-extension")
        XCTAssertEqual(definition.arguments, ["run", "acme/mcp"])
        XCTAssertEqual(definition.environmentKeys, ["ACME_TOKEN"])
        XCTAssertTrue(definition.environment.isEmpty, "no secret values in the definition")
    }

    func testDisabledPackageProducesADisabledDefinition() {
        XCTAssertFalse(
            service.definition(for: package("a", name: "a", state: .disabled)).isEnabled
        )
    }

    func testManifestIsWrittenAtomicallyAndReadBack() throws {
        let written = try service.writeManifest(
            packages: [package("acme/mcp", name: "acme")],
            entrypoints: ["acme/mcp": "dist/server.js"],
            environments: ["acme/mcp": ["ACME_REGION": "eu"]],
            secretKeys: ["acme/mcp": ["ACME_TOKEN"]]
        )
        XCTAssertEqual(written.entries.count, 1)
        let entry = service.readManifest()?.entry(id: "acme/mcp")
        XCTAssertEqual(entry?.runtime, .node)
        XCTAssertEqual(entry?.revisionPath, layout.activeSkill("acme").path)
        XCTAssertEqual(entry?.revisionID, "rev-1")
        XCTAssertEqual(entry?.secretKeys, ["ACME_TOKEN"])
        XCTAssertFalse(entry?.isQuarantined ?? true)
    }

    func testQuarantinedAndDisabledExtensionsStayInTheManifestMarked() throws {
        try service.writeManifest(
            packages: [
                package("q", name: "q", state: .quarantined),
                package("d", name: "d", state: .disabled),
            ],
            entrypoints: ["q": "server.js", "d": "server.js"]
        )
        let manifest = service.readManifest()
        XCTAssertEqual(manifest?.entry(id: "q")?.isQuarantined, true)
        XCTAssertEqual(
            manifest?.entry(id: "d")?.isQuarantined,
            true,
            "a disabled extension must not start either"
        )
    }

    func testSkillsAndEntrypointlessPackagesAreNotLaunchable() throws {
        let skill = ExtensionPackage(
            id: "s", kind: .skill, name: "s", source: .local(path: "/tmp/s")
        )
        let manifest = try service.writeManifest(
            packages: [skill, package("no-entry", name: "no-entry")],
            entrypoints: [:]
        )
        XCTAssertTrue(manifest.entries.isEmpty)
    }

    func testRunRecordsAreReadNewestFirst() throws {
        let runs = layout.root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (index, offset) in [10.0, 30.0, 20.0].enumerated() {
            let record = ExtensionRunRecord(
                extensionID: "acme/mcp", revisionID: "rev-1", pid: Int32(100 + index),
                startedAt: Date(timeIntervalSince1970: offset)
            )
            try encoder.encode(record).write(to: runs.appendingPathComponent("r\(index).json"))
        }
        XCTAssertEqual(service.runRecords().map(\.pid), [101, 102, 100])
    }
}

// MARK: - Secrets

@MainActor
final class ExtensionSecretStoreTests: XCTestCase {
    /// A private service name keeps these items out of the real app's keychain
    /// entries, and lets the test clean up after itself.
    private var store: ExtensionSecretStore!
    private let extensionID = "acme/mcp"

    override func setUp() {
        super.setUp()
        store = ExtensionSecretStore(
            service: "com.gkhntpbs.uncoil.tests.\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        store.delete(extensionID: extensionID, key: "ACME_TOKEN")
        store.delete(extensionID: extensionID, key: "OTHER")
        super.tearDown()
    }

    func testAccountNameCarriesTheExtensionAndKey() {
        let account = ExtensionSecretStore.account(extensionID: "a/b", key: "TOKEN")
        let parsed = ExtensionSecretStore.parseAccount(account)
        XCTAssertEqual(parsed?.extensionID, "a/b")
        XCTAssertEqual(parsed?.key, "TOKEN")
        XCTAssertNil(ExtensionSecretStore.parseAccount("no-separator"))
        XCTAssertNil(ExtensionSecretStore.parseAccount("#TOKEN"))
    }

    func testSaveReadDeleteRoundTrip() throws {
        store.save(extensionID: extensionID, key: "ACME_TOKEN", value: "s3cret")
        guard store.read(extensionID: extensionID, key: "ACME_TOKEN") == "s3cret" else {
            throw XCTSkip("keychain is not writable in this environment")
        }
        store.save(extensionID: extensionID, key: "ACME_TOKEN", value: "rotated")
        XCTAssertEqual(store.read(extensionID: extensionID, key: "ACME_TOKEN"), "rotated")
        store.delete(extensionID: extensionID, key: "ACME_TOKEN")
        XCTAssertNil(store.read(extensionID: extensionID, key: "ACME_TOKEN"))
    }

    func testMissingKeysAreReportedRatherThanSilentlyEmpty() throws {
        store.save(extensionID: extensionID, key: "ACME_TOKEN", value: "s3cret")
        guard store.read(extensionID: extensionID, key: "ACME_TOKEN") != nil else {
            throw XCTSkip("keychain is not writable in this environment")
        }
        let resolved = store.environment(
            for: extensionID, keys: ["ACME_TOKEN", "MISSING"]
        )
        XCTAssertEqual(resolved.environment, ["ACME_TOKEN": "s3cret"])
        XCTAssertEqual(resolved.missing, ["MISSING"])
    }

    func testInventoryListsKeyNamesWithoutValues() throws {
        store.save(extensionID: extensionID, key: "ACME_TOKEN", value: "s3cret")
        store.save(extensionID: extensionID, key: "OTHER", value: "v")
        guard store.read(extensionID: extensionID, key: "ACME_TOKEN") != nil else {
            throw XCTSkip("keychain is not writable in this environment")
        }
        let inventory = store.inventory()
        XCTAssertEqual(inventory[extensionID], ["ACME_TOKEN", "OTHER"])
    }

    func testMaskingHidesSecretValuesInText() {
        let masked = ExtensionSecretStore.masked(
            "npx --token s3cretvalue --region eu", values: ["s3cretvalue", "eu"]
        )
        XCTAssertFalse(masked.contains("s3cretvalue"))
        XCTAssertTrue(masked.contains("--region eu"), "short values are left alone")
    }
}

// MARK: - Supervision

@MainActor
final class MCPProcessSupervisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func record(
        pid: Int32,
        revision: String? = "rev-2",
        startedAgo: TimeInterval = 10,
        endedAgo: TimeInterval? = nil,
        exitCode: Int32? = nil,
        signal: Int32? = nil,
        agent: String? = "claudeCode"
    ) -> ExtensionRunRecord {
        ExtensionRunRecord(
            extensionID: "acme/mcp",
            revisionID: revision,
            pid: pid,
            startedAt: now.addingTimeInterval(-startedAgo),
            endedAt: endedAgo.map { now.addingTimeInterval(-$0) },
            exitCode: exitCode,
            signal: signal,
            agent: agent
        )
    }

    private func supervisor(alive: Set<Int32> = []) -> MCPProcessSupervisor {
        var supervisor = MCPProcessSupervisor()
        supervisor.isProcessAlive = { alive.contains($0) }
        return supervisor
    }

    func testNeverStartedWhenThereAreNoRecords() {
        let health = supervisor().health(
            extensionID: "acme/mcp", records: [], activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(health.state, .neverStarted)
        XCTAssertTrue(health.isHealthy)
    }

    func testRunningOnlyCountsProcessesThatAreActuallyAlive() {
        let records = [record(pid: 10), record(pid: 11)]
        XCTAssertEqual(
            supervisor(alive: [10]).health(
                extensionID: "acme/mcp", records: records,
                activeRevisionID: "rev-2", now: now
            ).livePIDs,
            [10]
        )
        XCTAssertEqual(
            supervisor().health(
                extensionID: "acme/mcp", records: records,
                activeRevisionID: "rev-2", now: now
            ).state,
            .stopped,
            "a killed launcher never writes its ending"
        )
    }

    func testWhichAgentStartedItIsRecorded() {
        let health = supervisor(alive: [10]).health(
            extensionID: "acme/mcp",
            records: [record(pid: 10, agent: "codex"), record(pid: 11, agent: "claudeCode")],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(health.startedByAgents, ["claudeCode", "codex"])
    }

    func testCrashIsSurfacedAndRepeatedCrashesBecomeALoop() {
        let crashed = record(pid: 10, endedAgo: 5, signal: SIGSEGV)
        let single = supervisor().health(
            extensionID: "acme/mcp", records: [crashed],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(single.state, .crashed)
        XCTAssertEqual(single.lastSignal, SIGSEGV)
        XCTAssertTrue(single.isHealthy == false)

        let loop = supervisor().health(
            extensionID: "acme/mcp",
            records: [
                record(pid: 10, endedAgo: 5, exitCode: 1),
                record(pid: 11, endedAgo: 6, exitCode: 1),
                record(pid: 12, endedAgo: 7, exitCode: 1),
            ],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(loop.state, .crashLoop)
        XCTAssertEqual(loop.crashCount, 3)
    }

    func testOldCrashesFallOutOfTheWindow() {
        let health = supervisor().health(
            extensionID: "acme/mcp",
            records: [
                record(pid: 10, startedAgo: 5_000, endedAgo: 4_000, exitCode: 1),
                record(pid: 11, startedAgo: 5_001, endedAgo: 4_001, exitCode: 1),
                record(pid: 12, startedAgo: 5_002, endedAgo: 4_002, exitCode: 1),
            ],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(health.crashCount, 0)
        XCTAssertNotEqual(health.state, .crashLoop)
    }

    func testProcessesOnAnOldRevisionAskForARestart() {
        let health = supervisor(alive: [10, 11]).health(
            extensionID: "acme/mcp",
            records: [record(pid: 10, revision: "rev-1"), record(pid: 11, revision: "rev-2")],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(health.stalePIDs, [10])
        XCTAssertTrue(health.needsRestart)
        XCTAssertEqual(health.state, .running, "the current process is untouched")
    }

    func testRetiringStaleProcessesLeavesCurrentOnesRunning() {
        var signalled: [(Int32, Int32)] = []
        var supervisor = self.supervisor(alive: [10, 11])
        supervisor.terminate = { signalled.append(($0, $1)) }
        let health = supervisor.health(
            extensionID: "acme/mcp",
            records: [record(pid: 10, revision: "rev-1"), record(pid: 11, revision: "rev-2")],
            activeRevisionID: "rev-2", now: now
        )
        XCTAssertEqual(supervisor.retireStaleProcesses(health), [10])
        XCTAssertEqual(signalled.map(\.0), [10])
        XCTAssertEqual(signalled.map(\.1), [SIGTERM])
    }

    func testGracefulShutdownUsesSigtermAndForcedUsesSigkill() {
        var signalled: [(Int32, Int32)] = []
        var supervisor = self.supervisor(alive: [10])
        supervisor.terminate = { signalled.append(($0, $1)) }
        let health = supervisor.health(
            extensionID: "acme/mcp", records: [record(pid: 10)],
            activeRevisionID: "rev-2", now: now
        )
        supervisor.shutdown(health)
        supervisor.shutdown(health, graceful: false)
        XCTAssertEqual(signalled.map(\.1), [SIGTERM, SIGKILL])
    }

    func testChecksReportCrashLoopAsBlockingAndStaleAsWarning() {
        let supervisor = supervisor(alive: [10])
        let loop = supervisor.health(
            extensionID: "acme/mcp",
            records: [
                record(pid: 20, endedAgo: 5, exitCode: 1),
                record(pid: 21, endedAgo: 6, exitCode: 1),
                record(pid: 22, endedAgo: 7, exitCode: 1),
                record(pid: 10, revision: "rev-1"),
            ],
            activeRevisionID: "rev-2", now: now
        )
        let checks = supervisor.checks(loop, now: now)
        XCTAssertTrue(checks.contains { $0.isBlocking })
        XCTAssertTrue(checks.contains { $0.id.hasSuffix("stale") && $0.outcome == .warning })
        XCTAssertNotNil(checks.first { $0.isBlocking }?.remedy)
    }

    func testHealthIsGroupedPerExtension() {
        let records = [
            record(pid: 10),
            ExtensionRunRecord(
                extensionID: "other/mcp", revisionID: "rev-9", pid: 30,
                startedAt: now.addingTimeInterval(-5)
            ),
        ]
        let all = supervisor(alive: [10, 30]).healthByExtension(
            records: records,
            activeRevisions: ["acme/mcp": "rev-2", "other/mcp": "rev-9"],
            now: now
        )
        XCTAssertEqual(all.map(\.id), ["acme/mcp", "other/mcp"])
        XCTAssertTrue(all.allSatisfy { $0.state == .running })
    }
}
