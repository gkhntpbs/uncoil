import XCTest
@testable import Uncoil

@MainActor
final class ExtensionStoreLayoutTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilStoreLayout-\(UUID().uuidString)", isDirectory: true)
    }

    func testEnsureCreatesEverySubdirectory() throws {
        let layout = ExtensionStoreLayout(root: root())
        try layout.ensure()
        for directory in layout.allDirectories {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.path),
                directory.lastPathComponent
            )
        }
        XCTAssertTrue(layout.activeSkills.path.hasSuffix("active/skills"))
    }

    func testTwoSkillsFromOneRepositoryShareOneMirror() {
        let layout = ExtensionStoreLayout(root: root())
        XCTAssertEqual(
            layout.mirror(forRepository: "anthropics/skills"),
            layout.mirror(forRepository: "anthropics/skills")
        )
        XCTAssertNotEqual(
            layout.mirror(forRepository: "anthropics/skills"),
            layout.mirror(forRepository: "other/skills")
        )
        XCTAssertFalse(
            layout.mirror(forRepository: "anthropics/skills").lastPathComponent.contains("/")
        )
    }

    func testDefaultLayoutLivesUnderDotUncoil() {
        XCTAssertTrue(
            ExtensionStoreLayout.default().root.path.hasSuffix(".uncoil/extensions")
        )
    }
}

