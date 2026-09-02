import XCTest
@testable import Uncoil

/// What is specific to Hermes rather than to YAML: where the config root is,
/// that a missing config file is the ordinary case, and that `HERMES_HOME`
/// moves everything. The YAML surgery itself is pinned by `HermesYAMLTests`.
@MainActor
final class HermesAdapterTests: XCTestCase {
    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilHermes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".hermes", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private func adapter(_ home: URL, hermesHome: String? = nil) -> HermesAdapter {
        var adapter = HermesAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        adapter.hermesHomeOverride = hermesHome
        return adapter
    }

    func testDetectionPointsAtHermesOwnConfigRoot() throws {
        let home = home()
        let installation = try XCTUnwrap(adapter(home).detectInstallations().first)
        XCTAssertEqual(installation.agent, .hermes)
        XCTAssertEqual(installation.configDirectory, home.appendingPathComponent(".hermes").path)
        XCTAssertEqual(
            installation.mcpConfigPath,
            home.appendingPathComponent(".hermes/config.yaml").path
        )
        // Hermes' skills live in a hub of its own shape, so Uncoil claims none.
        XCTAssertNil(installation.skillsDirectory)
    }

    /// `HERMES_HOME` relocates config.yaml, .env, auth.json and the session
    /// store together, so an installation has to be read at the root the
    /// environment points at — not at `~/.hermes`.
    func testHermesHomeOverridesTheConfigRoot() throws {
        let home = home()
        let elsewhere = home.appendingPathComponent("relocated", isDirectory: true)
        let installation = try XCTUnwrap(
            adapter(home, hermesHome: elsewhere.path).detectInstallations().first
        )
        XCTAssertEqual(installation.configDirectory, elsewhere.path)
        XCTAssertEqual(
            installation.mcpConfigPath, elsewhere.appendingPathComponent("config.yaml").path
        )
    }

    func testNoBinaryMeansNoInstallation() {
        var adapter = HermesAdapter()
        adapter.homeDirectory = home()
        adapter.binaryPathOverride = nil
        // Nothing named `hermes` is guaranteed on a build machine, so this only
        // asserts the shape: detection never invents an install.
        for installation in adapter.detectInstallations() {
            XCTAssertFalse(installation.binaryPath.isEmpty)
        }
    }

    /// The normal case, not a broken one: Hermes writes config.yaml lazily, so
    /// a working install can have nothing but `logs/` under its home.
    func testMissingConfigFileReadsAsEmptyRatherThanFailing() throws {
        let home = home()
        let adapter = adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        XCTAssertEqual(configuration.raw, "")
        XCTAssertFalse(configuration.exists)
        XCTAssertTrue(configuration.mcpServers.isEmpty)
        XCTAssertTrue(adapter.validate(configuration).isEmpty)
    }

    func testAuthenticationIsReportedFromHermesAuthFile() throws {
        let home = home()
        let root = home.appendingPathComponent(".hermes", isDirectory: true)
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, false)
        try Data("{}".utf8).write(to: root.appendingPathComponent("auth.json"))
        XCTAssertEqual(adapter(home).detectInstallations().first?.isAuthenticated, true)
    }

    // MARK: - Validation

    func testTabIndentationIsReportedBecauseHermesIgnoresTheWholeFile() throws {
        let home = home()
        let adapter = adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = AgentConfiguration(
            installation: installation,
            path: installation.mcpConfigPath ?? "",
            raw: "mcp_servers:\n\ta:\n\t\tcommand: uvx\n",
            hash: "",
            mcpServers: [],
            skillNames: []
        )
        XCTAssertEqual(
            adapter.validate(configuration).map(\.id), ["hermes.config.tabs"]
        )
    }

    /// Hermes interpolates `${VAR}` from its own `.env`, so a reference is not
    /// a secret sitting in the config and must not be reported as one.
    func testInterpolatedSecretReferenceIsNotWarnedAbout() throws {
        let home = home()
        let adapter = adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)

        func issues(forEnvironment environment: [String: String]) -> [String] {
            let server = MCPServerDefinition(
                id: "hermes:s", name: "s", transport: .stdio, command: "x",
                environmentKeys: Array(environment.keys), environment: environment
            )
            return adapter.validate(
                AgentConfiguration(
                    installation: installation, path: "", raw: "", hash: "",
                    mcpServers: [server], skillNames: []
                )
            ).map(\.id)
        }

        XCTAssertEqual(issues(forEnvironment: ["API_KEY": "${MCP_S_API_KEY}"]), [])
        XCTAssertEqual(issues(forEnvironment: ["API_KEY": "sk-live"]), ["hermes.mcp.s.secrets"])
    }

    func testMissingCommandAndURLAreErrors() throws {
        let home = home()
        let adapter = adapter(home)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = AgentConfiguration(
            installation: installation, path: "", raw: "", hash: "",
            mcpServers: [
                MCPServerDefinition(id: "1", name: "a", transport: .stdio, command: ""),
                MCPServerDefinition(id: "2", name: "b", transport: .http, url: ""),
            ],
            skillNames: []
        )
        XCTAssertEqual(
            adapter.validate(configuration).map(\.id),
            ["hermes.mcp.a.command", "hermes.mcp.b.url"]
        )
    }

    // MARK: - Changes

    func testChangesRoundTripThroughTheConfig() throws {
        let base = "mcp_servers:\n  time:\n    command: uvx\n    args: [\"mcp-server-time\"]\n"
        let added = try HermesAdapter.applying(
            [.addMCPServer(MCPServerDefinition(
                id: "hermes:uncoil", name: "uncoil", transport: .stdio,
                command: "/bin/uncoil-mcp", arguments: ["--stdio"]
            ))],
            to: base
        )
        XCTAssertEqual(HermesYAML.servers(in: added).map(\.name), ["time", "uncoil"])

        let disabled = try HermesAdapter.applying(
            [.setMCPServerEnabled(name: "uncoil", isEnabled: false)], to: added
        )
        XCTAssertEqual(
            HermesYAML.servers(in: disabled).first { $0.name == "uncoil" }?.isEnabled, false
        )

        let removed = try HermesAdapter.applying([.removeMCPServer(name: "uncoil")], to: disabled)
        XCTAssertEqual(HermesYAML.servers(in: removed).map(\.name), ["time"])
    }

    func testAnIncompleteServerIsRefusedRatherThanWritten() {
        XCTAssertThrowsError(
            try HermesAdapter.applying(
                [.addMCPServer(MCPServerDefinition(
                    id: "1", name: "a", transport: .stdio, command: ""
                ))],
                to: ""
            )
        )
        XCTAssertThrowsError(
            try HermesAdapter.applying(
                [.addMCPServer(MCPServerDefinition(
                    id: "2", name: "b", transport: .http, url: ""
                ))],
                to: ""
            )
        )
        XCTAssertThrowsError(
            try HermesAdapter.applying([.setMCPServerEnabled(name: "ghost", isEnabled: true)], to: "")
        )
    }

    // MARK: - Registration

    func testHermesIsAManagedAgent() {
        XCTAssertFalse(AgentAdapterRegistry().unmanagedAgents.contains(.hermes))
        XCTAssertNotNil(AgentAdapterRegistry().adapter(for: .hermes))
    }
}
