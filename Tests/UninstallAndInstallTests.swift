import XCTest
@testable import Uncoil

@MainActor
final class UninstallServiceTests: XCTestCase {
    private var base: URL!
    private var dataDirectory: URL!
    private var layout: ExtensionStoreLayout!
    private var home: URL!
    private var agentSkills: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilUninstall-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = base.appendingPathComponent("Application Support/Uncoil", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        home = base.appendingPathComponent("home", isDirectory: true)
        agentSkills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentSkills, withIntermediateDirectories: true)
        try layout.ensure()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func service(managed: Set<String> = ["review"]) -> UninstallService {
        UninstallService(
            dataDirectory: dataDirectory,
            extensionLayout: layout,
            agentSkillDirectories: [agentSkills],
            managedSkillNames: managed,
            homeDirectory: home
        )
    }

    private func seed() throws {
        for name in ["projects.json", "sessions.json", "settings.json", "permissions.json"] {
            try Data("{}".utf8).write(to: dataDirectory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: dataDirectory.appendingPathComponent("transcripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A skill Uncoil manages, linked into the agent's directory.
        let revision = layout.revisions.appendingPathComponent("rev-1", isDirectory: true)
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        try Data("# review\n".utf8).write(to: revision.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: agentSkills.appendingPathComponent("review"), withDestinationURL: revision
        )
        // A skill the user wrote themselves, right next to it.
        let mine = agentSkills.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("# elle yazdım\n".utf8).write(to: mine.appendingPathComponent("SKILL.md"))
        // Agent configs.
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        // Uncoil's own lock file.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".agents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: home.appendingPathComponent(".agents/.skill-lock.json")
        )
    }

    func testThePlanListsWhatGoesAndWhatStays() throws {
        try seed()
        let plan = service().plan()
        let removed = Set(plan.removals.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let kept = Set(plan.kept.map { URL(fileURLWithPath: $0.path).lastPathComponent })

        XCTAssertTrue(removed.contains("projects.json"))
        XCTAssertTrue(removed.contains("transcripts"))
        XCTAssertTrue(removed.contains("review"), "the link Uncoil made")
        XCTAssertTrue(removed.contains(".skill-lock.json"))
        XCTAssertTrue(kept.contains("mine"), "the user's own skill")
        XCTAssertTrue(kept.contains(".claude.json"), "the agent's own config")
        XCTAssertTrue(plan.summary.contains("silinecek"))
    }

    func testTheUsersOwnFilesSurviveTheUninstall() throws {
        try seed()
        let service = self.service()
        let result = service.perform(service.plan())
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataDirectory.appendingPathComponent("projects.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: agentSkills.appendingPathComponent("review").path
        ))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: agentSkills.appendingPathComponent("mine/SKILL.md").path
            ),
            "a skill the user wrote is not Uncoil's to delete"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path),
            "and neither is the agent's config"
        )
    }

    func testALinkUncoilDidNotMakeIsLeftAlone() throws {
        try seed()
        // A symlink with a managed-looking name that Uncoil does not own.
        try FileManager.default.createSymbolicLink(
            at: agentSkills.appendingPathComponent("someone-else"),
            withDestinationURL: base.appendingPathComponent("elsewhere", isDirectory: true)
        )
        let plan = service(managed: ["review"]).plan()
        XCTAssertTrue(
            plan.kept.contains { $0.path.hasSuffix("someone-else") },
            "only the names Uncoil manages are removed"
        )
    }

    func testAnEmptyInstallationPlansNothingDestructive() {
        let plan = service().plan()
        XCTAssertTrue(plan.removals.isEmpty || plan.removals.allSatisfy {
            $0.path.contains("store")
        })
    }
}

final class CrashReportingPolicyTests: XCTestCase {
    func testReportingIsOffByDefault() {
        XCTAssertFalse(CrashReportingPolicy.default.isEnabled)
        XCTAssertTrue(CrashReportingPolicy.default.summary.contains("Off"))
    }

