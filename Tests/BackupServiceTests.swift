import XCTest
@testable import Uncoil

final class UncoilSchemaTests: XCTestCase {
    func testEverySchemaHasALabelAndAVersion() {
        for schema in UncoilSchema.allCases {
            XCTAssertFalse(schema.label.isEmpty, schema.rawValue)
            XCTAssertGreaterThan(schema.currentVersion, 0, schema.rawValue)
        }
        XCTAssertEqual(UncoilSchema.versions.count, UncoilSchema.allCases.count)
    }

    func testEveryStructureTheBacklogNamesIsVersioned() {
        // Aşama 19.3: these are the shapes that must carry a version.
        for schema: UncoilSchema in [
            .sessions, .sessionGroups, .extensionRegistry, .permissionPolicy,
            .runtimeProtocol, .auditLog, .securityFinding,
        ] {
            XCTAssertGreaterThan(schema.currentVersion, 0, schema.rawValue)
        }
    }

    func testADocumentFromTheFutureIsRefused() {
        XCTAssertFalse(UncoilSchema.projects.canRead(version: 99))
        XCTAssertFalse(UncoilSchema.projects.canRead(version: 0))
        XCTAssertTrue(UncoilSchema.projects.canRead(version: 1))
    }

    func testMigrationIsOnlyNeededForAnOlderReadableVersion() {
        XCTAssertFalse(UncoilSchema.projects.needsMigration(from: 1))
        XCTAssertFalse(
            UncoilSchema.projects.needsMigration(from: 99),
            "an unreadable version is refused, not migrated"
        )
        XCTAssertTrue(
            UncoilSchema.sessions.needsMigration(from: 1),
            "sessions are at version \(UncoilSchema.sessions.currentVersion)"
        )
    }

    func testALegacyBareArrayStillDecodes() throws {
        let legacy = try JSONEncoder().encode(["a", "b"])
        let decoded = VersionedDocument<[String]>.decode(legacy, schema: .projects)
        XCTAssertEqual(decoded?.payload, ["a", "b"])
        XCTAssertEqual(decoded?.version, 1, "a file with no version reads as the first one")

        let versioned = try JSONEncoder().encode(
            VersionedDocument(schemaVersion: 1, payload: ["c"])
        )
        XCTAssertEqual(
            VersionedDocument<[String]>.decode(versioned, schema: .projects)?.payload, ["c"]
        )
    }

    func testAVersionedDocumentFromTheFutureIsNotDecoded() throws {
        let future = try JSONEncoder().encode(
            VersionedDocument(schemaVersion: 99, payload: ["x"])
        )
        XCTAssertNil(VersionedDocument<[String]>.decode(future, schema: .projects))
    }
}

@MainActor
final class ProjectStoreVersioningTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilStoreVersion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testProjectsAndGroupsAreWrittenWithTheirSchemaVersion() throws {
        let store = ProjectStore(directory: directory)
        store.addProject(at: directory)
        let raw = try String(
            contentsOf: directory.appendingPathComponent("projects.json"), encoding: .utf8
        )
        XCTAssertTrue(raw.contains("schemaVersion"), raw)
        XCTAssertEqual(
            BackupService.declaredVersion(in: raw), UncoilSchema.projects.currentVersion
        )
    }

    func testAnOlderInstallationsBareArrayIsStillRead() throws {
        // What a previous build wrote: no version, just the array.
        let project = Project(name: "eski", rootPath: "/tmp/eski")
        try JSONEncoder().encode([project]).write(
            to: directory.appendingPathComponent("projects.json")
        )
        let store = ProjectStore(directory: directory)
        XCTAssertEqual(store.projects.map(\.name), ["eski"])
    }
}

