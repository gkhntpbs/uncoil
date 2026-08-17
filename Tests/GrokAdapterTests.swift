import XCTest
@testable import Uncoil

/// Grok CLI's config is TOML with the same `[mcp_servers.*]` tables Codex uses
/// — verified by running `grok mcp add` against a throwaway `GROK_HOME` — so
/// these tests pin that equivalence rather than re-testing the TOML writer.
@MainActor
final class GrokAdapterTests: XCTestCase {
    /// Byte-for-byte the shape `grok mcp add` produced.
    private let sample = """
    [cli]
    installer = "internal"

    [models]
    default = "grok-4.6"

    [mcp_servers.uncoil]
    command = "/path/to/uncoil-mcp"
    args = []
    enabled = true

    [mcp_servers.uncoil.env]
    UNCOIL_SESSION_ID = "abc"
    """

    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilGrok-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private func adapter(_ home: URL) -> GrokAdapter {
        var adapter = GrokAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        return adapter
    }

    func testDetectionPointsAtGroksOwnConfigRoot() throws {
        let home = home()
        let installation = try XCTUnwrap(adapter(home).detectInstallations().first)
        XCTAssertEqual(installation.agent, .grok)
        XCTAssertEqual(
            installation.mcpConfigPath,
            home.appendingPathComponent(".grok/config.toml").path
        )
        // Grok extends itself through a plugin marketplace, not a skills
        // directory: claiming one would make Uncoil offer to link skills into
        // a folder the CLI never reads.
        XCTAssertNil(installation.skillsDirectory)
    }

