import XCTest
@testable import Uncoil

/// Aşama 20 — the load and durability cases that can be checked deterministically.
///
/// The ones needing a live environment (ten agents running at once, a PTY open
/// for hours, agents running while the app is closed, sleep/wake reconnects, a
/// network coming and going) are not here: they need real agents and real time,
/// and a fake that merely looks like them would prove nothing.
@MainActor
final class LoadAndDurabilityTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var store: SkillStore!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilLoad-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try layout.ensure()
        store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("canonical", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    // MARK: - Stores under load

    func testAHundredSessionsAcrossTwentyProjectsStayConsistent() throws {
        let directory = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProjectStore(directory: directory)

        for index in 0..<20 {
            let root = base.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store.addProject(at: root)
        }
        XCTAssertEqual(store.projects.count, 20)

        for index in 0..<105 {
            let project = store.projects[index % store.projects.count]
            _ = store.createSession(
                projectID: project.id,
                provider: index.isMultiple(of: 2) ? .claude : .codex,
                accountID: nil,
                title: "session \(index)"
            )
        }
        XCTAssertEqual(store.sessions.count, 105)

        // Everything survives a reload, and each session still points at a
        // project that exists.
        let reloaded = ProjectStore(directory: directory)
        XCTAssertEqual(reloaded.projects.count, 20)
        XCTAssertEqual(reloaded.sessions.count, 105)
        let projectIDs = Set(reloaded.projects.map(\.id))
        XCTAssertTrue(
            reloaded.sessions.allSatisfy { projectIDs.contains($0.projectID) },
            "no session was orphaned by the round-trip"
        )
        XCTAssertEqual(
            Set(reloaded.sessions.map(\.id)).count, 105, "no id collided or was dropped"
        )
    }

    func testFiftySkillsAndThirtyMCPServersAreHandled() throws {
        let registry = ExtensionRegistry(layout: layout, store: store)
        for index in 0..<50 {
            registry.upsert(ExtensionPackage(
                id: "acme/skills:s\(index)", kind: .skill, name: "skill-\(index)",
                source: .managedGitHub(
                    repository: "acme/skills", subpath: "s\(index)", tracking: .branch("main")
                ),
                state: .active
            ))
        }
        for index in 0..<30 {
            registry.upsert(ExtensionPackage(
                id: "acme/mcp:m\(index)", kind: .mcpServer, name: "mcp-\(index)",
                source: .remoteMCP(url: "https://mcp\(index).test", transport: .http),
                state: .active
            ))
        }
        XCTAssertEqual(registry.skills.count, 50)
        XCTAssertEqual(registry.mcpServers.count, 30)

        // Assigning every skill to two agents stays one binding per pair.
        for package in registry.skills {
            registry.setAgentBinding(true, packageID: package.id, agent: .claudeCode)
            registry.setAgentBinding(true, packageID: package.id, agent: .codex)
        }
        XCTAssertEqual(registry.agentBindings.filter(\.isEnabled).count, 100)

        let reloaded = ExtensionRegistry(layout: layout, store: store)
        XCTAssertEqual(reloaded.packages.count, 80)
        XCTAssertEqual(reloaded.overview.managedSkills, 50)
        XCTAssertEqual(reloaded.overview.mcpServers, 30)
    }

    func testALargeRepositoryIsScannedWithoutWalkingEverything() throws {
        let root = base.appendingPathComponent("big-repo", isDirectory: true)
        // A few thousand files, most of them in directories discovery must skip.
        for directory in ["node_modules/pkg", ".build-cache/x", "src", "docs"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for index in 0..<500 {
                try Data("x".utf8).write(to: url.appendingPathComponent("f\(index).txt"))
            }
        }
        try Data("- [ ] kök görev\n".utf8).write(to: root.appendingPathComponent("TODO.md"))
        try Data("- [ ] doküman görevi\n".utf8).write(
            to: root.appendingPathComponent("docs/TODO.md")
        )
        try Data("- [ ] görülmemeli\n".utf8).write(
            to: root.appendingPathComponent("node_modules/pkg/TODO.md")
        )

        let started = Date()
        let found = TodoDiscovery.load(
            projectID: UUID(), projectRoot: root.path, rules: .default, now: now
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(
            Set(found.map { URL(fileURLWithPath: $0.source.path).lastPathComponent }),
            ["TODO.md"]
        )
        XCTAssertEqual(found.count, 2, "the root and docs files, not the vendored one")
        XCTAssertFalse(
            found.contains { $0.source.path.contains("node_modules") },
            "vendored directories are skipped, which is why this stays fast"
        )
        XCTAssertLessThan(elapsed, 10, "a 2000-file repo took \(elapsed)s")
    }

    // A very large replay is bounded by the daemon, and
    // `RuntimeDaemonIntegrationTests` checks it there against
    // `RuntimeProtocol.replayBufferLimit` and `replayDiskLimit` — the buffer is
    // the daemon's, so that is where the test belongs.

    func testManyBrokenSymlinksAreReportedAndRepairableInOnePass() throws {
        let agent = base.appendingPathComponent("agent-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)

        var names: [String] = []
        for index in 0..<60 {
            let name = "skill-\(index)"
            names.append(name)
            let source = base.appendingPathComponent("src-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("# skill\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
            let revision = try store.install(
                from: source, name: name, revisionID: "rev-\(name)", commitSHA: nil, now: now
            )
            _ = revision
            _ = try store.link(name: name, intoAgentDirectory: agent)
        }
        // Every link breaks at once — what a moved store directory looks like.
        for name in names {
            try FileManager.default.removeItem(at: layout.activeSkill(name))
        }

        let broken = names.filter {
            store.status(name: $0, inAgentDirectory: agent).needsRepair
        }
        XCTAssertEqual(broken.count, 60, "all of them are reported, not a sample")
        for name in names {
            try store.activate(revisionID: "rev-\(name)", name: name)
            XCTAssertEqual(try store.repair(name: name, inAgentDirectory: agent), .linked)
        }
        XCTAssertTrue(
            names.allSatisfy { !store.status(name: $0, inAgentDirectory: agent).needsRepair }
        )
    }

    // MARK: - Failure conditions

    func testAFullDiskRefusesAnUpdateInsteadOfHalfWritingIt() throws {
        var engine = ExtensionUpdateEngine(
            mirror: ExtensionMirror(layout: layout), store: store
        )
        // More free space required than any disk has.
        engine.minimumFreeBytes = Int64.max
        let package = ExtensionPackage(
            id: "acme/skills:x", kind: .skill, name: "x",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        XCTAssertThrowsError(
            try engine.stage(
                UpdateCandidate(
                    extensionID: package.id, installedCommitSHA: nil,
                    availableCommitSHA: "abc123", commitCount: 1, changedFiles: [],
                    fetchedAt: now
                ),
                package: package
            )
        ) { error in
            XCTAssertTrue(
                "\(error)".lowercased().contains("disk")
                    || (error as? ExtensionUpdateError) != nil,
                "\(error)"
            )
        }
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: layout.revisions.path))?
                .isEmpty ?? true,
            "nothing was written on the way to failing"
        )
    }

    func testAnInterruptedUpdateLeavesTheRegistryConsistent() throws {
        let registry = ExtensionRegistry(layout: layout, store: store)
        let source = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# skill\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let revision = try store.install(
            from: source, name: "x", revisionID: "rev-1", commitSHA: "c1", now: now
        )
        var package = ExtensionPackage(
            id: "acme/skills:x", kind: .skill, name: "x",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = revision
        registry.upsert(package)

        // A staging directory from a process that never finished.
        let orphan = layout.revisions.appendingPathComponent("staging-half", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let engine = ExtensionUpdateEngine(mirror: ExtensionMirror(layout: layout), store: store)
        _ = engine.recoverAfterInterruption(packages: registry.packages)

        let reloaded = ExtensionRegistry(layout: layout, store: store)
        XCTAssertEqual(reloaded.package(id: package.id)?.activeRevision?.id, "rev-1")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: revision.path)
                    .appendingPathComponent("SKILL.md").path
            ),
            "the revision that was active is intact"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.activeSkill("x").path
            ).contains("rev-1"),
            true
        )
    }

    func testAnMCPCrashLoopIsDetectedAndNotRestartedForever() {
        var supervisor = MCPProcessSupervisor()
        supervisor.isProcessAlive = { _ in false }
        supervisor.crashLoopThreshold = 3
        let records = (0..<5).map { index in
            ExtensionRunRecord(
                extensionID: "x", revisionID: "rev", pid: Int32(1_000 + index),
                startedAt: now.addingTimeInterval(Double(index) * 5),
                endedAt: now.addingTimeInterval(Double(index) * 5 + 1),
                exitCode: 1, signal: nil, agent: "claudeCode"
            )
        }
        let health = supervisor.health(
            extensionID: "x", records: records, activeRevisionID: "rev",
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(health.state, .crashLoop)
        XCTAssertFalse(health.isHealthy)
        let checks = supervisor.checks(health, now: now.addingTimeInterval(30))
        XCTAssertTrue(
            checks.contains { $0.outcome == .failure },
            "a crash loop is a failure the user sees, not a silent retry"
        )
    }

    func testConfigChangedUnderneathIsCaughtByTheHash() throws {
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent(".claude.json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: configURL)

        var adapter = ClaudeCodeAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "x", name: "uncoil", transport: .stdio, command: "/Helpers/uncoil-mcp"
            ))],
            for: try adapter.readConfiguration(installation)
        )
        try Data(#"{"mcpServers":{"elle":{"command":"elle"}}}"#.utf8).write(to: configURL)
        XCTAssertEqual(try adapter.apply(transaction).status, .staleConfig)
    }
}
