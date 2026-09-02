import XCTest
@testable import Uncoil

/// `HermesYAML` edits the user's `~/.hermes/config.yaml` in place, so what these
/// tests are really pinning is that everything it does *not* manage comes back
/// untouched. Hermes' own `cli-config.yaml.example` is fourteen hundred lines of
/// commented documentation people copy from and edit; a rewrite that reordered,
/// re-quoted or dropped a comment would be the bug, not a cosmetic difference.
final class HermesYAMLTests: XCTestCase {
    /// The shapes Hermes' own documentation shows, together: a flow sequence, a
    /// block sequence, a nested `env:`, a URL value whose colon is not a
    /// key separator, and comments in between.
    private let sample = """
    # Hermes configuration
    model:
      provider: openrouter

    mcp_servers:
      # the clock one
      time:
        command: uvx
        args: ["mcp-server-time"]
      github:
        command: npx
        args:
          - "-y"
          - "@modelcontextprotocol/server-github"
        env:
          GITHUB_PERSONAL_ACCESS_TOKEN: "ghp_xxx"
      notion:
        url: https://mcp.notion.com/mcp

    hooks_auto_accept: false
    """

    // MARK: - Reading

    func testReadsEveryServerShapeHermesDocuments() {
        let servers = HermesYAML.servers(in: sample)
        XCTAssertEqual(servers.map(\.name), ["time", "github", "notion"])

        let time = servers[0]
        XCTAssertEqual(time.transport, .stdio)
        XCTAssertEqual(time.command, "uvx")
        XCTAssertEqual(time.arguments, ["mcp-server-time"])

        // A block sequence has to read the same as the flow one.
        XCTAssertEqual(servers[1].arguments, ["-y", "@modelcontextprotocol/server-github"])

        // `https://…` must not split at its own colon.
        XCTAssertEqual(servers[2].transport, .http)
        XCTAssertEqual(servers[2].url, "https://mcp.notion.com/mcp")
        XCTAssertNil(servers[2].command)
    }