@MainActor
final class BackupServiceTests: XCTestCase {
    private var base: URL!
    private var dataDirectory: URL!
    private var layout: ExtensionStoreLayout!
    private var service: BackupService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilBackup-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = base.appendingPathComponent("data", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try layout.ensure()
        service = BackupService(
            dataDirectory: dataDirectory, extensionLayout: layout, appVersion: "1.0.0"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, to name: String) throws {
        let url = dataDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func writeRegistry(_ packages: [ExtensionPackage]) throws {
        let document = ExtensionRegistry.Document(packages: packages)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: layout.locks.appendingPathComponent("registry.json")
        )
    }

    private func seed() throws {
        try write(#"{"schemaVersion":1,"payload":[{"id":"\#(UUID().uuidString)"}]}"#, to: "projects.json")
        try write(#"{"schemaVersion":2,"sessions":[]}"#, to: "sessions.json")
        try write(#"{"schemaVersion":1,"payload":[]}"#, to: "session-groups.json")
        try write(#"{"theme":"dark"}"#, to: "settings.json")
        try write(#"{"decisions":[{"key":"browser.navigate","granted":true}]}"#, to: "permissions.json")
        try write("konuşma", to: "transcripts/session-1.txt")
    }

    // MARK: - Backup

    func testABackupCarriesEverythingButTranscriptsByDefault() throws {
        try seed()
        try writeRegistry([])
        let backup = service.build(now: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(backup.includesTranscripts)
        XCTAssertFalse(backup.entries.contains { $0.contents.contains(.transcripts) })
        for content: BackupContent in [
            .settings, .projects, .sessions, .sessionGroups, .permissionDecisions,
            .extensionRegistry,
        ] {
            XCTAssertFalse(
                backup.entries(for: content).isEmpty, "\(content.rawValue) is missing"
            )
        }
        XCTAssertEqual(backup.appVersion, "1.0.0")
        XCTAssertEqual(backup.schemaVersions["projects"], UncoilSchema.projects.currentVersion)
    }

    func testTranscriptsAreIncludedOnlyWhenAskedFor() throws {
        try seed()
        let with = service.build(contents: BackupContent.allCases)
        XCTAssertTrue(with.includesTranscripts)
        XCTAssertEqual(with.entries(for: .transcripts).count, 1)
        XCTAssertTrue(BackupContent.transcripts.isOptIn)
        XCTAssertFalse(BackupContent.defaults.contains(.transcripts))
    }

    func testEachEntryRecordsTheSchemaVersionItWasWrittenWith() throws {
        try seed()
        let backup = service.build()
        XCTAssertEqual(backup.entries(for: .sessions).first?.schemaVersion, 2)
        XCTAssertEqual(backup.entries(for: .projects).first?.schemaVersion, 1)
    }

    func testAFileHoldingASecretValueIsNotExported() throws {
        try seed()
        try write(#"{"servers":{"x":{"env":{"API_TOKEN":"çok-gizli-bir-değer"}}}}"#, to: "settings.json")
        let backup = service.build()
        XCTAssertTrue(
            backup.entries(for: .settings).isEmpty,
            "a payload with a secret value is left out rather than exported"
        )
        XCTAssertFalse(
            backup.entries.contains { $0.payload.contains("çok-gizli-bir-değer") }
        )
    }

    func testSecretDetectionIgnoresKeyNamesWithoutValues() {
        XCTAssertFalse(
            BackupService.looksLikeASecret(#"{"environmentKeys":["API_TOKEN"]}"#),
            "a key name is a reference, not a secret"
        )
        XCTAssertTrue(
            BackupService.looksLikeASecret(#"{"env":{"password":"hunter2-uzun-değer"}}"#)
        )
    }

    // MARK: - Restore

    func testRestoreValidatesTheSchemaBeforeWritingAnything() throws {
        try seed()
        var backup = service.build()
        let index = try XCTUnwrap(
            backup.entries.firstIndex { $0.contents.contains(.projects) }
        )
        backup.entries[index].schemaVersion = 99
        let preview = service.preview(backup)
        XCTAssertFalse(preview.isRestorable)
        XCTAssertTrue(preview.fatalProblems.contains { $0.message.contains("okunamıyor") })
        XCTAssertThrowsError(try service.restore(backup))
    }

    func testABackupFromANewerUncoilIsRefused() throws {
        try seed()
        var backup = service.build()
        backup.version = UncoilBackup.currentVersion + 1
        XCTAssertFalse(service.preview(backup).isRestorable)
    }

    func testRestorePutsEveryFileBackAndReportsWhatItWrote() throws {
        try seed()
        try writeRegistry([])
        let backup = service.build()

        try write(#"{"schemaVersion":1,"payload":[]}"#, to: "projects.json")
        try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("settings.json"))

        let written = try service.restore(backup, now: Date(timeIntervalSince1970: 5))
        XCTAssertTrue(written.contains("projects.json"))
        XCTAssertTrue(written.contains("settings.json"))
        XCTAssertEqual(
            try String(
                contentsOf: dataDirectory.appendingPathComponent("settings.json"), encoding: .utf8
            ),
            #"{"theme":"dark"}"#
        )
        XCTAssertTrue(
            try String(
                contentsOf: dataDirectory.appendingPathComponent("projects.json"), encoding: .utf8
            ).contains("id")
        )
    }

    func testAFailedRestoreLeavesTheCurrentStateAlone() throws {
        try seed()
        var backup = service.build()
        // A path that cannot be written: restoring must undo what it managed to
        // write rather than leaving half the files replaced.
        // settings.json is a file, so a path treating it as a directory cannot be
        // created: a deterministic failure part-way through the restore.
        backup.entries.append(UncoilBackup.Entry(
            contents: [.settings], relativePath: "settings.json/child.json",
            schemaVersion: nil, payload: "{}"
        ))
        let before = try String(
            contentsOf: dataDirectory.appendingPathComponent("settings.json"), encoding: .utf8
        )
        try write(#"{"theme":"light"}"#, to: "settings.json")

        XCTAssertThrowsError(try service.restore(backup, now: Date(timeIntervalSince1970: 9)))
        let after = try String(
            contentsOf: dataDirectory.appendingPathComponent("settings.json"), encoding: .utf8
        )
        XCTAssertNotEqual(before, "")
        XCTAssertEqual(
            after, #"{"theme":"light"}"#,
            "the file the user had is what remains after a failed restore"
        )
    }

    func testAGitHubExtensionIsReportedAsReinstallableFromItsCommit() throws {
        try seed()
        var package = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = InstalledRevision(
            id: "rev1", commitSHA: "a1b2c3d4e5f67890", contentHash: "hash",
            path: layout.revisions.path, installedAt: Date(timeIntervalSince1970: 0)
        )
        try writeRegistry([package])

        let backup = service.build()
        let preview = service.preview(backup, installedPackages: [])
        XCTAssertTrue(preview.isRestorable, "a missing extension is a warning, not a wall")
        guard case .reinstallableFromCommit(_, let repository, let commit) = try XCTUnwrap(
            preview.warnings.first
        ) else {
            return XCTFail("expected a reinstall hint, got \(preview.warnings)")
        }
        XCTAssertEqual(repository, "acme/skills")
        XCTAssertEqual(commit, "a1b2c3d4e5f67890")
    }

    func testAManualExtensionWithMissingFilesIsWarnedAbout() throws {
        try seed()
        try writeRegistry([
            ExtensionPackage(
                id: "local:mine", kind: .skill, name: "mine",
                source: .local(path: "/does/not/exist"), state: .active
            ),
        ])
        let preview = service.preview(service.build())
        XCTAssertTrue(
            preview.warnings.contains { $0.message.contains("dosyaları yok") },
            "\(preview.warnings)"
        )
    }

    func testAnAlreadyInstalledExtensionIsNotReportedAsMissing() throws {
        try seed()
        let package = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        try writeRegistry([package])
        let preview = service.preview(service.build(), installedPackages: [package])
        XCTAssertTrue(preview.warnings.isEmpty, "\(preview.warnings)")
    }

    func testAgentConfigChangesArePreviewedNotApplied() throws {
        try seed()
        try writeRegistry([
            ExtensionPackage(
                id: "acme/mcp:uncoil", kind: .mcpServer, name: "uncoil",
                source: .managedGitHub(
                    repository: "acme/mcp", subpath: nil, tracking: .branch("main")
                ),
                state: .active
            ),
        ])
        let backup = service.build()
        let installation = AgentInstallation(
            agent: .claudeCode, binaryPath: "/usr/bin/true",
            configDirectory: "/home/.claude", skillsDirectory: nil,
            mcpConfigPath: "/home/.claude.json", version: nil, isAuthenticated: nil,
            detectedAt: Date(timeIntervalSince1970: 0)
        )
        let configuration = AgentConfiguration(
            installation: installation, path: "/home/.claude.json", raw: "{}", hash: "h",
            mcpServers: [], skillNames: []
        )
        let problems = service.agentConfigPreview(
            backup: backup, currentConfigurations: [configuration]
        )
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].message.contains("uncoil"), problems[0].message)
        XCTAssertFalse(problems[0].isFatal, "a preview is not a failure")
    }

    // MARK: - Files

    func testABackupRoundTripsThroughAFile() throws {
        try seed()
        let backup = service.build(now: Date(timeIntervalSince1970: 0))
        let url = base.appendingPathComponent("uncoil-backup.json")
        try service.write(backup, to: url)

        guard case .success(let read) = service.read(url) else {
            return XCTFail("the backup should read back")
        }
        XCTAssertEqual(read, backup)
    }

    func testAMissingOrBrokenBackupFileIsReportedNotCrashed() throws {
        guard case .failure(let missing) = service.read(
            base.appendingPathComponent("yok.json")
        ) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(missing.message.contains("dosya yok"))

        let broken = base.appendingPathComponent("broken.json")
        try Data("bu JSON değil".utf8).write(to: broken)
        guard case .failure(let unreadable) = service.read(broken) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(unreadable.isFatal)
    }

    func testEveryContentKindHasALabelAndAKnownHome() throws {
        try seed()
        try writeRegistry([])
        // Directory-backed contents are empty when nothing is in them; the
        // file-backed ones always name their file.
        let directoryBacked: Set<BackupContent> = [.extensionLocks, .transcripts]
        for content in BackupContent.allCases {
            XCTAssertFalse(content.label.isEmpty, content.rawValue)
            guard !directoryBacked.contains(content) else { continue }
            XCTAssertFalse(service.files(for: content).isEmpty, content.rawValue)
        }
        XCTAssertFalse(
            service.files(for: .transcripts).isEmpty,
            "the seeded transcript is found once it exists"
        )
    }

    func testTheSameFileIsNotBackedUpTwice() throws {
        try seed()
        try writeRegistry([])
        let backup = service.build()
        XCTAssertEqual(
            Set(backup.entries.map(\.relativePath)).count, backup.entries.count,
            "the registry answers for three contents but goes in once"
        )
    }
}
