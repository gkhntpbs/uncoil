import XCTest
@testable import Uncoil

/// The parse/apply core of the OpenCode adapter — its JSON shape is unlike the
/// `mcpServers` family (array command, `type` field, `environment`, `enabled`),
/// which is the whole reason the adapter exists.
final class OpenCodeAdapterTests: XCTestCase {
    private let sample = """
    {
      "$schema": "https://opencode.ai/config.json",
      "provider": { "lan-ollama": { "name": "Ollama" } },
      "mcp": {
        "uncoil": {
          "type": "local",
          "command": ["/Applications/Uncoil.app/Contents/Helpers/uncoil-mcp"],
          "environment": { "UNCOIL_SESSION_ID": "abc" }
        },
        "docs": {
          "type": "remote",
          "url": "https://example.test/mcp",
          "enabled": false
        }
      }
    }
    """

    // MARK: Reading

    func testParsesLocalAndRemoteServers() throws {
        let servers = try OpenCodeAdapter.parseServers(sample)
        XCTAssertEqual(servers.map(\.name), ["docs", "uncoil"])

        let local = servers[1]
        XCTAssertEqual(local.transport, .stdio)
        XCTAssertEqual(local.command, "/Applications/Uncoil.app/Contents/Helpers/uncoil-mcp")
        XCTAssertEqual(local.arguments, [])
        XCTAssertEqual(local.environment["UNCOIL_SESSION_ID"], "abc")
        XCTAssertTrue(local.isEnabled)

        let remote = servers[0]
        XCTAssertEqual(remote.transport, .http)
        XCTAssertEqual(remote.url, "https://example.test/mcp")
        XCTAssertFalse(remote.isEnabled)
    }

    func testArrayCommandSplitsIntoCommandAndArguments() throws {
        let raw = """
        { "mcp": { "s": { "type": "local", "command": ["bunx", "-y", "server"] } } }
        """
        let server = try XCTUnwrap(OpenCodeAdapter.parseServers(raw).first)
        XCTAssertEqual(server.command, "bunx")
        XCTAssertEqual(server.arguments, ["-y", "server"])
    }

    func testConfigWithoutMCPKeyReadsAsEmpty() throws {
        XCTAssertEqual(try OpenCodeAdapter.parseServers("{ \"theme\": \"dark\" }"), [])
    }

    func testMalformedConfigThrowsRatherThanReturningEmpty() {
        XCTAssertThrowsError(try OpenCodeAdapter.parseServers("not json"))
    }

    // MARK: JSONC

    func testCommentsAreStrippedOutsideStringsOnly() throws {
        let raw = """
        {
          // servers live here
          "mcp": {
            /* the uncoil control plane */
            "uncoil": { "type": "remote", "url": "https://example.test/path" }
          }
        }
        """
        let server = try XCTUnwrap(OpenCodeAdapter.parseServers(raw).first)
        // The `//` inside the URL must survive: a comment stripper that eats
        // it would corrupt the one value every remote server depends on.
        XCTAssertEqual(server.url, "https://example.test/path")
    }

    // MARK: Writing

    func testAddingAServerTouchesOnlyTheMCPObject() throws {
        let updated = try OpenCodeAdapter.applying(
            [.addMCPServer(MCPServerDefinition(
                id: "opencode:new",
                name: "new",
                transport: .stdio,
                command: "bunx",
                arguments: ["server"]
            ))],
            to: sample
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any]
        )
        // Unknown keys survive the round-trip.
        XCTAssertNotNil(root["$schema"])
        XCTAssertNotNil(root["provider"])
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertEqual(Set(mcp.keys), ["uncoil", "docs", "new"])
        let entry = try XCTUnwrap(mcp["new"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["bunx", "server"])
    }

    func testSecretsNeverReachTheConfig() throws {
        let updated = try OpenCodeAdapter.applying(
            [.addMCPServer(MCPServerDefinition(
                id: "opencode:s",
                name: "s",
                transport: .stdio,
                command: "run",
                environment: ["MY_API_KEY": "sk-secret", "PLAIN": "1"]
            ))],
            to: "{}"
        )
        XCTAssertFalse(updated.contains("sk-secret"))
        XCTAssertTrue(updated.contains("PLAIN"))
    }