    func testSecretValuesAreSeparatedFromPlainOnes() {
        let github = HermesYAML.servers(in: sample)[1]
        XCTAssertEqual(github.environmentKeys, ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertTrue(github.environment.isEmpty)
    }

    /// Hermes loads its config with PyYAML's `safe_load`, which is YAML 1.1: a
    /// server switched off with `enabled: no` really is off, and reading only
    /// `false` would report it as running.
    func testYAML11BooleansAreHonoured() {
        for word in ["false", "no", "off", "No", "OFF"] {
            let text = """
            mcp_servers:
              a:
                command: x
                enabled: \(word)
            """
            XCTAssertEqual(
                HermesYAML.servers(in: text).first?.isEnabled, false,
                "`enabled: \(word)` should read as off"
            )
        }
        for word in ["true", "yes", "on"] {
            let text = """
            mcp_servers:
              a:
                command: x
                enabled: \(word)
            """
            XCTAssertEqual(HermesYAML.servers(in: text).first?.isEnabled, true)
        }
    }

    func testMissingEnabledMeansEnabled() {
        XCTAssertTrue(HermesYAML.servers(in: sample).allSatisfy(\.isEnabled))
    }

    func testCommentsDoNotBecomeValues() {
        let text = """
        mcp_servers:
          a:
            command: uvx  # the runner
            args: ["a#b"]
        """
        let server = HermesYAML.servers(in: text).first
        XCTAssertEqual(server?.command, "uvx")
        // A `#` with no space before it is not a comment in YAML.
        XCTAssertEqual(server?.arguments, ["a#b"])
    }

    func testNoMappingMeansNoServers() {
        XCTAssertTrue(HermesYAML.servers(in: "model:\n  provider: x\n").isEmpty)
        XCTAssertTrue(HermesYAML.servers(in: "").isEmpty)
    }

    /// Four-space indentation is ordinary YAML, and appending a two-space entry
    /// into such a file would silently drop the new server out of the mapping.
    func testEntryIndentIsReadFromTheFileNotAssumed() {
        let text = """
        mcp_servers:
            a:
                command: uvx
        """
        XCTAssertEqual(HermesYAML.serversSection(in: text)?.entryIndent, 4)
        XCTAssertEqual(HermesYAML.servers(in: text).map(\.name), ["a"])

        let appended = HermesYAML.rewrite(
            text,
            name: "b",
            with: MCPServerDefinition(id: "hermes:b", name: "b", transport: .stdio, command: "npx")
        )
        XCTAssertTrue(appended.contains("\n    b:\n"), appended)
        XCTAssertEqual(HermesYAML.servers(in: appended).map(\.name), ["a", "b"])
    }

    // MARK: - Writing

    func testAppendingLeavesEverythingElseByteIdentical() {
        let updated = HermesYAML.rewrite(
            sample,
            name: "uncoil",
            with: MCPServerDefinition(
                id: "hermes:uncoil", name: "uncoil", transport: .stdio,
                command: "/path/uncoil-mcp", arguments: []
            )
        )
        for line in sample.components(separatedBy: "\n") where !line.isEmpty {
            XCTAssertTrue(updated.contains(line), "lost line: \(line)")
        }
        XCTAssertTrue(updated.contains("# the clock one"))
        XCTAssertTrue(updated.contains("hooks_auto_accept: false"))
        XCTAssertEqual(
            HermesYAML.servers(in: updated).map(\.name),
            ["time", "github", "notion", "uncoil"]
        )
    }

    func testReplacingOneServerLeavesItsNeighboursAlone() {
        var github = HermesYAML.servers(in: sample)[1]
        github.isEnabled = false
        let updated = HermesYAML.rewrite(sample, name: "github", with: github)
        let servers = HermesYAML.servers(in: updated)
        XCTAssertEqual(servers.map(\.name), ["time", "github", "notion"])
        XCTAssertEqual(servers[1].isEnabled, false)
        XCTAssertEqual(servers[1].arguments, ["-y", "@modelcontextprotocol/server-github"])
        XCTAssertEqual(servers[0].command, "uvx")
        XCTAssertEqual(servers[2].url, "https://mcp.notion.com/mcp")
        XCTAssertTrue(updated.contains("# the clock one"))
    }

    func testRemovingOneServerKeepsTheRest() {
        let updated = HermesYAML.rewrite(sample, name: "github", with: nil)
        XCTAssertEqual(HermesYAML.servers(in: updated).map(\.name), ["time", "notion"])
        XCTAssertFalse(updated.contains("server-github"))
        XCTAssertTrue(updated.contains("hooks_auto_accept: false"))
    }

    /// An `mcp_servers:` with nothing under it parses as null, which Hermes
    /// already treats as "no servers" — but leaving it invites the next
    /// hand-edit to add an entry at some other indent, so the header goes too.
    func testRemovingTheLastServerRemovesTheMappingHeader() {
        let text = """
        model:
          provider: x

        mcp_servers:
          only:
            command: uvx
        """
        let updated = HermesYAML.rewrite(text, name: "only", with: nil)
        XCTAssertFalse(updated.contains("mcp_servers:"))
        XCTAssertTrue(updated.contains("provider: x"))
    }

    func testAddingToAFileWithNoMappingCreatesOne() {
        let updated = HermesYAML.rewrite(
            "model:\n  provider: x\n",
            name: "uncoil",
            with: MCPServerDefinition(
                id: "hermes:uncoil", name: "uncoil", transport: .stdio, command: "/bin/mcp"
            )
        )
        XCTAssertTrue(updated.contains("provider: x"))
        XCTAssertEqual(HermesYAML.servers(in: updated).map(\.name), ["uncoil"])
    }

    /// The normal case: `~/.hermes/config.yaml` is written lazily, so a working
    /// install often has no file at all.
    func testAddingToAnEmptyFileProducesValidConfig() {
        let updated = HermesYAML.rewrite(
            "",
            name: "uncoil",
            with: MCPServerDefinition(
                id: "hermes:uncoil", name: "uncoil", transport: .stdio,
                command: "/bin/mcp", arguments: ["--stdio"]
            )
        )
        let server = HermesYAML.servers(in: updated).first
        XCTAssertEqual(server?.command, "/bin/mcp")
        XCTAssertEqual(server?.arguments, ["--stdio"])
    }

    func testSecretValuesNeverReachTheFile() {
        let updated = HermesYAML.rewrite(
            "",
            name: "s",
            with: MCPServerDefinition(
                id: "hermes:s", name: "s", transport: .stdio, command: "x",
                environment: ["API_KEY": "sk-live-secret", "REGION": "eu"]
            )
        )
        XCTAssertFalse(updated.contains("sk-live-secret"))
        XCTAssertTrue(updated.contains("REGION"))
    }

    /// Everything written is double-quoted, so a value that would otherwise
    /// change meaning — `${VAR}`, `yes`, a bare number — survives a round trip.
    func testValuesThatYAMLWouldReinterpretSurviveARoundTrip() {
        let awkward = ["${UNCOIL_SESSION_ID}", "yes", "12345", "- dash", "a: b", "#hash"]
        let updated = HermesYAML.rewrite(
            "",
            name: "s",
            with: MCPServerDefinition(
                id: "hermes:s", name: "s", transport: .stdio, command: "x", arguments: awkward
            )
        )
        XCTAssertEqual(HermesYAML.servers(in: updated).first?.arguments, awkward)
    }

    func testUnmodelledKeysSurviveANeighboursRewrite() {
        let text = """
        mcp_servers:
          a:
            command: uvx
            sampling:
              enabled: true
              max_rpm: 10
          b:
            command: npx
        """
        let updated = HermesYAML.rewrite(text, name: "b", with: nil)
        XCTAssertTrue(updated.contains("max_rpm: 10"))
        XCTAssertTrue(updated.contains("sampling:"))
        XCTAssertEqual(HermesYAML.servers(in: updated).map(\.name), ["a"])
    }
}
