import XCTest
@testable import Uncoil

final class ExtensionDiscoverySourceTests: XCTestCase {
    func testEverySourceTypeIsIdentifiableAndLabelled() {
        let sources: [ExtensionDiscoverySource] = [
            .localFolder(path: "/Users/x/skills/mine"),
            .gitHubRepository(repository: "acme/skills", subpath: "review", reference: "v1"),
            .gitHubRelease(repository: "acme/skills", tag: "v1.2.0", asset: "skills.zip"),
            .curatedRegistry(name: "Uncoil registry", url: "https://uncoil.test/registry.json"),
            .agentSkillsDirectory(agent: .claudeCode, path: "/Users/x/.claude/skills"),
            .bundled(identifier: "uncoil.review"),
        ]
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
        for source in sources {
            XCTAssertFalse(source.label.isEmpty, source.id)
        }
    }

    func testWhatEachSourceBecomesOnceInstalled() {
        XCTAssertEqual(
            ExtensionDiscoverySource.localFolder(path: "/p").installedSource,
            .local(path: "/p")
        )
        XCTAssertEqual(
            ExtensionDiscoverySource
                .agentSkillsDirectory(agent: .codex, path: "/p").installedSource,
            .local(path: "/p"),
            "an agent's own skill stays unmanaged until the user says otherwise"
        )
        XCTAssertEqual(
            ExtensionDiscoverySource
                .gitHubRelease(repository: "a/b", tag: "v1", asset: nil).installedSource,
            .managedGitHub(repository: "a/b", subpath: nil, tracking: .tag("v1"))
        )
        XCTAssertEqual(
            ExtensionDiscoverySource.bundled(identifier: "x").installedSource,
            .bundled(identifier: "x")
        )
        XCTAssertNil(
            ExtensionDiscoverySource
                .curatedRegistry(name: "r", url: "u").installedSource,
            "a registry is a catalogue, not an extension"
        )
    }

    func testARegistryEntryNamesItsOwnRepository() throws {
        let json = """
        [
          {
            "name": "review",
            "kind": "skill",
            "repository": "acme/skills",
            "subpath": "review",
            "license": "MIT"
          }
        ]
        """
        let entries = try JSONDecoder().decode(
            [CuratedRegistryEntry].self, from: Data(json.utf8)
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "acme/skills/review")
        XCTAssertEqual(
            entries[0].source,
            .gitHubRepository(repository: "acme/skills", subpath: "review", reference: nil)
        )
    }

    func testSourcesRoundTripThroughCoding() throws {
        let source = ExtensionDiscoverySource.gitHubRepository(
            repository: "acme/skills", subpath: nil, reference: "main"
        )
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionDiscoverySource.self, from: data), source)
    }
}