    func testDisablingUsesOpenCodesOwnSpelling() throws {
        let updated = try OpenCodeAdapter.applying(
            [.setMCPServerEnabled(name: "uncoil", isEnabled: false)],
            to: sample
        )
        let servers = try OpenCodeAdapter.parseServers(updated)
        XCTAssertEqual(servers.first { $0.name == "uncoil" }?.isEnabled, false)
        // Re-enabling removes the key rather than writing `enabled: true` —
        // checked on the entry itself, because `docs` keeps its own flag.
        let restored = try OpenCodeAdapter.applying(
            [.setMCPServerEnabled(name: "uncoil", isEnabled: true)],
            to: updated
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any]
        )
        let entry = try XCTUnwrap((root["mcp"] as? [String: Any])?["uncoil"] as? [String: Any])
        XCTAssertNil(entry["enabled"])
    }

    // MARK: Per-session control plane

    func testOpenCodeIsALaunchableProviderThatWiresTheControlPlane() {
        XCTAssertEqual(ExtensionAgentID.opencode.provider, .opencode)
        XCTAssertTrue(AgentProvider.opencode.isAgent)
        XCTAssertTrue(AgentProvider.opencode.wiresControlPlane)
        // `--session <id>` is documented, so a hibernated session can wake up
        // holding its conversation instead of silently restarting.
        XCTAssertTrue(AgentProvider.opencode.resumesConversation)
        // No hook system: it must never be the fallback owner of a hook event.
        XCTAssertFalse(AgentProvider.opencode.reportsStatusThroughHooks)
        XCTAssertTrue(AgentProvider.agents.contains(.opencode))
    }

    func testInlineSessionConfigMatchesTheShapeOpenCodeReads() throws {
        let record = SessionRecord(
            projectID: UUID(), provider: .opencode, accountID: nil, title: "t"
        )
        let content = try XCTUnwrap(
            TerminalRegistry.openCodeConfigContent(for: record, binaryPath: "/A/uncoil-mcp")
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
        let entry = try XCTUnwrap((root["mcp"] as? [String: Any])?["uncoil"] as? [String: Any])
        // Verified against the installed CLI: `type`/`command` array, and the
        // env under `environment`. A wrong key here is a server that never
        // starts, and the agent would report the tools as simply missing.
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["/A/uncoil-mcp"])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        let environment = try XCTUnwrap(entry["environment"] as? [String: String])
        XCTAssertEqual(environment["UNCOIL_SESSION_ID"], record.id.uuidString)
        XCTAssertEqual(environment["UNCOIL_PROJECT_ID"], record.projectID.uuidString)
        // Without the socket the helper answers CONTROL_PLANE_UNAVAILABLE to
        // every call, so its absence would be a control plane in name only.
        XCTAssertFalse((environment["UNCOIL_CONTROL_SOCKET"] ?? "").isEmpty)
        // The inline config carries only `mcp`: anything else would replace
        // part of the user's own configuration on merge.
        XCTAssertEqual(Array(root.keys), ["mcp"])
    }

    func testResumeUsesOpenCodesOwnSessionFlag() {
        var record = SessionRecord(
            projectID: UUID(), provider: .opencode, accountID: nil, title: "t"
        )
        record.providerSessionID = "ses_123"
        let command = TerminalRegistry.launchCommand(
            for: record, resume: .resume("ses_123"), extraArguments: nil
        )
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("--session 'ses_123'"), command!)
    }

    func testRemovingAServerLeavesTheRest() throws {
        let updated = try OpenCodeAdapter.applying(
            [.removeMCPServer(name: "docs")],
            to: sample
        )
        XCTAssertEqual(try OpenCodeAdapter.parseServers(updated).map(\.name), ["uncoil"])
    }
}
