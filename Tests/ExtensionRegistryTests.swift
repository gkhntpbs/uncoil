import XCTest
@testable import Uncoil

@MainActor
final class ExtensionRegistryTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var store: SkillStore!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000)
    private let launcherPath = "/Helpers/uncoil-extension"

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilRegistry-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("agents/skills", isDirectory: true)
        )
        registry = ExtensionRegistry(layout: layout, store: store)
    }

    // MARK: - Fixture agents

    private func claudeHome(mcpServers: String = "{}") throws -> URL {
        let home = base.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/skills", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(mcpServers.utf8).write(to: home.appendingPathComponent(".claude.json"))
        return home
    }

    private func adapters(home: URL) -> AgentAdapterRegistry {
        var adapter = ClaudeCodeAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        return AgentAdapterRegistry(adapters: [adapter])
    }

    private func makeSkill(_ name: String) throws -> URL {
        let url = base.appendingPathComponent("source/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("# \(name)\n".utf8).write(to: url.appendingPathComponent("SKILL.md"))
        return url
    }

    // MARK: - Persistence

    func testRegistrySurvivesAReload() throws {
        let package = ExtensionPackage(
            id: "acme/skill", kind: .skill, name: "writer",
            source: .managedGitHub(repository: "acme/skills", subpath: "writer", tracking: .branch("main"))
        )
        registry.upsert(package)
        registry.setAgentBinding(true, packageID: package.id, agent: .claudeCode)
        registry.addSource("acme/skills")

        let reloaded = ExtensionRegistry(layout: layout, store: store)
        XCTAssertEqual(reloaded.packages.map(\.id), ["acme/skill"])
        XCTAssertEqual(reloaded.agents(for: "acme/skill"), [.claudeCode])
        XCTAssertEqual(reloaded.sources, ["acme/skills"])
    }

    func testAuditLogIsAppendOnlyAndSurvivesReload() {
        registry.record(AuditEvent(kind: .skillInstalled, extensionID: "a", detail: "kuruldu", at: now))
        registry.record(AuditEvent(kind: .updateApplied, extensionID: "a", detail: "güncellendi", at: now))
        XCTAssertEqual(registry.auditEvents.count, 2)

        let reloaded = ExtensionRegistry(layout: layout, store: store)
        XCTAssertEqual(reloaded.auditEvents.count, 2)
        XCTAssertEqual(
            reloaded.auditEvents.first?.kind,
            .updateApplied,
            "newest first"
        )
    }

    func testStateChangesAreAudited() {
        registry.upsert(ExtensionPackage(
            id: "a", kind: .skill, name: "a", source: .local(path: "/tmp/a")
        ))
        registry.setState(.quarantined, packageID: "a")
        registry.setState(.active, packageID: "a")
        XCTAssertEqual(registry.auditEvents.map(\.kind), [.restored, .quarantined])
    }

    func testRemovingAPackageDropsItsBindingsAndFindings() {
        registry.upsert(ExtensionPackage(id: "a", kind: .skill, name: "a", source: .local(path: "/x")))
        registry.setAgentBinding(true, packageID: "a", agent: .codex)
        registry.setProjectBinding(ProjectBinding(extensionID: "a", projectID: UUID()))
        registry.setFindings([
            SecurityFinding(
                id: "f", origin: .uncoil, severity: .high, rule: "r", message: "m",
                extensionID: "a", foundAt: now
            ),
        ], forExtension: "a")

        registry.remove(packageID: "a")
        XCTAssertTrue(registry.packages.isEmpty)
        XCTAssertTrue(registry.agentBindings.isEmpty)
        XCTAssertTrue(registry.projectBindings.isEmpty)
        XCTAssertTrue(registry.findings.isEmpty)
    }

    // MARK: - Discovery

    func testDiscoverySplitsManagedFromUnmanagedMCPServers() throws {
        let home = try claudeHome(mcpServers: """
        {"mcpServers": {
          "ours": {"command": "\(launcherPath)", "args": ["run", "acme/mcp"]},
          "theirs": {"command": "npx", "args": ["-y", "some-mcp"]},
          "remote": {"url": "https://mcp.notion.com/mcp"}
        }}
        """)
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)

        let ids = Set(registry.mcpServers.map(\.id))
        XCTAssertTrue(ids.contains("acme/mcp"), "our launcher's id comes from the arguments")
        XCTAssertTrue(ids.contains("claudeCode:theirs"))
        XCTAssertTrue(ids.contains("claudeCode:remote"))

        let theirs = registry.package(id: "claudeCode:theirs")
        XCTAssertFalse(theirs?.source.isManaged ?? true)
        XCTAssertFalse(theirs?.source.isOwnedByUncoil ?? true)
        XCTAssertTrue(theirs?.source.label.contains("Unmanaged") ?? false)

        if case .remoteMCP(let url, let transport) = registry.package(id: "claudeCode:remote")?.source {
            XCTAssertEqual(url, "https://mcp.notion.com/mcp")
            XCTAssertEqual(transport, .http)
        } else {
            XCTFail("a url-only server is a remote MCP")
        }
    }

    func testRemoteMCPIsNotUpdateCheckedAndSaysSo() throws {
        let home = try claudeHome(mcpServers: """
        {"mcpServers": {"remote": {"url": "https://mcp.notion.com/mcp"}}}
        """)
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertFalse(registry.package(id: "claudeCode:remote")?.supportsUpdateCheck ?? true)
        XCTAssertTrue(
            registry.health.contains { $0.id == "health.remote" && $0.outcome == .notApplicable }
        )
    }

    func testDiscoveryRecordsUsersOwnSkillsWithoutTouchingThem() throws {
        let home = try claudeHome()
        let manual = home.appendingPathComponent(".claude/skills/mine", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: manual.appendingPathComponent("SKILL.md"))

        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)

        XCTAssertEqual(registry.unmanagedSkills[.claudeCode], ["mine"])
        let package = registry.package(id: "local:mine")
        XCTAssertEqual(package?.kind, .skill)
        XCTAssertFalse(package?.source.isOwnedByUncoil ?? true)
        XCTAssertFalse(package?.supportsUpdateCheck ?? true, "no update button for a local skill")
        XCTAssertEqual(
            try String(contentsOf: manual.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "# mine\n",
            "discovery never modifies the user's files"
        )
    }

    func testDiscoveryKeepsManagedPackagesAcrossRuns() throws {
        let managed = ExtensionPackage(
            id: "acme/mcp", kind: .mcpServer, name: "acme",
            source: .managedGitHub(repository: "acme/mcp", subpath: nil, tracking: .branch("main"))
        )
        registry.upsert(managed)
        let home = try claudeHome()
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertTrue(
            registry.packages.contains { $0.id == "acme/mcp" },
            "a managed package is not forgotten because a config stopped listing it"
        )
    }

    func testLocalModificationOfAManagedSkillIsDetected() throws {
        let revision = try store.install(from: try makeSkill("writer"), name: "writer", revisionID: "rev-1")
        registry.upsert(ExtensionPackage(
            id: "acme/writer", kind: .skill, name: "writer",
            source: .managedGitHub(repository: "acme/skills", subpath: "writer", tracking: .branch("main")),
            activeRevision: revision
        ))
        let home = try claudeHome()
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertFalse(registry.package(id: "acme/writer")?.hasLocalModification ?? true)
        XCTAssertEqual(registry.configDriftCount, 0)

        try Data("# edited\n".utf8).write(
            to: URL(fileURLWithPath: revision.path).appendingPathComponent("SKILL.md")
        )
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertTrue(registry.package(id: "acme/writer")?.hasLocalModification ?? false)
        XCTAssertEqual(registry.configDriftCount, 1)
    }

    func testBrokenLinkShowsUpInHealthAndBrokenList() throws {
        let revision = try store.install(from: try makeSkill("writer"), name: "writer", revisionID: "rev-1")
        registry.upsert(ExtensionPackage(
            id: "acme/writer", kind: .skill, name: "writer",
            source: .managedGitHub(repository: "acme/skills", subpath: "writer", tracking: .branch("main")),
            activeRevision: revision
        ))
        let home = try claudeHome()
        let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        try store.link(name: "writer", intoAgentDirectory: skills)
        // The assignment is what says this agent is meant to have the link; a
        // missing link only means "broken" for an agent the skill was given to.
        registry.setAgentBinding(true, packageID: "acme/writer", agent: .claudeCode)

        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertTrue(registry.brokenPackages.isEmpty)
        XCTAssertTrue(registry.health.contains { $0.id == "health.links" && $0.outcome == .ok })

        try FileManager.default.removeItem(at: skills.appendingPathComponent("writer"))
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertEqual(registry.brokenPackages.map(\.id), ["acme/writer"])
        XCTAssertTrue(
            registry.health.contains { $0.id == "health.links" && $0.outcome == .failure }
        )
    }

    func testMalformedAgentConfigIsReportedNotFatal() throws {
        let home = try claudeHome(mcpServers: "{ not json")
        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        XCTAssertFalse(registry.configurationIssues.isEmpty)
        XCTAssertTrue(registry.health.contains { $0.id == "health.agents" })
    }

    func testNoAgentsIsAFailingHealthCheck() {
        registry.discover(
            adapters: AgentAdapterRegistry(adapters: []),
            launcherPath: launcherPath, now: now
        )
        XCTAssertTrue(
            registry.health.contains { $0.id == "health.agents" && $0.outcome == .failure }
        )
    }

    // MARK: - Overview and findings

    func testOverviewCountsWhatTheScreenShows() throws {
        let home = try claudeHome(mcpServers: """
        {"mcpServers": {"theirs": {"command": "npx"}}}
        """)
        let manual = home.appendingPathComponent(".claude/skills/mine", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: manual.appendingPathComponent("SKILL.md"))

        let revision = try store.install(from: try makeSkill("writer"), name: "writer", revisionID: "rev-1")
        registry.upsert(ExtensionPackage(
            id: "acme/writer", kind: .skill, name: "writer",
            source: .managedGitHub(repository: "acme/skills", subpath: "writer", tracking: .branch("main")),
            activeRevision: revision
        ))
        registry.setUpdateCandidates([
            UpdateCandidate(
                extensionID: "acme/writer", installedCommitSHA: "a",
                availableCommitSHA: "b", commitCount: 1, changedFiles: ["SKILL.md"],
                changelog: nil, fetchedAt: now
            ),
        ])
        registry.setFindings([
            SecurityFinding(
                id: "f1", origin: .uncoil, severity: .high, rule: "r", message: "m",
                extensionID: "acme/writer", foundAt: now
            ),
        ], forExtension: "acme/writer")

        registry.discover(adapters: adapters(home: home), launcherPath: launcherPath, now: now)
        let overview = registry.overview
        XCTAssertEqual(overview.agents, ["Claude Code"])
        XCTAssertEqual(overview.managedSkills, 1)
        XCTAssertEqual(overview.unmanagedSkills, 1)
        XCTAssertEqual(overview.mcpServers, 1)
        XCTAssertEqual(overview.pendingUpdates, 1)
        XCTAssertEqual(overview.openFindings, 1)
    }

    func testOverviewNeverImpliesABumblebeeScanHappened() {
        XCTAssertNil(registry.overview.lastBumblebeeScan)
        XCTAssertNil(
            registry.overview.bumblebeeSummary,
            "no scan means no summary — never a clean bill of health"
        )
        registry.setFindings([
            SecurityFinding(
                id: "b1", origin: .bumblebee, severity: .low, rule: "inventory",
                message: "m", extensionID: "a", foundAt: now
            ),
        ], forExtension: "a")
        XCTAssertEqual(registry.overview.lastBumblebeeScan, now)
        XCTAssertNotNil(registry.overview.bumblebeeSummary)
    }

    func testAcceptedFindingLeavesTheOpenList() {
        registry.setFindings([
            SecurityFinding(
                id: "f1", origin: .uncoil, severity: .blocked, rule: "r", message: "m",
                extensionID: "a", foundAt: now
            ),
        ], forExtension: "a")
        XCTAssertEqual(registry.openFindings.count, 1)
        XCTAssertTrue(registry.health.contains { $0.id == "health.security" })

        registry.acceptFinding(id: "f1")
        XCTAssertTrue(registry.openFindings.isEmpty)
        XCTAssertEqual(registry.auditEvents.first?.kind, .findingAccepted)
    }

    func testOpenFindingsAreSortedBySeverity()  {
        registry.setFindings([
            SecurityFinding(
                id: "low", origin: .uncoil, severity: .low, rule: "a", message: "m",
                extensionID: "a", foundAt: now
            ),
            SecurityFinding(
                id: "blocked", origin: .uncoil, severity: .blocked, rule: "b", message: "m",
                extensionID: "a", foundAt: now
            ),
        ], forExtension: "a")
        XCTAssertEqual(registry.openFindings.map(\.id), ["blocked", "low"])
    }

    func testSourcesIncludeRepositoriesPackagesActuallyTrack() {
        registry.addSource("manually/added")
        registry.upsert(ExtensionPackage(
            id: "a", kind: .skill, name: "a",
            source: .managedGitHub(repository: "from/package", subpath: nil, tracking: .tag("v1"))
        ))
        XCTAssertEqual(registry.effectiveSources, ["from/package", "manually/added"])
        registry.removeSource("manually/added")
        XCTAssertEqual(registry.effectiveSources, ["from/package"])
    }

    func testAssignmentsAreScopedPerAgentAndProject() {
        let projectID = UUID()
        registry.upsert(ExtensionPackage(id: "a", kind: .skill, name: "a", source: .local(path: "/x")))
        registry.setAgentBinding(true, packageID: "a", agent: .claudeCode)
        registry.setAgentBinding(true, packageID: "a", agent: .codex)
        registry.setProjectBinding(
            ProjectBinding(extensionID: "a", projectID: projectID, agent: .codex, isEnabled: false)
        )

        XCTAssertEqual(registry.agents(for: "a"), [.claudeCode, .codex])
        XCTAssertFalse(SkillAssignment.isActive(
            .init(extensionID: "a", agent: .codex, projectID: projectID),
            agentBindings: registry.agentBindings,
            projectBindings: registry.projectBindings
        ))
        XCTAssertTrue(SkillAssignment.isActive(
            .init(extensionID: "a", agent: .claudeCode, projectID: projectID),
            agentBindings: registry.agentBindings,
            projectBindings: registry.projectBindings
        ))
    }
}
