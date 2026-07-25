import XCTest
@testable import Uncoil

@MainActor
final class SkillAuthoringTests: XCTestCase {
    private var root: URL!
    private var canonical: URL!
    private var layout: ExtensionStoreLayout!
    private var service: SkillAuthoringService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilAuthoring-\(UUID().uuidString)", isDirectory: true)
        canonical = root.appendingPathComponent("agents/skills", isDirectory: true)
        layout = ExtensionStoreLayout(root: root.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        service = SkillAuthoringService(
            layout: layout, store: SkillStore(layout: layout, canonicalRoot: canonical)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSlugTurnsATitleIntoAFolderName() {
        XCTAssertEqual(SkillAuthoringService.slug("Release Checklist"), "release-checklist")
        XCTAssertEqual(SkillAuthoringService.slug("  PR  review!! "), "pr-review")
        XCTAssertEqual(SkillAuthoringService.slug("!!!"), "")
    }

    func testCreatedSkillCarriesItsDescriptionInTheFrontMatter() throws {
        let package = try service.create(SkillAuthoringService.Draft(
            name: "Release Checklist",
            summary: "Sürüm çıkarmadan önce çalıştır.",
            body: "1. Testleri çalıştır."
        ))
        XCTAssertEqual(package.name, "release-checklist")
        XCTAssertEqual(package.kind, .skill)
        let path = try XCTUnwrap(package.activeRevision?.path)
        let markdown = try String(
            contentsOf: URL(fileURLWithPath: path).appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("name: release-checklist"))
        XCTAssertTrue(markdown.contains("description: Sürüm çıkarmadan önce çalıştır."))
        XCTAssertTrue(markdown.contains("1. Testleri çalıştır."))
        // Reachable through the shared location every agent can read.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: canonical.appendingPathComponent("release-checklist").path
            )
        )
    }

    func testAnEmptyOrUnusableNameIsRefused() {
        XCTAssertThrowsError(try service.create(SkillAuthoringService.Draft(name: "  "))) {
            XCTAssertEqual($0 as? SkillAuthoringError, .emptyName)
        }
        XCTAssertThrowsError(try service.create(SkillAuthoringService.Draft(name: "!!!"))) {
            XCTAssertEqual($0 as? SkillAuthoringError, .invalidName("!!!"))
        }
    }

    func testTheSameNameTwiceIsRefusedRatherThanOverwritten() throws {
        _ = try service.create(SkillAuthoringService.Draft(name: "notes", summary: "x"))
        XCTAssertThrowsError(
            try service.create(SkillAuthoringService.Draft(name: "Notes", summary: "y"))
        ) {
            XCTAssertEqual($0 as? SkillAuthoringError, .alreadyExists("notes"))
        }
    }