@MainActor
final class SkillStoreTests: XCTestCase {
    private var storeRoot: URL!
    private var canonicalRoot: URL!
    private var sourceRoot: URL!
    private var store: SkillStore!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSkillStore-\(UUID().uuidString)", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        canonicalRoot = base.appendingPathComponent("agents/skills", isDirectory: true)
        sourceRoot = base.appendingPathComponent("source", isDirectory: true)
        store = SkillStore(
            layout: ExtensionStoreLayout(root: storeRoot),
            canonicalRoot: canonicalRoot
        )
    }

    private func makeSkill(_ name: String, body: String = "# skill\n") -> URL {
        let url = sourceRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data(body.utf8).write(to: url.appendingPathComponent("SKILL.md"))
        return url
    }

    private func agentDirectory(_ name: String) -> URL {
        let url = storeRoot.deletingLastPathComponent()
            .appendingPathComponent("\(name)/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    // MARK: - Central copy

    func testInstallCopiesIntoAnImmutableRevisionAndActivatesIt() throws {
        let revision = try store.install(
            from: makeSkill("writer"), name: "writer", revisionID: "rev-1", commitSHA: "abc1234"
        )
        XCTAssertEqual(revision.commitSHA, "abc1234")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent("revisions/rev-1/SKILL.md").path
        ))
        XCTAssertEqual(store.activeStatus(name: "writer", expectedRevisionID: "rev-1"), .linked)
    }

    func testActivePointerReportsItsOwnHealth() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        XCTAssertEqual(store.activeStatus(name: "writer"), .linked)
        XCTAssertEqual(store.activeStatus(name: "absent"), .missing)

        guard case .wrongTarget = store.activeStatus(name: "writer", expectedRevisionID: "rev-9") else {
            return XCTFail("a pointer at another revision should read as wrongTarget")
        }

        try FileManager.default.removeItem(
            at: storeRoot.appendingPathComponent("revisions/rev-1", isDirectory: true)
        )
        guard case .broken = store.activeStatus(name: "writer") else {
            return XCTFail("a pointer at a deleted revision should read as broken")
        }
    }

    func testInstallRefusesAFolderWithoutSkillMarkdown() {
        let notASkill = sourceRoot.appendingPathComponent("empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: notASkill, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try store.install(from: notASkill, name: "empty", revisionID: "rev-x")
        )
    }

    func testTheSameSkillLinkedIntoTwoAgentsHasOnePhysicalCopy() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        let codex = agentDirectory("codex")

        let claudeLink = try store.link(name: "writer", intoAgentDirectory: claude)
        let codexLink = try store.link(name: "writer", intoAgentDirectory: codex)

        XCTAssertEqual(store.status(name: "writer", inAgentDirectory: claude), .linked)
        XCTAssertEqual(store.status(name: "writer", inAgentDirectory: codex), .linked)
        XCTAssertTrue(isSymlink(URL(fileURLWithPath: claudeLink)))
        XCTAssertTrue(isSymlink(URL(fileURLWithPath: codexLink)))

        // One revision on disk, two links pointing at it.
        let revisions = try FileManager.default.contentsOfDirectory(
            atPath: storeRoot.appendingPathComponent("revisions").path
        )
        XCTAssertEqual(revisions, ["rev-1"])
    }

    func testLinksArePerSkillNotAWholeFolderSymlink() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        XCTAssertFalse(isSymlink(claude), "the skills directory itself stays a real directory")
        XCTAssertTrue(isSymlink(claude.appendingPathComponent("writer")))
    }

    func testUnlinkingFromOneAgentKeepsTheCentralCopyAndTheOtherAgent() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        let codex = agentDirectory("codex")
        try store.link(name: "writer", intoAgentDirectory: claude)
        try store.link(name: "writer", intoAgentDirectory: codex)

        try store.unlink(name: "writer", fromAgentDirectory: claude)

        XCTAssertEqual(store.status(name: "writer", inAgentDirectory: claude), .missing)
        XCTAssertEqual(store.status(name: "writer", inAgentDirectory: codex), .linked)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent("revisions/rev-1/SKILL.md").path
        ))
    }

    func testCanonicalLinkIsSharedByEveryAgent() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let path = try store.linkCanonical(name: "writer")
        XCTAssertTrue(path.hasSuffix("agents/skills/writer"))
        XCTAssertEqual(store.status(name: "writer", inAgentDirectory: canonicalRoot), .linked)
    }

    // MARK: - Maintenance

    func testDeletedLinkIsDetectedAndRepaired() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        try FileManager.default.removeItem(at: claude.appendingPathComponent("writer"))
        let status = store.status(name: "writer", inAgentDirectory: claude)
        XCTAssertEqual(status, .missing)
        XCTAssertTrue(status.needsRepair)

        XCTAssertEqual(try store.repair(name: "writer", inAgentDirectory: claude), .linked)
    }

    func testBrokenLinkIsDetectedAndRepaired() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        // Drop the active pointer: the agent link now dangles.
        try store.deactivate(name: "writer")
        guard case .broken = store.status(name: "writer", inAgentDirectory: claude) else {
            return XCTFail("a dangling link should read as broken")
        }

        try store.activate(revisionID: "rev-1", name: "writer")
        XCTAssertEqual(try store.repair(name: "writer", inAgentDirectory: claude), .linked)
    }

    func testLinkPointedElsewhereOutsideUncoilIsReported() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        let elsewhere = makeSkill("elsewhere")
        try FileManager.default.removeItem(at: claude.appendingPathComponent("writer"))
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("writer"), withDestinationURL: elsewhere
        )

        guard case .wrongTarget(let target) = store.status(name: "writer", inAgentDirectory: claude) else {
            return XCTFail("a relinked skill should read as wrongTarget")
        }
        XCTAssertTrue(target.hasSuffix("elsewhere"))
        XCTAssertEqual(try store.repair(name: "writer", inAgentDirectory: claude), .linked)
    }

    func testAUsersOwnSkillIsNeverOverwrittenOrRemoved() throws {
        let claude = agentDirectory("claude")
        let manual = claude.appendingPathComponent("hand-written", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: manual.appendingPathComponent("SKILL.md"))

        try store.install(from: makeSkill("hand-written"), name: "hand-written", revisionID: "rev-2")

        let status = store.status(name: "hand-written", inAgentDirectory: claude)
        XCTAssertEqual(status, .foreign)
        XCTAssertFalse(status.isRepairable)
        XCTAssertThrowsError(try store.link(name: "hand-written", intoAgentDirectory: claude))
        XCTAssertThrowsError(try store.unlink(name: "hand-written", fromAgentDirectory: claude))

        let contents = try String(
            contentsOf: manual.appendingPathComponent("SKILL.md"), encoding: .utf8
        )
        XCTAssertEqual(contents, "# mine\n", "the user's file is untouched")
    }

    func testManualSkillsAreListedAsUnmanaged() throws {
        let claude = agentDirectory("claude")
        let manual = claude.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: manual.appendingPathComponent("SKILL.md"))

        try store.install(from: makeSkill("managed"), name: "managed", revisionID: "rev-3")
        try store.link(name: "managed", intoAgentDirectory: claude)

        XCTAssertEqual(store.unmanagedSkills(in: claude), ["mine"])
    }

    /// The way most people already keep skills: one folder of them, symlinked
    /// into each agent's directory. Every one of those links used to be skipped
    /// as "probably ours", so a machine full of skills reported nothing to
    /// adopt and onboarding told the user there was nothing there.
    func testSkillsSymlinkedFromTheUsersOwnFolderAreUnmanaged() throws {
        let claude = agentDirectory("claude")
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("linked"),
            withDestinationURL: makeSkill("linked")
        )

        try store.install(from: makeSkill("managed"), name: "managed", revisionID: "rev-4")
        try store.link(name: "managed", intoAgentDirectory: claude)

        XCTAssertEqual(store.unmanagedSkills(in: claude), ["linked"])
    }

    func testOnlyLinksIntoTheStoreCountAsOurs() throws {
        let claude = agentDirectory("claude")
        try store.install(from: makeSkill("managed"), name: "managed", revisionID: "rev-5")
        try store.link(name: "managed", intoAgentDirectory: claude)
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("theirs"),
            withDestinationURL: makeSkill("theirs")
        )

        XCTAssertTrue(store.isOurLink(claude.appendingPathComponent("managed")))
        XCTAssertFalse(store.isOurLink(claude.appendingPathComponent("theirs")))
    }

    /// Adopting through a symlink has to copy what it points at. `copyItem`
    /// copies the link itself, which left the store holding a pointer into the
    /// user's folder while claiming to own the bytes — deleting their folder
    /// would then take the "managed" skill with it.
    func testAdoptingASymlinkedSkillCopiesTheContents() throws {
        let real = makeSkill("origin", body: "# origin\n")
        let link = sourceRoot.appendingPathComponent("linked-origin", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let revision = try store.install(from: link, name: "origin", revisionID: "rev-6")

        let attributes = try FileManager.default.attributesOfItem(atPath: revision.path)
        XCTAssertNotEqual(
            attributes[.type] as? FileAttributeType, .typeSymbolicLink,
            "the store kept a link instead of a copy"
        )
        try FileManager.default.removeItem(at: real)
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: revision.path)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# origin\n",
            "the copy did not survive the source being removed"
        )
    }

    func testUninstallCleansOnlyItsOwnDeadLinks() throws {
        try store.install(from: makeSkill("writer"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        // A link the user made to somewhere else entirely.
        let outside = makeSkill("outside")
        try FileManager.default.createSymbolicLink(
            at: claude.appendingPathComponent("outside"), withDestinationURL: outside
        )
        // And a user folder.
        let manual = claude.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)

        try store.deactivate(name: "writer")
        XCTAssertEqual(store.orphanedLinks(in: claude), ["writer"])
        XCTAssertEqual(store.removeOrphanedLinks(in: claude), ["writer"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertTrue(isSymlink(claude.appendingPathComponent("outside")))
    }

    func testDeactivateRefusesToTouchARealDirectory() throws {
        try store.layout.ensure()
        let real = store.layout.activeSkill("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.deactivate(name: "real"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    func testLocalModificationIsDetectedFromTheContentHash() throws {
        let revision = try store.install(
            from: makeSkill("writer"), name: "writer", revisionID: "rev-1"
        )
        XCTAssertFalse(store.hasLocalModification(revision))

        try Data("# edited\n".utf8).write(
            to: URL(fileURLWithPath: revision.path).appendingPathComponent("SKILL.md")
        )
        XCTAssertTrue(store.hasLocalModification(revision))
    }

    func testContentHashCoversAddedFilesNotJustEditedOnes() throws {
        let source = makeSkill("writer")
        let before = SkillStore.contentHash(of: source)
        try Data("echo hi\n".utf8).write(to: source.appendingPathComponent("run.sh"))
        XCTAssertNotEqual(SkillStore.contentHash(of: source), before)
    }

    func testActivatingANewRevisionSwapsThePointerForEveryAgentAtOnce() throws {
        try store.install(from: makeSkill("writer", body: "# v1\n"), name: "writer", revisionID: "rev-1")
        let claude = agentDirectory("claude")
        try store.link(name: "writer", intoAgentDirectory: claude)

        let v2 = makeSkill("writer-v2", body: "# v2\n")
        try store.install(from: v2, name: "writer", revisionID: "rev-2")

        let seen = try String(
            contentsOf: claude.appendingPathComponent("writer/SKILL.md"), encoding: .utf8
        )
        XCTAssertEqual(seen, "# v2\n", "the agent's link follows the active pointer")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent("revisions/rev-1/SKILL.md").path
        ), "the previous revision is kept for rollback")
    }
}

final class SkillAssignmentTests: XCTestCase {
    private let extensionID = "skills/writer"
    private let projectA = UUID()
    private let projectB = UUID()

    private func scope(_ agent: ExtensionAgentID, _ project: UUID? = nil) -> SkillAssignment.Scope {
        SkillAssignment.Scope(extensionID: extensionID, agent: agent, projectID: project)
    }

    func testNoAgentBindingMeansNotAssigned() {
        XCTAssertFalse(
            SkillAssignment.isActive(scope(.claudeCode), agentBindings: [], projectBindings: [])
        )
    }

    func testAgentBindingAloneIsGlobal() {
        let bindings = [AgentBinding(extensionID: extensionID, agent: .claudeCode)]
        XCTAssertTrue(
            SkillAssignment.isActive(scope(.claudeCode), agentBindings: bindings, projectBindings: [])
        )
        XCTAssertTrue(
            SkillAssignment.isActive(scope(.claudeCode, projectA), agentBindings: bindings, projectBindings: [])
        )
        XCTAssertFalse(
            SkillAssignment.isActive(scope(.codex), agentBindings: bindings, projectBindings: []),
            "another agent is unaffected"
        )
    }

    func testDisabledAgentBindingTurnsItOff() {
        let bindings = [AgentBinding(extensionID: extensionID, agent: .codex, isEnabled: false)]
        XCTAssertFalse(
            SkillAssignment.isActive(scope(.codex), agentBindings: bindings, projectBindings: bindings.isEmpty ? [] : [])
        )
    }

    func testProjectScopedBindingLimitsItToThatProject() {
        let agentBindings = [AgentBinding(extensionID: extensionID, agent: .claudeCode)]
        let projectBindings = [ProjectBinding(extensionID: extensionID, projectID: projectA)]
        XCTAssertTrue(SkillAssignment.isActive(
            scope(.claudeCode, projectA),
            agentBindings: agentBindings, projectBindings: projectBindings
        ))
        XCTAssertFalse(SkillAssignment.isActive(
            scope(.claudeCode, projectB),
            agentBindings: agentBindings, projectBindings: projectBindings
        ))
    }

    func testProjectScopedBindingBeatsTheGlobalOne() {
        let agentBindings = [AgentBinding(extensionID: extensionID, agent: .claudeCode)]
        let projectBindings = [
            ProjectBinding(extensionID: extensionID, projectID: nil, isEnabled: true),
            ProjectBinding(extensionID: extensionID, projectID: projectA, isEnabled: false),
        ]
        XCTAssertFalse(SkillAssignment.isActive(
            scope(.claudeCode, projectA),
            agentBindings: agentBindings, projectBindings: projectBindings
        ))
        XCTAssertTrue(SkillAssignment.isActive(
            scope(.claudeCode, projectB),
            agentBindings: agentBindings, projectBindings: projectBindings
        ))
    }

    func testAgentPlusProjectCombinationIsHonored() {
        let agentBindings = [
            AgentBinding(extensionID: extensionID, agent: .claudeCode),
            AgentBinding(extensionID: extensionID, agent: .codex),
        ]
        let projectBindings = [
            ProjectBinding(extensionID: extensionID, projectID: projectA, agent: .codex, isEnabled: false),
        ]
        XCTAssertFalse(SkillAssignment.isActive(
            scope(.codex, projectA),
            agentBindings: agentBindings, projectBindings: projectBindings
        ))
        XCTAssertTrue(
            SkillAssignment.isActive(
                scope(.claudeCode, projectA),
                agentBindings: agentBindings, projectBindings: projectBindings
            ),
            "a binding naming codex says nothing about claude"
        )
    }

    func testOneSkillCanBeAssignedToSeveralAgents() {
        var bindings: [AgentBinding] = []
        bindings = SkillAssignment.setting(true, extensionID: extensionID, agent: .claudeCode, in: bindings)
        bindings = SkillAssignment.setting(true, extensionID: extensionID, agent: .codex, in: bindings)
        XCTAssertEqual(
            SkillAssignment.activeAgents(extensionID: extensionID, agentBindings: bindings),
            [.claudeCode, .codex]
        )
    }

    func testDisablingForOneAgentLeavesTheOther() {
        var bindings = [
            AgentBinding(extensionID: extensionID, agent: .claudeCode),
            AgentBinding(extensionID: extensionID, agent: .codex),
        ]
        bindings = SkillAssignment.setting(false, extensionID: extensionID, agent: .codex, in: bindings)
        XCTAssertEqual(
            SkillAssignment.activeAgents(extensionID: extensionID, agentBindings: bindings),
            [.claudeCode]
        )
    }

    func testRemovingFromAnAgentDropsOnlyThatBinding() {
        let bindings = SkillAssignment.removing(
            extensionID: extensionID,
            agent: .codex,
            from: [
                AgentBinding(extensionID: extensionID, agent: .claudeCode),
                AgentBinding(extensionID: extensionID, agent: .codex),
                AgentBinding(extensionID: "other", agent: .codex),
            ]
        )
        XCTAssertEqual(bindings.count, 2)
        XCTAssertNil(bindings.first { $0.extensionID == extensionID && $0.agent == .codex })
        XCTAssertNotNil(bindings.first { $0.extensionID == "other" })
    }

    func testContradictoryProjectBindingsAreReported() {
        let bindings = [
            ProjectBinding(extensionID: extensionID, projectID: projectA, isEnabled: true),
            ProjectBinding(extensionID: extensionID, projectID: projectA, isEnabled: false),
            ProjectBinding(extensionID: extensionID, projectID: projectB, isEnabled: true),
        ]
        let conflicts = SkillAssignment.conflicts(bindings)
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertTrue(conflicts.allSatisfy { $0.projectID == projectA })
    }

    func testConsistentBindingsHaveNoConflicts() {
        XCTAssertTrue(SkillAssignment.conflicts([
            ProjectBinding(extensionID: extensionID, projectID: projectA, isEnabled: true),
            ProjectBinding(extensionID: extensionID, projectID: projectB, isEnabled: false),
        ]).isEmpty)
    }
}