@MainActor
final class ExtensionInstallPreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, to name: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
    }

    func testTheOwnerComesFromTheRepositoryName() {
        XCTAssertEqual(ExtensionInstallPreviewBuilder.owner(of: "acme/skills"), "acme")
        XCTAssertNil(ExtensionInstallPreviewBuilder.owner(of: "skills"))
    }

    func testAnSPDXLicenceIsPreferredOverTheFileName() throws {
        try write("SPDX-License-Identifier: Apache-2.0\n", to: "LICENSE")
        XCTAssertEqual(ExtensionInstallPreviewBuilder.license(at: root), "Apache-2.0")
    }

    func testAWellKnownLicenceTextIsRecognised() throws {
        try write("MIT License\n\nCopyright (c) 2026\n", to: "LICENSE")
        XCTAssertEqual(ExtensionInstallPreviewBuilder.license(at: root), "MIT")
    }

    func testAGPLLicenceIsNamedAsSuchBecauseItMatters() throws {
        try write("GNU GENERAL PUBLIC LICENSE\nVersion 3\n", to: "COPYING")
        XCTAssertEqual(ExtensionInstallPreviewBuilder.license(at: root), "GPL")
    }

    func testNoLicenceFileMeansUnknownNotAssumedPermissive() {
        XCTAssertNil(ExtensionInstallPreviewBuilder.license(at: root))
    }

    func testScriptsAndBinariesAreListedSeparately() throws {
        try write("#!/bin/sh\necho hi\n", to: "bin/run.sh", executable: true)
        try write("data", to: "bin/helper", executable: true)
        try write("# doc\n", to: "README.md")
        let executables = ExtensionInstallPreviewBuilder.executables(at: root)
        XCTAssertTrue(executables.scripts.contains { $0.hasSuffix("run.sh") }, "\(executables)")
        XCTAssertTrue(executables.binaries.contains { $0.hasSuffix("helper") }, "\(executables)")
        XCTAssertFalse(
            (executables.scripts + executables.binaries).contains { $0.hasSuffix("README.md") }
        )
    }

    func testRequestedPermissionsAndAgentsAreReadFromFrontMatter() throws {
        try write(
            """
            ---
            name: review
            permissions: [read, run]
            agents:
              - claudeCode
              - codex
            ---

            # Review
            """,
            to: "SKILL.md"
        )
        let claims = ExtensionInstallPreviewBuilder.manifestClaims(at: root)
        XCTAssertEqual(claims.permissions, ["read", "run"])
        XCTAssertEqual(claims.agents, [.claudeCode, .codex])
    }

    func testAJSONManifestIsAlsoRead() throws {
        try write(
            #"{ "permissions": ["network"], "agents": ["cursor"] }"#, to: "uncoil.json"
        )
        let claims = ExtensionInstallPreviewBuilder.manifestClaims(at: root)
        XCTAssertEqual(claims.permissions, ["network"])
        XCTAssertEqual(claims.agents, [.cursor])
    }

    func testAnUnknownAgentNameIsDroppedRatherThanGuessed() throws {
        try write(
            """
            ---
            agents: [claudeCode, someFutureAgent]
            ---
            """,
            to: "SKILL.md"
        )
        XCTAssertEqual(
            ExtensionInstallPreviewBuilder.manifestClaims(at: root).agents, [.claudeCode]
        )
    }

    func testNoManifestMeansNoClaims() {
        let claims = ExtensionInstallPreviewBuilder.manifestClaims(at: root)
        XCTAssertTrue(claims.permissions.isEmpty)
        XCTAssertTrue(claims.agents.isEmpty)
    }

    func testThePreviewSeparatesChangedFilesAndBlockingFindings() {
        var preview = ExtensionInstallPreview(
            name: "review", kind: .skill,
            source: .gitHubRepository(repository: "acme/skills", subpath: nil, reference: "main")
        )
        preview.diff = [
            .init(path: "SKILL.md", kind: .modified),
            .init(path: "README.md", kind: .unchanged),
        ]
        preview.findings = [
            SecurityFinding(
                id: "1", origin: .uncoil, severity: .blocked, rule: "symlink-escape",
                message: "symlink dışarı çıkıyor", foundAt: Date(timeIntervalSince1970: 0)
            ),
            SecurityFinding(
                id: "2", origin: .bumblebee, severity: .low, rule: "note",
                message: "bilgi", foundAt: Date(timeIntervalSince1970: 0)
            ),
        ]
        XCTAssertEqual(preview.changedFiles.map(\.path), ["SKILL.md"])
        XCTAssertEqual(preview.blockingFindings.count, 1)
    }
}

final class ExtensionInstallGuardTests: XCTestCase {
    private func preview(
        resolvedCommit: String? = "a1b2c3d4e5f6",
        findings: [SecurityFinding] = [],
        scripts: [String] = []
    ) -> ExtensionInstallPreview {
        var preview = ExtensionInstallPreview(
            name: "review", kind: .skill,
            source: .gitHubRepository(repository: "acme/skills", subpath: nil, reference: "main")
        )
        preview.resolvedCommit = resolvedCommit
        preview.findings = findings
        preview.scripts = scripts
        return preview
    }

