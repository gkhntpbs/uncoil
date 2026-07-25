import XCTest
@testable import Uncoil

// MARK: - Shared helpers

final class AgentAdapterSupportTests: XCTestCase {
    func testHashChangesWithContentAndIsStable() {
        XCTAssertEqual(
            AgentAdapterSupport.hash("a = 1"),
            AgentAdapterSupport.hash("a = 1")
        )
        XCTAssertNotEqual(
            AgentAdapterSupport.hash("a = 1"),
            AgentAdapterSupport.hash("a = 2")
        )
    }

    func testDiffIsEmptyWhenNothingChanges() {
        XCTAssertEqual(AgentAdapterSupport.diff(before: "x", after: "x", path: "/p"), "")
        let diff = AgentAdapterSupport.diff(before: "x", after: "y", path: "/p")
        XCTAssertTrue(diff.contains("-x"))
        XCTAssertTrue(diff.contains("+y"))
    }

    func testSecretEnvironmentKeysAreSeparatedFromPlainValues() {
        let split = AgentAdapterSupport.partitionEnvironment([
            "SUPABASE_ACCESS_TOKEN": "sbp_secret",
            "GITHUB_API_KEY": "ghp_secret",
            "FIREBASE_TOOLS_NO_UPDATE_CHECK": "1",
        ])
        XCTAssertEqual(split.secretKeys, ["GITHUB_API_KEY", "SUPABASE_ACCESS_TOKEN"])
        XCTAssertEqual(split.plain, ["FIREBASE_TOOLS_NO_UPDATE_CHECK": "1"])
        XCTAssertFalse(split.plain.values.contains("sbp_secret"))
    }
}

// MARK: - Codex TOML

final class CodexTOMLTests: XCTestCase {
    private let sample = """
    # user's own header
    model = "gpt-5.6-sol"

    [projects."/Users/me/app"]
    trust_level = "trusted"

    [mcp_servers.playwright]
    command = "npx"
    args = ["-y", "@playwright/mcp@latest"]

    [mcp_servers.supabase]
    command = "npx"
    args = ["-y", "@supabase/mcp-server-supabase@latest"]

    [mcp_servers.supabase.env]
    SUPABASE_ACCESS_TOKEN = "sbp_plaintext"

    [mcp_servers.notion]
    url = "https://mcp.notion.com/mcp"

    [mcp_servers.figma]
    url = "https://mcp.figma.com/mcp"
    enabled = false
    """

    func testReadsStdioAndHTTPServers() {
        let servers = CodexTOML.servers(in: sample)
        XCTAssertEqual(servers.map(\.name), ["playwright", "supabase", "notion", "figma"])

        let playwright = servers.first { $0.name == "playwright" }
        XCTAssertEqual(playwright?.transport, .stdio)
        XCTAssertEqual(playwright?.command, "npx")
        XCTAssertEqual(playwright?.arguments, ["-y", "@playwright/mcp@latest"])

        let notion = servers.first { $0.name == "notion" }
        XCTAssertEqual(notion?.transport, .http)
        XCTAssertEqual(notion?.url, "https://mcp.notion.com/mcp")

        XCTAssertEqual(servers.first { $0.name == "figma" }?.isEnabled, false)
    }

    func testSecretEnvironmentValueIsNeverCarriedIntoTheModel() {
        let supabase = CodexTOML.servers(in: sample).first { $0.name == "supabase" }
        XCTAssertEqual(supabase?.environmentKeys, ["SUPABASE_ACCESS_TOKEN"])
        XCTAssertTrue(supabase?.environment.isEmpty == true)
        XCTAssertFalse(CodexTOML.render(supabase!).contains("sbp_plaintext"))
    }

    func testRewritingOneServerLeavesEveryOtherLineUntouched() {
        let updated = CodexTOML.rewrite(
            sample,
            name: "playwright",
            with: CodexTOML.render(MCPServerDefinition(
                id: "codex:playwright",
                name: "playwright",
                transport: .stdio,
                command: "npx",
                arguments: ["-y", "@playwright/mcp@2.0.0"]
            ))
        )
        XCTAssertTrue(updated.contains("# user's own header"))
        XCTAssertTrue(updated.contains("model = \"gpt-5.6-sol\""))
        XCTAssertTrue(updated.contains("[projects.\"/Users/me/app\"]"))
        XCTAssertTrue(updated.contains("@playwright/mcp@2.0.0"))
        XCTAssertFalse(updated.contains("@playwright/mcp@latest"))
        // Neighbours survive.
        XCTAssertTrue(updated.contains("[mcp_servers.supabase]"))
        XCTAssertTrue(updated.contains("SUPABASE_ACCESS_TOKEN = \"sbp_plaintext\""))
    }

