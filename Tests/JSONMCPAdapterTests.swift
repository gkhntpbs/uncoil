import XCTest
@testable import Uncoil

@MainActor
final class JSONMCPAdapterTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-json-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func adapter(_ layout: JSONMCPConfigLayout) -> JSONMCPAdapter {
        var adapter = JSONMCPAdapter(layout: layout)
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        return adapter
    }

    private func writeConfig(_ contents: String, at relativePath: String) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Layouts

    func testEveryLayoutIsDistinctAndComplete() {
        let layouts = JSONMCPConfigLayout.all
        XCTAssertEqual(Set(layouts.map(\.agent)).count, layouts.count)
        for layout in layouts {
            XCTAssertFalse(layout.configRelativePath.isEmpty, layout.agent.rawValue)
            XCTAssertFalse(layout.serversKeyPath.isEmpty, layout.agent.rawValue)
            XCTAssertFalse(layout.binaryName.isEmpty, layout.agent.rawValue)
            XCTAssertFalse(layout.reload.isEmpty, layout.agent.rawValue)
        }
        XCTAssertEqual(JSONMCPConfigLayout.amp.serversKeyPath, ["amp.mcpServers"])
    }

    func testTheRegistryCoversEveryListedAgent() {
        let registry = AgentAdapterRegistry()
        XCTAssertTrue(
            registry.unmanagedAgents.isEmpty,
            "every listed agent has an adapter now: \(registry.unmanagedAgents)"
        )
        for agent in ExtensionAgentID.supported {
            XCTAssertNotNil(registry.adapter(for: agent), agent.rawValue)
        }
        XCTAssertEqual(ExtensionAgentID.launchable, [.claudeCode, .codex])
    }

    // MARK: - Reading

    func testGeminiServersAreRead() throws {
        _ = try writeConfig(
            """
            {
              "theme": "dark",
              "mcpServers": {
                "b-http": { "url": "https://example.test/mcp" },
                "a-stdio": {
                  "command": "uncoil-mcp",
                  "args": ["--stdio"],
                  "env": { "LOG_LEVEL": "debug", "API_TOKEN": "gizli" }
                }
              }
            }
            """,
            at: ".gemini/settings.json"
        )
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)

        XCTAssertEqual(configuration.mcpServers.map(\.name), ["a-stdio", "b-http"])
        let stdio = try XCTUnwrap(configuration.mcpServers.first)
        XCTAssertEqual(stdio.transport, .stdio)
        XCTAssertEqual(stdio.command, "uncoil-mcp")
        XCTAssertEqual(stdio.arguments, ["--stdio"])
        XCTAssertEqual(stdio.environment, ["LOG_LEVEL": "debug"])
        XCTAssertEqual(
            stdio.environmentKeys, ["API_TOKEN"],
            "a secret is reported by name, never by value"
        )
        XCTAssertEqual(configuration.mcpServers[1].transport, .http)
    }

    func testAmpsNamespacedKeyIsRead() throws {
        _ = try writeConfig(
            """
            { "amp.mcpServers": { "x": { "command": "x-server" } }, "amp.theme": "light" }
            """,
            at: ".config/amp/settings.json"
        )
        let adapter = self.adapter(.amp)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        XCTAssertEqual(
            try adapter.readConfiguration(installation).mcpServers.map(\.name), ["x"]
        )
    }

    func testAMissingConfigReadsAsEmptyRatherThanFailing() throws {
        let adapter = self.adapter(.cursor)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        XCTAssertTrue(configuration.raw.isEmpty)
        XCTAssertTrue(configuration.mcpServers.isEmpty)
        XCTAssertTrue(adapter.validate(configuration).isEmpty)
    }

    func testBothSpellingsOfDisabledAreUnderstood() throws {
        let servers = try JSONMCPAdapter.parseServers(
            """
            {
              "mcpServers": {
                "a": { "command": "a", "disabled": true },
                "b": { "command": "b", "enabled": false },
                "c": { "command": "c" }
              }
            }
            """,
            layout: .geminiCLI
        )
        XCTAssertEqual(servers.filter(\.isEnabled).map(\.name), ["c"])
    }

    func testBrokenJSONIsReportedAndNeverWritten() throws {
        let url = try writeConfig("{ bu JSON değil", at: ".gemini/settings.json")
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        XCTAssertThrowsError(try adapter.readConfiguration(installation)) { error in
            guard case AgentAdapterError.configMalformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "{ bu JSON değil",
            "a file Uncoil could not parse is left exactly as it was"
        )
    }

    // MARK: - Writing

    func testAddingAServerLeavesEveryOtherKeyAlone() throws {
        _ = try writeConfig(
            """
            { "theme": "dark", "customCommands": { "x": "y" }, "mcpServers": {} }
            """,
            at: ".gemini/settings.json"
        )
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "geminiCLI:uncoil", name: "uncoil", transport: .stdio,
                command: "uncoil-mcp", arguments: ["--stdio"],
                environment: ["LOG_LEVEL": "debug", "OPENAI_API_KEY": "gizli"]
            ))],
            for: configuration
        )
        let applied = try adapter.apply(transaction)
        XCTAssertEqual(applied.status, .applied)

        let after = try adapter.readConfiguration(installation)
        XCTAssertEqual(after.mcpServers.map(\.name), ["uncoil"])
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(after.raw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(root["theme"] as? String, "dark", "the user's own keys survive")
        XCTAssertNotNil(root["customCommands"])
        XCTAssertFalse(
            after.raw.contains("gizli"),
            "a secret value never reaches an agent config"
        )
        XCTAssertTrue(after.raw.contains("LOG_LEVEL"))
    }

    func testAmpsNestedKeyIsWrittenWithoutFlatteningIt() throws {
        let updated = try JSONMCPAdapter.applying(
            [.addMCPServer(MCPServerDefinition(
                id: "amp:uncoil", name: "uncoil", transport: .http,
                url: "https://example.test/mcp"
            ))],
            to: "{ \"amp.theme\": \"light\" }",
            layout: .amp
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any]
        )
        XCTAssertEqual(root["amp.theme"] as? String, "light")
        let servers = try XCTUnwrap(root["amp.mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["uncoil"])
    }

    func testDisablingAndRemovingAServer() throws {
        let base = """
        { "mcpServers": { "a": { "command": "a" }, "b": { "command": "b" } } }
        """
        let disabled = try JSONMCPAdapter.applying(
            [.setMCPServerEnabled(name: "a", isEnabled: false)], to: base, layout: .cursor
        )
        XCTAssertEqual(
            try JSONMCPAdapter.parseServers(disabled, layout: .cursor)
                .first { $0.name == "a" }?.isEnabled,
            false
        )
        let reenabled = try JSONMCPAdapter.applying(
            [.setMCPServerEnabled(name: "a", isEnabled: true)], to: disabled, layout: .cursor
        )
        XCTAssertEqual(
            try JSONMCPAdapter.parseServers(reenabled, layout: .cursor)
                .first { $0.name == "a" }?.isEnabled,
            true
        )
        let removed = try JSONMCPAdapter.applying(
            [.removeMCPServer(name: "a")], to: base, layout: .cursor
        )
        XCTAssertEqual(
            try JSONMCPAdapter.parseServers(removed, layout: .cursor).map(\.name), ["b"]
        )
    }

    func testDisablingAServerThatIsNotThereIsRefused() {
        XCTAssertThrowsError(
            try JSONMCPAdapter.applying(
                [.setMCPServerEnabled(name: "yok", isEnabled: false)],
                to: "{ \"mcpServers\": {} }", layout: .cursor
            )
        )
    }

    func testAStdioServerWithoutACommandIsRefused() {
        XCTAssertThrowsError(
            try JSONMCPAdapter.applying(
                [.addMCPServer(MCPServerDefinition(
                    id: "cursor:x", name: "x", transport: .stdio
                ))],
                to: "{}", layout: .cursor
            )
        )
    }

    func testAConfigTouchedSinceThePlanIsNotOverwritten() throws {
        let url = try writeConfig("{ \"mcpServers\": {} }", at: ".cursor/mcp.json")
        let adapter = self.adapter(.cursor)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let configuration = try adapter.readConfiguration(installation)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "cursor:x", name: "x", transport: .stdio, command: "x"
            ))],
            for: configuration
        )
        // Someone edits the file between plan and apply.
        try Data("{ \"mcpServers\": { \"elle\": { \"command\": \"elle\" } } }".utf8)
            .write(to: url)

        let applied = try adapter.apply(transaction)
        XCTAssertEqual(applied.status, .staleConfig)
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("elle"),
            "the hand-made edit survives"
        )
    }

    func testRollbackRestoresTheFileFromItsBackup() throws {
        let url = try writeConfig(
            "{ \"theme\": \"dark\", \"mcpServers\": {} }", at: ".gemini/settings.json"
        )
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let before = try String(contentsOf: url, encoding: .utf8)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "geminiCLI:x", name: "x", transport: .stdio, command: "x"
            ))],
            for: try adapter.readConfiguration(installation)
        )
        let applied = try adapter.apply(transaction)
        XCTAssertEqual(applied.status, .applied)
        XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), before)

        let rolledBack = try adapter.rollback(applied)
        XCTAssertEqual(rolledBack.status, .rolledBack)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    func testThePlanCarriesAReadableDiffAndChangesNothingOnItsOwn() throws {
        let url = try writeConfig("{ \"mcpServers\": {} }", at: ".gemini/settings.json")
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let transaction = try adapter.plan(
            [.addMCPServer(MCPServerDefinition(
                id: "geminiCLI:x", name: "x", transport: .http, url: "https://example.test"
            ))],
            for: try adapter.readConfiguration(installation)
        )
        XCTAssertFalse(transaction.diff.isEmpty)
        XCTAssertTrue(transaction.diff.contains("example.test"), transaction.diff)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "{ \"mcpServers\": {} }",
            "planning writes nothing"
        )
    }

    func testReloadSemanticsMatchTheAgent() throws {
        for layout in JSONMCPConfigLayout.all {
            let adapter = self.adapter(layout)
            let installation = try XCTUnwrap(adapter.detectInstallations().first)
            switch adapter.reload(installation) {
            case .reloaded:
                XCTAssertTrue(adapter.capabilities.reloadsConfigWithoutRestart)
            case .restartRequired(let note):
                XCTAssertFalse(note.isEmpty)
            case .unsupported(let note):
                XCTFail("unexpected: \(note)")
            }
        }
    }

    func testSecretsInAConfigAreReportedAsAWarning() throws {
        _ = try writeConfig(
            """
            { "mcpServers": { "x": { "command": "x", "env": { "API_TOKEN": "gizli" } } } }
            """,
            at: ".gemini/settings.json"
        )
        let adapter = self.adapter(.geminiCLI)
        let installation = try XCTUnwrap(adapter.detectInstallations().first)
        let issues = adapter.validate(try adapter.readConfiguration(installation))
        XCTAssertEqual(issues.filter { $0.severity == .warning }.count, 1)
        XCTAssertTrue(issues[0].message.contains("API_TOKEN"))
        XCTAssertFalse(issues[0].message.contains("gizli"))
    }
}