    func testImportingAFolderCopiesItAndLeavesTheOriginalAlone() throws {
        let source = root.appendingPathComponent("outside/my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: my-skill\n---\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))

        let package = try service.importFolder(at: source)
        XCTAssertEqual(package.name, "my-skill")
        if case .local = package.source {} else { XCTFail("beklenen kaynak .local") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
        XCTAssertNotEqual(package.activeRevision?.path, source.path)
    }

    func testAFolderWithoutSkillMarkdownIsRefused() throws {
        let source = root.appendingPathComponent("outside/not-a-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.importFolder(at: source)) {
            XCTAssertEqual($0 as? SkillAuthoringError, .notASkillFolder(source.path))
        }
    }
}

@MainActor
final class ExtensionAdoptionTakeoverTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var service: ExtensionAdoptionService!
    private var agentSkills: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTakeover-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        service = ExtensionAdoptionService(
            layout: layout,
            store: SkillStore(
                layout: layout,
                canonicalRoot: base.appendingPathComponent("agents/skills", isDirectory: true)
            )
        )
        agentSkills = base.appendingPathComponent("claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSkills, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func installation() -> AgentInstallation {
        AgentInstallation(
            agent: .claudeCode,
            binaryPath: "/usr/local/bin/claude",
            configDirectory: base.appendingPathComponent("claude").path,
            skillsDirectory: agentSkills.path,
            mcpConfigPath: nil,
            version: nil,
            isAuthenticated: nil,
            detectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// The user's own skill folder, exactly where an agent keeps it.
    private func handWrittenSkill(_ name: String) throws -> URL {
        let url = agentSkills.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\n---\n# elle yazıldı\n".utf8)
            .write(to: url.appendingPathComponent("SKILL.md"))
        return url
    }

    func testThePlanListsTheAgentCopiesItWouldCollect() throws {
        let source = try handWrittenSkill("my-skill")
        let plan = try service.plan(
            name: "my-skill", kind: .skill, externalPath: source.path,
            installations: [installation()]
        )
        XCTAssertEqual(plan.agentCopies.map(\.agent), [.claudeCode])
        XCTAssertEqual(plan.agentCopies.first?.path, source.path)
    }

    func testAdoptingCollectsEveryAgentCopyIntoOneAndLeavesASymlink() throws {
        let source = try handWrittenSkill("my-skill")
        let plan = try service.plan(
            name: "my-skill", kind: .skill, externalPath: source.path,
            installations: [installation()]
        )
        let package = try service.adopt(plan)

        guard case .adopted = package.source else {
            return XCTFail("sahiplenilen paket .adopted olmalı: \(package.source)")
        }
        XCTAssertTrue(package.source.isOwnedByUncoil)
        XCTAssertNotNil(package.activeRevision)

        // The agent now reads the single copy through a symlink…
        let destination = try FileManager.default
            .destinationOfSymbolicLink(atPath: source.path)
        XCTAssertTrue(destination.contains("active/skills/my-skill"), destination)
        // …which resolves to the files that were adopted.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("SKILL.md").path
        ))
        // …and the original folder is in the backup, not gone.
        let backup = URL(fileURLWithPath: try XCTUnwrap(plan.backupPath))
            .appendingPathComponent("agents/claudeCode/my-skill/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), backup.path)
    }

    /// The point of the whole step: after adopting, the skill is no longer one of
    /// the unmanaged folders discovery keeps reporting.
    func testAnAdoptedSkillStopsCountingAsUnmanaged() throws {
        let source = try handWrittenSkill("my-skill")
        let store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("agents/skills", isDirectory: true)
        )
        XCTAssertEqual(store.unmanagedSkills(in: agentSkills), ["my-skill"])

        let plan = try service.plan(
            name: "my-skill", kind: .skill, externalPath: source.path,
            installations: [installation()]
        )
        _ = try service.adopt(plan)
        XCTAssertTrue(store.unmanagedSkills(in: agentSkills).isEmpty)
    }
}

@MainActor
final class MCPAdoptionTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var service: ExtensionAdoptionService!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilMCPAdopt-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base)
        try layout.ensure()
        service = ExtensionAdoptionService(layout: layout)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func definition() -> MCPServerDefinition {
        MCPServerDefinition(
            id: "claudeCode:figma",
            name: "figma",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@figma/mcp"],
            environmentKeys: ["FIGMA_TOKEN"],
            environment: ["FIGMA_MODE": "readonly"]
        )
    }

    /// An MCP server has no files, so what is adopted is the definition — and it
    /// lands in the same store the skills do.
    func testAdoptingAnMCPServerWritesItsDefinitionIntoTheStore() throws {
        let plan = try service.planDefinition(definition(), agents: [.claudeCode])
        XCTAssertEqual(plan.kind, .mcpServer)
        XCTAssertTrue(plan.isAdoptable)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destinationPath),
            "planning writes nothing"
        )

        let package = try service.adopt(plan)
        guard case .adopted = package.source else {
            return XCTFail("beklenen kaynak .adopted: \(package.source)")
        }
        XCTAssertEqual(package.id, "adopted:figma")
        XCTAssertNotNil(package.activeRevision)
        let stored = try Data(contentsOf: URL(fileURLWithPath: plan.destinationPath)
            .appendingPathComponent("server.json"))
        let decoded = try JSONDecoder().decode(MCPServerDefinition.self, from: stored)
        XCTAssertEqual(decoded.command, "npx")
        XCTAssertEqual(decoded.arguments, ["-y", "@figma/mcp"])
        // Names travel, values never do.
        XCTAssertEqual(decoded.environmentKeys, ["FIGMA_TOKEN"])
        XCTAssertFalse(
            String(decoding: stored, as: UTF8.self).contains("secret"),
            "definition carries no secret values"
        )
    }

    func testABlockingFindingStopsAnMCPAdoptionToo() throws {
        let plan = try service.planDefinition(
            definition(),
            findings: [SecurityFinding(
                id: "f1", origin: .uncoil, severity: .blocked, rule: "risky-command.sudo",
                message: "sudo çağrısı var", foundAt: Date(timeIntervalSince1970: 0)
            )]
        )
        XCTAssertFalse(plan.isAdoptable)
        XCTAssertThrowsError(try service.adopt(plan))
    }
}

@MainActor
final class ExtensionRegistryLocalPackageTests: XCTestCase {
    func testACreatedSkillSurvivesTheNextDiscoveryPass() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilLocalSurvive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ExtensionStoreLayout(root: root)
        try layout.ensure()
        let registry = ExtensionRegistry(layout: layout)

        registry.upsert(ExtensionPackage(
            id: "created:notes", kind: .skill, name: "notes",
            source: .local(path: layout.revision("created-notes-1").path)
        ))
        // No adapters and no launcher: discovery finds nothing, and what Uncoil
        // created must still be there afterwards.
        registry.discover(adapters: AgentAdapterRegistry(adapters: []), launcherPath: "/nonexistent")
        XCTAssertEqual(registry.package(id: "created:notes")?.name, "notes")
    }

    func testInstalledAgentsIsEmptyWhenNothingWasDetected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilInstalledAgents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ExtensionStoreLayout(root: root)
        try layout.ensure()
        let registry = ExtensionRegistry(layout: layout)
        registry.discover(adapters: AgentAdapterRegistry(adapters: []), launcherPath: "/nonexistent")
        XCTAssertTrue(registry.installedAgents.isEmpty)
    }
}