    func testRemovingAServerTakesItsEnvTableWithIt() {
        let updated = CodexTOML.rewrite(sample, name: "supabase", with: nil)
        XCTAssertFalse(updated.contains("[mcp_servers.supabase]"))
        XCTAssertFalse(updated.contains("SUPABASE_ACCESS_TOKEN"))
        XCTAssertTrue(updated.contains("[mcp_servers.playwright]"))
        XCTAssertTrue(updated.contains("[mcp_servers.notion]"))
    }

    func testAppendingAServerKeepsExistingContent() {
        let updated = CodexTOML.rewrite(
            sample,
            name: "uncoil",
            with: CodexTOML.render(MCPServerDefinition(
                id: "codex:uncoil", name: "uncoil", transport: .stdio,
                command: "/Applications/Uncoil.app/Contents/Helpers/uncoil-mcp"
            ))
        )
        XCTAssertTrue(updated.contains("[mcp_servers.uncoil]"))
        XCTAssertTrue(updated.contains("[mcp_servers.playwright]"))
        XCTAssertEqual(CodexTOML.servers(in: updated).count, 5)
    }

    func testCommentsAndQuotedHashesAreHandled() {
        XCTAssertEqual(CodexTOML.stripComment("a = 1 # trailing"), "a = 1")
        XCTAssertEqual(CodexTOML.stripComment("a = \"x # y\""), "a = \"x # y\"")
        XCTAssertEqual(CodexTOML.keyValue("a = \"x # y\"")?.value.stringValue, "x # y")
        XCTAssertNil(CodexTOML.keyValue("# just a comment"))
    }

    func testUnmodelledValuesAreKeptVerbatim() {
        XCTAssertEqual(
            CodexTOML.value("{ inline = true }"),
            .verbatim("{ inline = true }")
        )
        XCTAssertEqual(CodexTOML.value("120"), .integer(120))
        XCTAssertEqual(CodexTOML.value("true"), .boolean(true))
    }

    func testServerNameNeedingQuotesIsQuoted() {
        XCTAssertEqual(CodexTOML.quoteIfNeeded("node_repl"), "node_repl")
        XCTAssertEqual(CodexTOML.quoteIfNeeded("my server"), "\"my server\"")
    }

    func testStartupTimeoutRoundTrips() {
        let rendered = CodexTOML.render(MCPServerDefinition(
            id: "codex:x", name: "x", transport: .stdio,
            command: "node", startupTimeoutSeconds: 120
        ))
        XCTAssertEqual(
            CodexTOML.servers(in: rendered).first?.startupTimeoutSeconds,
            120
        )
    }
}

// MARK: - Claude Code adapter