    private func blocked() -> SecurityFinding {
        SecurityFinding(
            id: "1", origin: .uncoil, severity: .blocked, rule: "risky-command.curl-bash",
            message: "curl | bash var", foundAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMovingReferencesAreNeverStoredAsVersions() {
        for reference in ["latest", "LATEST", "head", "main", "master", "stable", "*"] {
            XCTAssertTrue(ExtensionInstallGuard.isMoving(reference), reference)
            guard case .failure(let blocker) = ExtensionInstallGuard.recordedVersion(
                requested: reference, resolvedCommit: nil
            ) else {
                return XCTFail("\(reference) alone is not a version")
            }
            XCTAssertTrue(blocker.message.contains(reference), blocker.message)
        }
    }

    func testTheExactCommitIsWhatGetsRecorded() {
        guard case .success(let version) = ExtensionInstallGuard.recordedVersion(
            requested: "latest", resolvedCommit: "a1b2c3d4e5f6"
        ) else {
            return XCTFail("a resolved commit makes a moving reference installable")
        }
        XCTAssertEqual(version, "a1b2c3d4e5f6")

        guard case .success(let tag) = ExtensionInstallGuard.recordedVersion(
            requested: "v1.2.0", resolvedCommit: nil
        ) else {
            return XCTFail("a fixed tag is a version on its own")
        }
        XCTAssertEqual(tag, "v1.2.0")
    }

    func testAnUnresolvedReferenceBlocksTheInstall() {
        let blockers = ExtensionInstallGuard.blockers(
            preview: preview(resolvedCommit: nil),
            requestedReference: "latest",
            userApprovedExecutables: true
        )
        XCTAssertEqual(blockers, [.referenceNotResolved("latest")])
    }

    func testABlockedFindingStopsTheInstall() {
        let blockers = ExtensionInstallGuard.blockers(
            preview: preview(findings: [blocked()]),
            requestedReference: "v1",
            userApprovedExecutables: true
        )
        XCTAssertEqual(blockers, [.blockedFinding("curl | bash var")])
    }

    func testExecutablesNeedTheUsersWordFirst() {
        let blockers = ExtensionInstallGuard.blockers(
            preview: preview(scripts: ["bin/install.sh"]),
            requestedReference: "v1",
            userApprovedExecutables: false
        )
        XCTAssertEqual(blockers, [.executablesNotApproved(["bin/install.sh"])])
        XCTAssertTrue(
            ExtensionInstallGuard.blockers(
                preview: preview(scripts: ["bin/install.sh"]),
                requestedReference: "v1",
                userApprovedExecutables: true
            ).isEmpty
        )
    }

    func testAnInvalidPackageStructureBlocksToo() {
        let blockers = ExtensionInstallGuard.blockers(
            preview: preview(),
            requestedReference: "v1",
            userApprovedExecutables: true,
            structureIssues: ["SKILL.md yok"]
        )
        XCTAssertEqual(blockers, [.structureInvalid(["SKILL.md yok"])])
    }

    func testEveryBlockerExplainsItself() {
        let blockers: [ExtensionInstallGuard.Blocker] = [
            .referenceNotResolved("latest"),
            .blockedFinding("x"),
            .executablesNotApproved(["a", "b", "c", "d"]),
            .structureInvalid(["y"]),
        ]
        for blocker in blockers {
            XCTAssertFalse(blocker.message.isEmpty)
        }
    }

    func testAgentConfigsAreOnlyTouchedAfterASuccessfulInstall() {
        XCTAssertFalse(
            ExtensionInstallGuard.mayTouchAgentConfig(installSucceeded: false),
            "a failed install leaves every agent config exactly as it was"
        )
        XCTAssertTrue(ExtensionInstallGuard.mayTouchAgentConfig(installSucceeded: true))
    }

    func testACleanPreviewHasNothingInItsWay() {
        XCTAssertTrue(
            ExtensionInstallGuard.blockers(
                preview: preview(), requestedReference: "v1.2.0",
                userApprovedExecutables: false
            ).isEmpty,
            "no executables means no approval to ask for"
        )
    }
}

@MainActor
final class ExtensionInstallPreviewAssemblyTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilPreviewAssembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func tree(_ name: String, files: [String: String]) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    func testEverythingTheInstallScreenShowsIsAssembledInOnePlace() throws {
        let staged = try tree("staged", files: [
            "LICENSE": "SPDX-License-Identifier: MIT\n",
            "SKILL.md": """
            ---
            permissions: [read]
            agents: [claudeCode]
            ---

            # Review
            """,
            "bin/setup.sh": "#!/bin/sh\necho hi\n",
        ])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: staged.appendingPathComponent("bin/setup.sh").path
        )
        let installed = try tree("installed", files: ["SKILL.md": "# eski\n"])

        let preview = ExtensionInstallPreviewBuilder.preview(
            name: "review",
            kind: .skill,
            source: .gitHubRepository(
                repository: "acme/skills", subpath: "review", reference: "main"
            ),
            materializedPath: staged,
            installedPath: installed,
            tracking: "branch main",
            lastCommit: .init(
                sha: "a1b2c3d4e5f67890", subject: "review skill eklendi",
                date: Date(timeIntervalSince1970: 0)
            ),
            resolvedCommit: "a1b2c3d4e5f67890",
            findings: [],
            bumblebeeSummary: "Bumblebee: temiz"
        )

        XCTAssertEqual(preview.owner, "acme")
        XCTAssertEqual(preview.license, "MIT")
        XCTAssertEqual(preview.subpath, "review")
        XCTAssertEqual(preview.tracking, "branch main")
        XCTAssertEqual(preview.lastCommit?.shortSHA, "a1b2c3d4e5f6")
        XCTAssertEqual(preview.resolvedCommit, "a1b2c3d4e5f67890")
        XCTAssertEqual(preview.requestedPermissions, ["read"])
        XCTAssertEqual(preview.supportedAgents, [.claudeCode])
        XCTAssertTrue(preview.scripts.contains { $0.hasSuffix("setup.sh") }, "\(preview.scripts)")
        XCTAssertEqual(preview.bumblebeeSummary, "Bumblebee: temiz")
        XCTAssertEqual(
            preview.changedFiles.first { $0.path == "SKILL.md" }?.kind, .modified,
            "the diff is against what is installed now"
        )
        XCTAssertTrue(preview.changedFiles.contains { $0.path == "LICENSE" && $0.kind == .added })
    }

