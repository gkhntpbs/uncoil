import XCTest
@testable import Uncoil

/// Registering the MCP server is provider-specific — `--mcp-config` for Claude
/// Code, `-c mcp_servers.uncoil.*` for Codex — so "is an agent" is not the same
/// question as "gets the control plane". Handing a session `UNCOIL_CONTROL_SOCKET`
/// while nothing registers a server would advertise tools that are not there:
/// the agent reads the variables, finds nothing, and the failure reads as a
/// broken socket rather than a missing feature.
final class ControlPlaneWiringTests: XCTestCase {
    func testOnlyTheProvidersWithRegistrationAreWired() {
        XCTAssertTrue(AgentProvider.claude.wiresControlPlane)
        XCTAssertTrue(AgentProvider.codex.wiresControlPlane)
        XCTAssertFalse(AgentProvider.gemini.wiresControlPlane)
        XCTAssertFalse(AgentProvider.terminal.wiresControlPlane)
    }

    /// A shell is never wired, so being wired always implies being an agent —
    /// but not the other way round, which is the whole point.
    func testWiringImpliesAgentButNotTheReverse() {
        for provider in AgentProvider.allCases where provider.wiresControlPlane {
            XCTAssertTrue(provider.isAgent, provider.rawValue)
        }
        XCTAssertTrue(
            AgentProvider.agents.contains { !$0.wiresControlPlane },
            "if every agent were wired this distinction would be dead code"
        )
    }

    /// The launch command is where the registration actually happens; a
    /// provider that is not wired must not get one written for it.
    func testAnUnwiredProviderGetsNoServerOnItsCommandLine() throws {
        let record = SessionRecord(
            projectID: UUID(), provider: .gemini, accountID: nil, title: "gemini"
        )
        let command = try XCTUnwrap(TerminalRegistry.launchCommand(
            for: record,
            mcpConfigPath: "/tmp/should-not-be-used.json",
            mcpBinaryPath: "/tmp/uncoil-mcp",
            mcpEnvironment: ["UNCOIL_SESSION_ID": record.id.uuidString],
            extraArguments: nil
        ))
        XCTAssertFalse(command.contains("mcp"), command)
    }

    func testClaudeGetsItsConfigOnTheCommandLine() throws {
        let record = SessionRecord(
            projectID: UUID(), provider: .claude, accountID: nil, title: "claude"
        )
        let command = try XCTUnwrap(TerminalRegistry.launchCommand(
            for: record,
            mcpConfigPath: "/tmp/session.json",
            mcpBinaryPath: "/tmp/uncoil-mcp",
            extraArguments: nil
        ))
        XCTAssertTrue(command.contains("--mcp-config"), command)
    }
}