    func testAuthFilePresenceIsTheLoginSignal() throws {
        let home = home()
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, false)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".grok/auth.json"))
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, true)
    }

    func testServersAreReadFromTheSameTablesCodexUses() throws {
        let home = home()
        try Data(sample.utf8).write(to: home.appendingPathComponent(".grok/config.toml"))
        let adapter = self.adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        let server = try XCTUnwrap(configuration.mcpServers.first)
        XCTAssertEqual(server.name, "uncoil")
        XCTAssertEqual(server.command, "/path/to/uncoil-mcp")
        XCTAssertTrue(server.isEnabled)
        XCTAssertEqual(server.environment["UNCOIL_SESSION_ID"], "abc")
    }

    func testWritingAServerLeavesTheUsersOwnTablesUntouched() throws {
        let home = home()
        try Data(sample.utf8).write(to: home.appendingPathComponent(".grok/config.toml"))
        let adapter = self.adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "grok:extra", name: "extra", transport: .stdio, command: "run-me"
            ))],
            for: configuration
        )
        XCTAssertEqual(try adapter.apply(transaction).status, .applied)

        let after = try adapter.readConfiguration(installation)
        XCTAssertEqual(after.mcpServers.map(\.name).sorted(), ["extra", "uncoil"])
        // The CLI's own settings are not Uncoil's to reformat.
        XCTAssertTrue(after.raw.contains("installer = \"internal\""))
        XCTAssertTrue(after.raw.contains("default = \"grok-4.6\""))
    }

    // MARK: - Provider wiring

    func testGrokLaunchesAndResumesButClaimsNoControlPlane() {
        XCTAssertEqual(ExtensionAgentID.grok.provider, .grok)
        XCTAssertTrue(AgentProvider.grok.isAgent)
        XCTAssertTrue(AgentProvider.grok.resumesConversation)
        XCTAssertFalse(AgentProvider.grok.reportsStatusThroughHooks)
        // No per-session way to register uncoil-mcp: a config entry would
        // carry one stale session id for every session, and every tool call
        // would arrive from a caller the app cannot find.
        XCTAssertFalse(AgentProvider.grok.wiresControlPlane)
        XCTAssertEqual(AgentIntegrationSupport.forAgent(.grok).ceiling, .observed)
    }

    func testResumeUsesGroksOwnFlag() {
        var record = SessionRecord(
            projectID: UUID(), provider: .grok, accountID: nil, title: "t"
        )
        record.providerSessionID = "ses-9"
        let command = TerminalRegistry.launchCommand(for: record, extraArguments: nil)
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("--resume 'ses-9'"), command!)
    }

    func testWorkingModesComeFromThePermissionModeFlagsOwnValues() {
        let modes = AgentWorkingMode.options(for: .grok)
        // Exactly the values `--permission-mode` lists, minus `default` which
        // is spelled `providerDefault` here.
        XCTAssertEqual(
            Set(modes),
            [.providerDefault, .plan, .acceptEdits, .auto, .dontAsk, .dangerouslySkipPermissions]
        )
        XCTAssertEqual(
            AgentWorkingMode.dangerouslySkipPermissions.launchArguments(for: .grok),
            ["--permission-mode", "bypassPermissions"]
        )
        XCTAssertEqual(
            AgentWorkingMode.plan.launchArguments(for: .grok),
            ["--permission-mode", "plan"]
        )
        // A mode Grok does not document must add nothing at all.
        XCTAssertEqual(AgentWorkingMode.fullAccess.launchArguments(for: .grok), [])
    }

    func testGrokHomeIsTheIsolationVariable() {
        let profile = AccountProfile(provider: .grok, name: "work")
        XCTAssertEqual(profile.isolationEnvironmentKey, "GROK_HOME")
    }

    // MARK: - Cursor's binary

    func testCursorIsDetectedByItsAgentCLINotTheEditorCommand() {
        // `cursor` is the editor's file-opening command and is frequently
        // absent on a machine where the agent CLI is installed; looking for it
        // reported Cursor as missing while `cursor-agent` sat on the PATH.
        XCTAssertEqual(ExtensionAgentID.cursor.cliBinaryName, "cursor-agent")
        XCTAssertEqual(JSONMCPConfigLayout.cursor.binaryName, "cursor-agent")
        XCTAssertEqual(AgentProvider.cursor.launchCommand, "cursor-agent")
    }

    func testCursorLaunchesAndResumesButClaimsNoControlPlane() {
        XCTAssertEqual(ExtensionAgentID.cursor.provider, .cursor)
        XCTAssertTrue(AgentProvider.cursor.isAgent)
        XCTAssertTrue(AgentProvider.cursor.resumesConversation)
        XCTAssertFalse(AgentProvider.cursor.reportsStatusThroughHooks)
        // `CURSOR_CONFIG_DIR` moves the credentials along with the config, so
        // a per-session root would start every session logged out — there is
        // no per-session way to register uncoil-mcp.
        XCTAssertFalse(AgentProvider.cursor.wiresControlPlane)
        XCTAssertEqual(AgentIntegrationSupport.forAgent(.cursor).ceiling, .observed)
    }

    func testCursorWorkingModesComeFromItsOwnDocumentedFlags() {
        XCTAssertEqual(
            Set(AgentWorkingMode.options(for: .cursor)),
            [.providerDefault, .plan, .readOnly, .auto, .dangerouslySkipPermissions]
        )
        XCTAssertEqual(AgentWorkingMode.plan.launchArguments(for: .cursor), ["--mode", "plan"])
        XCTAssertEqual(AgentWorkingMode.readOnly.launchArguments(for: .cursor), ["--mode", "ask"])
        XCTAssertEqual(AgentWorkingMode.auto.launchArguments(for: .cursor), ["--auto-review"])
        XCTAssertEqual(
            AgentWorkingMode.dangerouslySkipPermissions.launchArguments(for: .cursor),
            ["--force"]
        )
        // A Codex-shaped mode Cursor does not document adds nothing.
        XCTAssertEqual(AgentWorkingMode.fullAccess.launchArguments(for: .cursor), [])
    }

    func testCursorResumeAndIsolationUseItsOwnNames() {
        var record = SessionRecord(
            projectID: UUID(), provider: .cursor, accountID: nil, title: "t"
        )
        record.providerSessionID = "chat-7"
        let command = TerminalRegistry.launchCommand(for: record, extraArguments: nil)
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("--resume 'chat-7'"), command!)
        XCTAssertEqual(
            AccountProfile(provider: .cursor, name: "work").isolationEnvironmentKey,
            "CURSOR_CONFIG_DIR"
        )
    }

    func testSelfUpdatingCLIsOfferTheirOwnUpdateCommand() {
        // These three land outside every package manager's tree; without the
        // native-installer branch they read as "unknown" and the update button
        // went away for tools that each document an `update` subcommand.
        XCTAssertEqual(
            CLIToolService.updatePlan(provider: .cursor, source: .nativeInstaller),
            .run("cursor-agent update")
        )
        XCTAssertEqual(
            CLIToolService.updatePlan(provider: .grok, source: .nativeInstaller),
            .run("grok update")
        )
    }
}