    func testAFirstInstallShowsEveryFileAsNew() throws {
        let staged = try tree("staged2", files: ["SKILL.md": "# yeni\n"])
        let preview = ExtensionInstallPreviewBuilder.preview(
            name: "review", kind: .skill,
            source: .localFolder(path: staged.path),
            materializedPath: staged,
            installedPath: nil,
            tracking: nil,
            lastCommit: nil,
            resolvedCommit: nil
        )
        XCTAssertEqual(preview.changedFiles.map(\.kind), [.added])
        XCTAssertNil(preview.owner, "a local folder has no repository owner")
        XCTAssertNil(preview.tracking, "and nothing to follow")
    }
}

@MainActor
final class UpdateReviewTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilUpdateReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func revision(_ name: String, manifest: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        return root
    }

    func testANewPermissionIsReportedAsAdded() throws {
        let previous = try revision("prev", manifest: """
        ---
        permissions: [read]
        ---
        """)
        let next = try revision("next", manifest: """
        ---
        permissions: [read, network]
        ---
        """)
        let review = UpdateReview.between(previous: previous, next: next, candidate: nil)
        XCTAssertEqual(review.addedPermissions, ["network"])
        XCTAssertTrue(review.removedPermissions.isEmpty)
        XCTAssertTrue(review.needsReview, "a new permission is worth a look")
    }

    func testARemovedToolIsALikelyBreakingChange() throws {
        let previous = try revision("prev2", manifest: "---\npermissions: []\n---")
        let next = try revision("next2", manifest: "---\npermissions: []\n---")
        let review = UpdateReview.between(
            previous: previous, next: next, candidate: nil,
            previousTools: ["search", "write"], nextTools: ["search"]
        )
        XCTAssertEqual(review.removedTools, ["write"])
        XCTAssertEqual(review.breakingChangeRisk, .likely)
        XCTAssertTrue(review.summary.contains("-1 tool"), review.summary)
    }

    func testANewToolAloneIsNotBreaking() throws {
        let previous = try revision("prev3", manifest: "---\npermissions: []\n---")
        let next = try revision("next3", manifest: "---\npermissions: []\n---")
        let review = UpdateReview.between(
            previous: previous, next: next, candidate: nil,
            previousTools: ["search"], nextTools: ["search", "index"]
        )
        XCTAssertEqual(review.addedTools, ["index"])
        XCTAssertEqual(
            review.breakingChangeRisk, .unlikely,
            "something new can be ignored; something gone cannot"
        )
    }

    func testAFirstInstallReportsItsOwnFindingsRatherThanADiff() throws {
        let next = try revision("next4", manifest: "---\npermissions: [read]\n---")
        try Data("#!/bin/sh\ncurl https://x | bash\n".utf8).write(
            to: next.appendingPathComponent("install.sh")
        )
        let review = UpdateReview.between(previous: nil, next: next, candidate: nil)
        XCTAssertEqual(review.addedPermissions, ["read"])
        XCTAssertFalse(
            review.securityDiff.isEmpty,
            "with nothing to compare against, the findings themselves are the answer"
        )
    }

    func testDependenciesAreReadFromTheManifest() throws {
        let root = base.appendingPathComponent("deps", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"dependencies": {"ripgrep": "*", "jq": "1.7"}}"#.utf8).write(
            to: root.appendingPathComponent("uncoil.json")
        )
        XCTAssertEqual(
            ExtensionInstallPreviewBuilder.dependencies(at: root), ["jq", "ripgrep"]
        )
    }

    func testDependenciesAlsoComeFromFrontMatter() throws {
        let root = base.appendingPathComponent("deps2", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("---\ndependencies:\n  - ripgrep\n  - fd\n---\n".utf8).write(
            to: root.appendingPathComponent("SKILL.md")
        )
        XCTAssertEqual(
            ExtensionInstallPreviewBuilder.dependencies(at: root), ["ripgrep", "fd"]
        )
    }

    func testNoManifestMeansNoDependencies() {
        XCTAssertTrue(ExtensionInstallPreviewBuilder.dependencies(at: base).isEmpty)
    }
}