    func testNothingIsCollectedWhileItIsOff() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(CrashReportingPolicy.default.crashLogPaths(home: home).isEmpty)
    }

    func testTheNetworkPromiseIsUnconditional() {
        XCTAssertTrue(
            CrashReportingPolicy.networkStatement.contains("göndermez"),
            CrashReportingPolicy.networkStatement
        )
        var enabled = CrashReportingPolicy.default
        enabled.isEnabled = true
        XCTAssertTrue(
            enabled.summary.contains("yerel"),
            "even when on, it is local: \(enabled.summary)"
        )
    }

    func testThePolicyRoundTripsThroughCoding() throws {
        var policy = CrashReportingPolicy.default
        policy.isEnabled = true
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(CrashReportingPolicy.self, from: data), policy)
    }
}

/// Aşama 21 — a clean machine and an upgrade from an older layout.
@MainActor
final class CleanInstallAndMigrationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    func testAFirstLaunchOnACleanMachineStartsEmptyAndWritable() throws {
        let directory = base.appendingPathComponent("fresh/Uncoil", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let store = ProjectStore(directory: directory)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "the data directory is created on first use"
        )

        // And the first write lands in a file the next launch can read.
        let project = base.appendingPathComponent("proje", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.addProject(at: project)
        XCTAssertEqual(ProjectStore(directory: directory).projects.count, 1)

        let layout = ExtensionStoreLayout(
            root: base.appendingPathComponent("fresh/extensions", isDirectory: true)
        )
        try layout.ensure()
        for url in layout.allDirectories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        let registry = ExtensionRegistry(
            layout: layout, store: SkillStore(layout: layout)
        )
        XCTAssertTrue(registry.packages.isEmpty)
        XCTAssertEqual(registry.overview.managedSkills, 0)
    }

    func testAnUpgradeReadsWhatAnOlderVersionWrote() throws {
        let directory = base.appendingPathComponent("upgrade/Uncoil", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // What older builds wrote: bare arrays with no schema version, and sessions
        // at schema 1.
        let project = Project(name: "eski proje", rootPath: "/tmp/eski")
        try JSONEncoder().encode([project]).write(
            to: directory.appendingPathComponent("projects.json")
        )
        let group = SessionGroup(projectID: project.id, name: "eski grup")
        try JSONEncoder().encode([group]).write(
            to: directory.appendingPathComponent("session-groups.json")
        )
        let session = SessionRecord(
            projectID: project.id, provider: .claude, accountID: nil, title: "eski oturum"
        )
        try JSONEncoder().encode([session]).write(
            to: directory.appendingPathComponent("sessions.json")
        )

        let store = ProjectStore(directory: directory)
        XCTAssertEqual(store.projects.map(\.name), ["eski proje"])
        XCTAssertEqual(store.sessionGroups.map(\.name), ["eski grup"])
        XCTAssertEqual(store.sessions.map(\.title), ["eski oturum"])
        XCTAssertEqual(
            store.sessions.first?.metadataVersion, SessionRecord.currentMetadataVersion,
            "the record is migrated forward, not left at the old shape"
        )

        // And what it writes back declares its schema, so the next upgrade knows.
        let raw = try String(
            contentsOf: directory.appendingPathComponent("projects.json"), encoding: .utf8
        )
        // Rewritten only after a change; make one.
        store.addProject(at: base)
        let rewritten = try String(
            contentsOf: directory.appendingPathComponent("projects.json"), encoding: .utf8
        )
        XCTAssertFalse(raw.contains("schemaVersion"), "the file started without one")
        XCTAssertTrue(rewritten.contains("schemaVersion"), rewritten)
    }

    func testADocumentFromANewerVersionIsRefusedRatherThanMisread() throws {
        let directory = base.appendingPathComponent("downgrade/Uncoil", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // What a future build might write.
        try Data(#"{"schemaVersion":99,"payload":[{"id":"x","name":"gelecek","rootPath":"/x"}]}"#.utf8)
            .write(to: directory.appendingPathComponent("projects.json"))

        let store = ProjectStore(directory: directory)
        XCTAssertTrue(
            store.projects.isEmpty,
            "a shape this build does not understand is not half-read"
        )
    }
}