@MainActor
final class ClaudeCodeAdapterTests: XCTestCase {
    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilClaudeAdapter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".claude/skills/demo", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? Data("# demo\n".utf8).write(
            to: url.appendingPathComponent(".claude/skills/demo/SKILL.md")
        )
        return url
    }

    private func adapter(_ home: URL) -> ClaudeCodeAdapter {
        var adapter = ClaudeCodeAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        return adapter
    }

    func testDetectsInstallationWithSkillAndMCPPaths() {
        let home = home()
        let installation = adapter(home).detectInstallations().first
        XCTAssertEqual(installation?.agent, .claudeCode)
        XCTAssertEqual(installation?.mcpConfigPath, home.appendingPathComponent(".claude.json").path)
        XCTAssertEqual(
            installation?.skillsDirectory,
            home.appendingPathComponent(".claude/skills").path
        )
    }

    func testReadsServersAndVisibleSkills() throws {
        let home = home()
        try Data(#"""
        {
          "numStartups": 12,
          "mcpServers": {
            "maestro": {"command": "maestro", "args": ["mcp"]},
            "notion": {"url": "https://mcp.notion.com/mcp"},
            "off": {"command": "x", "disabled": true}
          }
        }
        """#.utf8).write(to: home.appendingPathComponent(".claude.json"))

        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let configuration = try adapter.readConfiguration(installation)

        XCTAssertEqual(configuration.mcpServers.map(\.name), ["maestro", "notion", "off"])
        XCTAssertEqual(configuration.mcpServers.first { $0.name == "notion" }?.transport, .http)
        XCTAssertEqual(configuration.mcpServers.first { $0.name == "off" }?.isEnabled, false)
        XCTAssertEqual(configuration.skillNames, ["demo"])
        XCTAssertTrue(configuration.exists)
    }

    func testMissingConfigReadsAsEmptyRatherThanFailing() throws {
        let adapter = adapter(home())
        let configuration = try adapter.readConfiguration(adapter.detectInstallations()[0])
        XCTAssertFalse(configuration.exists)
        XCTAssertTrue(configuration.mcpServers.isEmpty)
    }

    func testPlanIsPreviewOnlyAndApplyWritesIt() throws {
        let home = home()
        try Data(#"{"numStartups": 3}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let configuration = try adapter.readConfiguration(installation)

        let plan = try adapter.plan([
            .addMCPServer(MCPServerDefinition(
                id: "x", name: "uncoil", transport: .stdio,
                command: "/Helpers/uncoil-mcp", arguments: []
            )),
        ], for: configuration)

        XCTAssertEqual(plan.status, .planned)
        XCTAssertTrue(plan.diff.contains("uncoil"))
        // Nothing written yet.
        let onDisk = try String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("uncoil"))

        let applied = try adapter.apply(plan)
        XCTAssertEqual(applied.status, .applied)
        XCTAssertNotNil(applied.backupPath)

        let reread = try adapter.readConfiguration(installation)
        XCTAssertEqual(reread.mcpServers.map(\.name), ["uncoil"])
        // The user's unrelated key survived.
        XCTAssertTrue(reread.raw.contains("numStartups"))
    }

    func testApplyRefusesWhenTheConfigChangedUnderneath() throws {
        let home = home()
        try Data(#"{"numStartups": 3}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let plan = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(id: "x", name: "uncoil", transport: .stdio, command: "/x"))],
            for: try adapter.readConfiguration(installation)
        )

        // Someone edits the file after the plan was made.
        try Data(#"{"numStartups": 4, "theme": "dark"}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))

        let applied = try adapter.apply(plan)
        XCTAssertEqual(applied.status, .staleConfig)
        let onDisk = try String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("theme"), "the user's edit is not overwritten")
        XCTAssertFalse(onDisk.contains("uncoil"))
    }

    func testRollbackRestoresTheBackup() throws {
        let home = home()
        try Data(#"{"numStartups": 3}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let plan = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(id: "x", name: "uncoil", transport: .stdio, command: "/x"))],
            for: try adapter.readConfiguration(installation)
        )
        let applied = try adapter.apply(plan)
        let rolledBack = try adapter.rollback(applied)
        XCTAssertEqual(rolledBack.status, .rolledBack)
        XCTAssertTrue(try adapter.readConfiguration(installation).mcpServers.isEmpty)
    }

    func testRemoveAndDisableChangesAreSupported() throws {
        let base = #"{"mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}}}"#
        let removed = try ClaudeCodeAdapter.applying([.removeMCPServer(name: "a")], to: base)
        XCTAssertEqual(try ClaudeCodeAdapter.parseServers(removed).map(\.name), ["b"])

        let disabled = try ClaudeCodeAdapter.applying(
            [.setMCPServerEnabled(name: "a", isEnabled: false)], to: base
        )
        XCTAssertEqual(
            try ClaudeCodeAdapter.parseServers(disabled).first { $0.name == "a" }?.isEnabled,
            false
        )
    }

    func testMalformedConfigIsReportedNotOverwritten() throws {
        let home = home()
        try Data("{ not json".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        XCTAssertThrowsError(try adapter.readConfiguration(installation))

        var configuration = AgentConfiguration(
            installation: installation, path: installation.mcpConfigPath!,
            raw: "{ not json", hash: AgentAdapterSupport.hash("{ not json"),
            mcpServers: [], skillNames: []
        )
        XCTAssertTrue(adapter.validate(configuration).contains { $0.severity == .error })
        configuration.raw = ""
        XCTAssertTrue(adapter.validate(configuration).isEmpty)
    }

    func testSecretsInConfigAreFlagged() throws {
        let installation = adapter(home()).detectInstallations()[0]
        let configuration = AgentConfiguration(
            installation: installation, path: "/tmp/x", raw: "{}", hash: "h",
            mcpServers: [
                MCPServerDefinition(
                    id: "x", name: "supabase", transport: .stdio, command: "npx",
                    environmentKeys: ["SUPABASE_ACCESS_TOKEN"]
                ),
            ],
            skillNames: []
        )
        let issues = adapter(home()).validate(configuration)
        XCTAssertTrue(issues.contains { $0.id.hasSuffix("secrets") })
    }
}

// MARK: - Codex adapter

@MainActor
final class CodexAdapterTests: XCTestCase {
    private func home(config: String? = nil) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilCodexAdapter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex/skills/writer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? Data("# writer\n".utf8).write(
            to: url.appendingPathComponent(".codex/skills/writer/SKILL.md")
        )
        if let config {
            try? Data(config.utf8).write(to: url.appendingPathComponent(".codex/config.toml"))
        }
        return url
    }

    private func adapter(_ home: URL) -> CodexAdapter {
        var adapter = CodexAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        return adapter
    }

    func testDetectsInstallationAndAuthenticationHint() {
        let home = home()
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, false)
        try? Data("{}".utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, true)
    }

    func testReadsTOMLServersAndSkills() throws {
        let home = home(config: """
        model = "gpt-5.6-sol"

        [mcp_servers.playwright]
        command = "npx"
        args = ["-y", "@playwright/mcp@latest"]
        """)
        let adapter = adapter(home)
        let configuration = try adapter.readConfiguration(adapter.detectInstallations()[0])
        XCTAssertEqual(configuration.mcpServers.map(\.name), ["playwright"])
        XCTAssertEqual(configuration.skillNames, ["writer"])
    }

    func testAddingAServerPreservesUnrelatedTOML() throws {
        let home = home(config: """
        # keep me
        model = "gpt-5.6-sol"

        [projects."/Users/me/app"]
        trust_level = "trusted"
        """)
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let plan = try adapter.plan([
            .addMCPServer(MCPServerDefinition(
                id: "codex:uncoil", name: "uncoil", transport: .stdio,
                command: "/Helpers/uncoil-mcp",
                environment: ["UNCOIL_SESSION_ID": "abc"]
            )),
        ], for: try adapter.readConfiguration(installation))

        let applied = try adapter.apply(plan)
        XCTAssertEqual(applied.status, .applied)

        let updated = try adapter.readConfiguration(installation)
        XCTAssertTrue(updated.raw.contains("# keep me"))
        XCTAssertTrue(updated.raw.contains("trust_level = \"trusted\""))
        XCTAssertEqual(updated.mcpServers.map(\.name), ["uncoil"])
        XCTAssertEqual(
            updated.mcpServers.first?.environment,
            ["UNCOIL_SESSION_ID": "abc"]
        )
    }

    func testStaleConfigStopsTheWrite() throws {
        let home = home(config: "model = \"a\"\n")
        let adapter = adapter(home)
        let installation = adapter.detectInstallations()[0]
        let plan = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(id: "x", name: "u", transport: .stdio, command: "/x"))],
            for: try adapter.readConfiguration(installation)
        )
        try Data("model = \"b\"\n".utf8)
            .write(to: home.appendingPathComponent(".codex/config.toml"))

        XCTAssertEqual(try adapter.apply(plan).status, .staleConfig)
        XCTAssertTrue(
            try adapter.readConfiguration(installation).raw.contains("model = \"b\"")
        )
    }

    func testDisablingAServerRewritesOnlyThatBlock() throws {
        let base = """
        [mcp_servers.a]
        command = "a"

        [mcp_servers.b]
        command = "b"
        """
        let updated = try CodexAdapter.applying(
            [.setMCPServerEnabled(name: "a", isEnabled: false)], to: base
        )
        let servers = CodexTOML.servers(in: updated)
        XCTAssertEqual(servers.first { $0.name == "a" }?.isEnabled, false)
        XCTAssertEqual(servers.first { $0.name == "b" }?.isEnabled, true)
    }

    func testUnknownServerCannotBeToggled() {
        XCTAssertThrowsError(
            try CodexAdapter.applying([.setMCPServerEnabled(name: "nope", isEnabled: false)], to: "")
        )
    }

    func testTOMLCoverageGapIsStatedExplicitly() throws {
        let home = home(config: """
        [mcp_servers.a]
        command = "a"
        """)
        let adapter = adapter(home)
        let issues = adapter.validate(
            try adapter.readConfiguration(adapter.detectInstallations()[0])
        )
        XCTAssertTrue(issues.contains { $0.id == "codex.mcp.coverage" })
    }

    func testReloadSaysARestartIsNeeded() {
        let adapter = adapter(home())
        guard case .restartRequired = adapter.reload(adapter.detectInstallations()[0]) else {
            return XCTFail("Codex picks up config at startup")
        }
    }
}

// MARK: - Registry

@MainActor
final class AgentAdapterRegistryTests: XCTestCase {
    func testShipsAdaptersForClaudeAndCodexOnly() {
        let registry = AgentAdapterRegistry()
        XCTAssertEqual(registry.adapters.map(\.agent), [.claudeCode, .codex])
        XCTAssertNotNil(registry.adapter(for: .claudeCode))
        XCTAssertNotNil(registry.adapter(for: .codex))
        XCTAssertNil(registry.adapter(for: .cursor))
        XCTAssertEqual(Set(registry.unmanagedAgents), [.geminiCLI, .cursor, .amp])
    }

    func testSupportedAgentsMatchTheAdaptersWeShip() {
        XCTAssertEqual(
            Set(ExtensionAgentID.supported),
            Set(AgentAdapterRegistry().adapters.map(\.agent))
        )
    }

    func testAgentsMapOntoTheProvidersUncoilLaunches() {
        XCTAssertEqual(ExtensionAgentID.claudeCode.provider, .claude)
        XCTAssertEqual(ExtensionAgentID.codex.provider, .codex)
        XCTAssertNil(ExtensionAgentID.amp.provider)
    }

    func testCapabilitiesDescribeWhatTheAdaptersActuallyDo() {
        let claude = ClaudeCodeAdapter().capabilities
        XCTAssertTrue(claude.supportsPerSkillSymlinks)
        XCTAssertTrue(claude.supportsProjectScopedMCP)
        XCTAssertFalse(claude.reloadsConfigWithoutRestart)

        let codex = CodexAdapter().capabilities
        XCTAssertTrue(codex.reportsAuthenticationState)
        XCTAssertFalse(codex.supportsProjectScopedMCP)
    }
}

// MARK: - Model invariants

final class ExtensionModelTests: XCTestCase {
    func testOnlyGitSourcesAreUpdatable() {
        let managed = ExtensionPackage(
            id: "a", kind: .skill, name: "a",
            source: .managedGitHub(repository: "o/r", subpath: nil, tracking: .branch("main"))
        )
        XCTAssertTrue(managed.supportsUpdateCheck)

        for source in [
            ExtensionSource.local(path: "/tmp/x"),
            .detectedExternal(path: "/tmp/y"),
            .bundled(identifier: "b"),
            .remoteMCP(url: "https://x", transport: .http),
        ] {
            let package = ExtensionPackage(id: "b", kind: .skill, name: "b", source: source)
            XCTAssertFalse(package.supportsUpdateCheck, source.label)
        }
    }

    func testUnmanagedSourcesSaySoInTheirLabel() {
        XCTAssertTrue(ExtensionSource.local(path: "/x").label.contains("Unmanaged"))
        XCTAssertTrue(ExtensionSource.detectedExternal(path: "/x").label.contains("Unmanaged"))
        XCTAssertFalse(
            ExtensionSource
                .managedGitHub(repository: "o/r", subpath: nil, tracking: .tag("v1"))
                .label.contains("Unmanaged")
        )
    }

    func testUncoilOnlyOwnsFilesItInstalled() {
        XCTAssertTrue(ExtensionSource.bundled(identifier: "b").isOwnedByUncoil)
        XCTAssertTrue(
            ExtensionSource
                .managedGitHub(repository: "o/r", subpath: nil, tracking: .branch("main"))
                .isOwnedByUncoil
        )
        XCTAssertFalse(ExtensionSource.local(path: "/x").isOwnedByUncoil)
        XCTAssertFalse(ExtensionSource.detectedExternal(path: "/x").isOwnedByUncoil)
    }

    func testSeverityOrdersFromInfoToBlocked() {
        XCTAssertEqual(
            SecurityFinding.Severity.allCases.sorted(),
            [.info, .low, .needsReview, .high, .blocked]
        )
        XCTAssertTrue(SecurityFinding.Severity.high > .needsReview)
    }

    func testFindingsKeepTheirOriginSeparate() {
        let uncoil = SecurityFinding(
            id: "1", origin: .uncoil, severity: .high, rule: "risky-command.sudo",
            message: "sudo", foundAt: Date(timeIntervalSince1970: 0)
        )
        let bumblebee = SecurityFinding(
            id: "2", origin: .bumblebee, severity: .high, rule: "known-malicious",
            message: "pkg", foundAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotEqual(uncoil.origin, bumblebee.origin)
        XCTAssertEqual(uncoil.origin.label, "Uncoil")
        XCTAssertEqual(bumblebee.origin.label, "Bumblebee")
    }

    func testGlobalProjectBindingIsDistinctFromAScopedOne() {
        let global = ProjectBinding(extensionID: "a")
        let scoped = ProjectBinding(extensionID: "a", projectID: UUID())
        XCTAssertTrue(global.isGlobal)
        XCTAssertFalse(scoped.isGlobal)
        XCTAssertNotEqual(global.id, scoped.id)
    }

    func testBindingIDsAreStablePerAgent() {
        XCTAssertEqual(
            AgentBinding(extensionID: "a", agent: .codex).id,
            AgentBinding(extensionID: "a", agent: .codex, isEnabled: false).id
        )
        XCTAssertNotEqual(
            AgentBinding(extensionID: "a", agent: .codex).id,
            AgentBinding(extensionID: "a", agent: .claudeCode).id
        )
    }

    func testRevisionRecordsSomethingWeCanReturnTo() {
        let revision = InstalledRevision(
            id: "abc1234", commitSHA: "abc1234", contentHash: "h",
            path: "/revisions/abc1234", installedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotEqual(revision.id, "latest")
        XCTAssertEqual(revision.commitSHA, "abc1234")
    }

    func testTransactionStartsPlannedAndEmptyDiffIsNoop() {
        let transaction = ConfigurationTransaction(
            agent: .codex, configPath: "/x", baseHash: "h", diff: ""
        )
        XCTAssertEqual(transaction.status, .planned)
        XCTAssertTrue(transaction.isEmpty)
    }

    func testOnlyEventsWithATokenCanBeUndone() {
        XCTAssertFalse(AuditEvent(kind: .scanCompleted, detail: "ok").isUndoable)
        XCTAssertTrue(
            AuditEvent(kind: .updateApplied, detail: "ok", undoToken: "rev-1").isUndoable
        )
    }

    func testMCPDefinitionShowsEndpointForRemoteServers() {
        let remote = MCPServerDefinition(
            id: "r", name: "notion", transport: .http, url: "https://mcp.notion.com/mcp"
        )
        XCTAssertEqual(remote.displayTarget, "https://mcp.notion.com/mcp")

        let local = MCPServerDefinition(
            id: "l", name: "pw", transport: .stdio, command: "npx", arguments: ["-y", "x"]
        )
        XCTAssertEqual(local.displayTarget, "npx -y x")
    }

    func testHealthFailureIsBlockingButAWarningIsNot() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(
            HealthCheckResult(id: "1", name: "n", outcome: .failure, detail: "d", checkedAt: now)
                .isBlocking
        )
        XCTAssertFalse(
            HealthCheckResult(id: "2", name: "n", outcome: .warning, detail: "d", checkedAt: now)
                .isBlocking
        )
        XCTAssertFalse(
            HealthCheckResult(id: "3", name: "n", outcome: .notApplicable, detail: "d", checkedAt: now)
                .isBlocking
        )
    }
}