@MainActor
final class ExtensionRegistryUndoTests: XCTestCase {
    private var base: URL!
    private var registry: ExtensionRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilUndo-\(UUID().uuidString)", isDirectory: true)
        let layout = ExtensionStoreLayout(
            root: base.appendingPathComponent("store", isDirectory: true)
        )
        try layout.ensure()
        registry = ExtensionRegistry(
            layout: layout,
            store: SkillStore(
                layout: layout,
                canonicalRoot: base.appendingPathComponent("agents", isDirectory: true)
            )
        )
        registry.upsert(ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
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

    func testOnlySomeEventsCanBeUndone() {
        for kind: AuditEvent.Kind in [.quarantined, .restored, .assignmentChanged, .findingAccepted] {
            XCTAssertTrue(
                ExtensionRegistry.isUndoable(
                    AuditEvent(kind: kind, extensionID: "x", detail: "d")
                ),
                kind.rawValue
            )
        }
        for kind: AuditEvent.Kind in [.skillInstalled, .configChanged, .scanCompleted] {
            XCTAssertFalse(
                ExtensionRegistry.isUndoable(
                    AuditEvent(kind: kind, extensionID: "x", detail: "d")
                ),
                kind.rawValue
            )
        }
    }

    func testUndoingAQuarantineRestoresThePackage() {
        registry.setState(.quarantined, packageID: "acme/skills:review")
        let event = AuditEvent(
            kind: .quarantined, extensionID: "acme/skills:review", detail: "karantina"
        )
        XCTAssertNotNil(registry.undo(event))
        XCTAssertEqual(registry.package(id: "acme/skills:review")?.state, .active)
    }

    func testUndoingAnAssignmentPutsItBack() {
        registry.setAgentBinding(true, packageID: "acme/skills:review", agent: .claudeCode)
        XCTAssertTrue(registry.agents(for: "acme/skills:review").contains(.claudeCode))

        let event = AuditEvent(
            kind: .assignmentChanged, extensionID: "acme/skills:review",
            detail: "claudeCode: açık"
        )
        XCTAssertNotNil(registry.undo(event))
        XCTAssertFalse(registry.agents(for: "acme/skills:review").contains(.claudeCode))
    }

    func testAnEventWithNothingToUndoSaysSo() {
        XCTAssertNil(
            registry.undo(AuditEvent(kind: .configChanged, extensionID: "x", detail: "d")),
            "a config change is undone from the Agents screen, not here"
        )
        XCTAssertNil(
            registry.undo(
                AuditEvent(kind: .assignmentChanged, extensionID: "x", detail: "isim yok")
            ),
            "an event whose detail names no agent cannot be reversed by guessing"
        )
    }

    func testTrackingCanBePinnedAndMoved() {
        XCTAssertTrue(
            registry.setTracking(.pinnedCommit("a1b2c3"), packageID: "acme/skills:review")
        )
        guard case .managedGitHub(_, _, let pinned) = try? XCTUnwrap(
            registry.package(id: "acme/skills:review")?.source
        ) else {
            return XCTFail("expected a managed source")
        }
        XCTAssertEqual(pinned, .pinnedCommit("a1b2c3"))
        XCTAssertFalse(
            registry.setTracking(.pinnedCommit("a1b2c3"), packageID: "acme/skills:review"),
            "setting the same tracking again changes nothing"
        )
        XCTAssertTrue(registry.setTracking(.tag("v2"), packageID: "acme/skills:review"))
        XCTAssertTrue(
            registry.auditEvents.contains { $0.detail.contains("tracking changed") },
            "\(registry.auditEvents.map(\.detail))"
        )
    }

    func testTrackingCannotBeSetOnAnUnmanagedSource() {
        registry.upsert(ExtensionPackage(
            id: "local:mine", kind: .skill, name: "mine",
            source: .local(path: "/tmp/mine"), state: .active
        ))
        XCTAssertFalse(registry.setTracking(.tag("v1"), packageID: "local:mine"))
    }
}
