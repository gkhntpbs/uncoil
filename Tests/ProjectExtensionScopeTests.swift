import XCTest
@testable import Uncoil

/// A project says which MCP servers and skills its sessions get. These cover
/// the rule that decides it and the command lines it produces, because the two
/// failure modes are opposite and both are silent: a scope that is too wide
/// changes nothing the user asked for, and one that is too narrow takes tools
/// away from an agent without ever saying so.
final class ProjectExtensionScopeTests: XCTestCase {
    private let projectA = UUID()
    private let projectB = UUID()

    private func installation(
        agent: ExtensionAgentID = .codex,
        skills: String? = "/tmp/skills"
    ) -> AgentInstallation {
        AgentInstallation(
            agent: agent,
            binaryPath: "/usr/local/bin/\(agent.cliBinaryName)",
            configDirectory: "/tmp/config",
            skillsDirectory: skills,
            mcpConfigPath: "/tmp/config/config.toml",
            version: nil,
            isAuthenticated: nil,
            detectedAt: .now
        )
    }

    private func server(_ name: String) -> MCPServerDefinition {
        MCPServerDefinition(id: "codex:\(name)", name: name, transport: .stdio, command: "/bin/true")
    }

    private func configuration(
        servers: [String],
        skills: [String],
        agent: ExtensionAgentID = .codex,
        skillsDirectory: String? = "/tmp/skills"
    ) -> AgentConfiguration {
        AgentConfiguration(
            installation: installation(agent: agent, skills: skillsDirectory),
            path: "/tmp/config/config.toml",
            raw: "",
            hash: "",
            mcpServers: servers.map(server),
            skillNames: skills
        )
    }

    private func packages(servers: [String], skills: [String]) -> [ExtensionPackage] {
        servers.map {
            ExtensionPackage(
                id: "codex:\($0)", kind: .mcpServer, name: $0,
                source: .detectedExternal(path: "/bin/true")
            )
        } + skills.map {
            ExtensionPackage(
                id: "local:\($0)", kind: .skill, name: $0,
                source: .detectedExternal(path: "/tmp/skills/\($0)")
            )
        }
    }

    // MARK: - The rule

    /// The default, and the one every existing project lands on: a project that
    /// has never been configured keeps everything it had before this existed.
    func testAProjectWithNoRecordsAllowsEverything() {
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: ["figma", "supabase"], skills: ["a", "b"]),
            packages: packages(servers: ["figma", "supabase"], skills: ["a", "b"]),
            projectBindings: [],
            projectID: projectA
        )
        XCTAssertEqual(scope.allowedMCPNames, ["figma", "supabase"])
        XCTAssertTrue(scope.excludedMCPNames.isEmpty)
        XCTAssertEqual(scope.allowedSkillNames, ["a", "b"])
        XCTAssertTrue(scope.isUnrestricted)
    }

    /// Turning one thing off must not disturb its neighbours, and must not
    /// leak into another project.
    func testOneExclusionLeavesEverythingElseAlone() {
        let bindings = [
            ProjectBinding(extensionID: "codex:figma", projectID: projectA, isEnabled: false)
        ]
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: ["figma", "supabase"], skills: []),
            packages: packages(servers: ["figma", "supabase"], skills: []),
            projectBindings: bindings,
            projectID: projectA
        )
        XCTAssertEqual(scope.allowedMCPNames, ["supabase"])
        XCTAssertEqual(scope.excludedMCPNames, ["figma"])
        XCTAssertFalse(scope.isUnrestricted)

        let other = ProjectExtensionScope.resolve(
            configuration: configuration(servers: ["figma", "supabase"], skills: []),
            packages: packages(servers: ["figma", "supabase"], skills: []),
            projectBindings: bindings,
            projectID: projectB
        )
        XCTAssertEqual(other.allowedMCPNames, ["figma", "supabase"])
    }

    /// An extension installed after the project was configured has no record,
    /// so it arrives allowed rather than silently missing.
    func testSomethingInstalledLaterIsAllowedWithoutARecord() {
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: ["figma", "brand-new"], skills: []),
            packages: packages(servers: ["figma", "brand-new"], skills: []),
            projectBindings: [
                ProjectBinding(extensionID: "codex:figma", projectID: projectA, isEnabled: false)
            ],
            projectID: projectA
        )
        XCTAssertEqual(scope.allowedMCPNames, ["brand-new"])
    }

    /// Excluding `uncoil` would cut the session off from the app that started
    /// it, so it is not a decision the project is allowed to make.
    func testTheControlPlaneServerIsNeverExcluded() {
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: [ControlPlaneMCPName, "figma"], skills: []),
            packages: packages(servers: [ControlPlaneMCPName, "figma"], skills: []),
            projectBindings: [
                ProjectBinding(
                    extensionID: "codex:\(ControlPlaneMCPName)",
                    projectID: projectA, isEnabled: false
                )
            ],
            projectID: projectA
        )
        XCTAssertFalse(scope.excludedMCPNames.contains(ControlPlaneMCPName))
        XCTAssertFalse(scope.allowedMCPNames.contains(ControlPlaneMCPName))
    }

    func testSkillsCarryTheirPathAndVerdict() throws {
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: [], skills: ["keep", "drop"]),
            packages: packages(servers: [], skills: ["keep", "drop"]),
            projectBindings: [
                ProjectBinding(extensionID: "local:drop", projectID: projectA, isEnabled: false)
            ],
            projectID: projectA
        )
        XCTAssertEqual(scope.allowedSkillNames, ["keep"])
        XCTAssertEqual(scope.excludedSkillNames, ["drop"])
        let keep = try XCTUnwrap(scope.skills.first { $0.name == "keep" })
        XCTAssertEqual(keep.path, "/tmp/skills/keep/SKILL.md")
    }

    /// No skills directory means no path to hand Codex, and a decision that
    /// cannot be expressed is not carried.
    func testSkillsAreDroppedWhenTheAgentHasNoSkillsDirectory() {
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(
                servers: [], skills: ["a"], skillsDirectory: nil
            ),
            packages: packages(servers: [], skills: ["a"]),
            projectBindings: [],
            projectID: projectA
        )
        XCTAssertTrue(scope.skills.isEmpty)
    }

    /// A record naming another agent says nothing about this one.
    func testAnAgentScopedRecordDoesNotBindTheOtherAgent() {
        let bindings = [
            ProjectBinding(
                extensionID: "codex:figma", projectID: projectA,
                agent: .claudeCode, isEnabled: false
            )
        ]
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration(servers: ["figma"], skills: []),
            packages: packages(servers: ["figma"], skills: []),
            projectBindings: bindings,
            projectID: projectA
        )
        XCTAssertEqual(scope.allowedMCPNames, ["figma"])
    }

    // MARK: - Copying the allow-list verbatim

    /// Reading a config deliberately drops secret env VALUES, so Claude's
    /// strict allow-list is copied out of the raw JSON instead of rebuilt from
    /// parsed definitions. If it were rebuilt, this token would be gone and the
    /// server would start unauthenticated — with `--strict-mcp-config` making
    /// that broken copy the only one the session gets.
    func testTheAllowListKeepsSecretsAndUnknownKeys() throws {
        let raw = """
        {"mcpServers":{
          "github":{"command":"npx","args":["-y","srv"],
                    "env":{"GITHUB_TOKEN":"ghp_secret","REGION":"eu"},
                    "somethingUncoilDoesNotModel":true},
          "figma":{"command":"figma-mcp"}
        }}
        """
        let filtered = ProjectExtensionScope.filteredMCPServers(
            rawConfig: raw, allowing: ["github"]
        )
        XCTAssertEqual(Set(filtered.keys), ["github"])
        let entry = try XCTUnwrap(filtered["github"] as? [String: Any])
        let env = try XCTUnwrap(entry["env"] as? [String: String])
        XCTAssertEqual(env["GITHUB_TOKEN"], "ghp_secret")
        XCTAssertEqual(entry["somethingUncoilDoesNotModel"] as? Bool, true)
    }

    func testAnUnreadableConfigYieldsNoServersRatherThanACrash() {
        XCTAssertTrue(
            ProjectExtensionScope.filteredMCPServers(
                rawConfig: "not json", allowing: ["github"]
            ).isEmpty
        )
        XCTAssertTrue(
            ProjectExtensionScope.filteredMCPServers(rawConfig: "", allowing: ["a"]).isEmpty
        )
    }

    // MARK: - What reaches the command line

    private func command(
        provider: AgentProvider,
        scope: ProjectExtensionScope
    ) throws -> String {
        let record = SessionRecord(
            projectID: projectA, provider: provider, accountID: nil, title: "t"
        )
        return try XCTUnwrap(TerminalRegistry.launchCommand(
            for: record,
            resume: .fresh(nil),
            mcpConfigPath: "/tmp/session.json",
            mcpBinaryPath: "/tmp/uncoil-mcp",
            scope: scope,
            extraArguments: nil
        ))
    }

    /// An unconfigured project has to produce the command it always produced.
    /// This is the regression that matters most: every existing user is here.
    func testAnUnrestrictedProjectAddsNothingToTheCommandLine() throws {
        for provider in [AgentProvider.claude, .codex] {
            let before = try command(provider: provider, scope: .unrestricted)
            XCTAssertFalse(before.contains("--strict-mcp-config"), before)
            XCTAssertFalse(before.contains("enabled=false"), before)
            XCTAssertFalse(before.contains("skills.config"), before)
        }
    }

    func testClaudeGoesStrictOnlyOnceSomethingIsExcluded() throws {
        var scope = ProjectExtensionScope()
        scope.allowedMCPNames = ["supabase"]
        scope.excludedMCPNames = ["figma"]
        let command = try command(provider: .claude, scope: scope)
        XCTAssertTrue(command.contains("--mcp-config"), command)
        XCTAssertTrue(command.contains("--strict-mcp-config"), command)
        // Claude's allow-list travels in the config file, never as flags.
        XCTAssertFalse(command.contains("supabase"), command)
    }

    func testCodexSwitchesOffWhatTheProjectRefused() throws {
        var scope = ProjectExtensionScope()
        scope.allowedMCPNames = ["supabase"]
        scope.excludedMCPNames = ["figma", "blender"]
        let command = try command(provider: .codex, scope: scope)
        XCTAssertTrue(command.contains("mcp_servers.figma.enabled=false"), command)
        XCTAssertTrue(command.contains("mcp_servers.blender.enabled=false"), command)
        // Subtractive: an allowed server is never re-stated, so its secrets
        // never have to be either.
        XCTAssertFalse(command.contains("supabase"), command)
        XCTAssertFalse(command.contains("--strict-mcp-config"), command)
    }

    /// Only the refused skills are named. Measured against the installed CLI
    /// with `codex debug prompt-input`: the override array merges into the
    /// config's own `[[skills.config]]` rather than replacing it, so naming one
    /// skill removed exactly that one and left the other 48 listed. Listing the
    /// allowed ones as `enabled=true` would assert a default at length, and
    /// would overrule a skill the user had disabled globally.
    func testCodexNamesOnlyTheSkillsTheProjectRefused() throws {
        var scope = ProjectExtensionScope()
        scope.skills = [
            .init(name: "keep", path: "/tmp/skills/keep/SKILL.md", isEnabled: true),
            .init(name: "drop", path: "/tmp/skills/drop/SKILL.md", isEnabled: false),
        ]
        let command = try command(provider: .codex, scope: scope)
        XCTAssertTrue(command.contains("skills.config="), command)
        XCTAssertTrue(command.contains("path=\"/tmp/skills/drop/SKILL.md\",enabled=false"), command)
        XCTAssertFalse(command.contains("keep"), command)
        XCTAssertFalse(command.contains("enabled=true"), command)
    }

    /// A path holding a quote has to arrive escaped: Codex parses a `-c` value
    /// as TOML and falls back to a bare literal when the parse fails, so an
    /// unescaped quote would turn the whole array into one inert string.
    func testASkillPathWithAQuoteIsEscapedForTOML() throws {
        var scope = ProjectExtensionScope()
        scope.skills = [
            .init(name: "odd", path: "/tmp/sk\"ills/odd/SKILL.md", isEnabled: false),
            .init(name: "ok", path: "/tmp/skills/ok/SKILL.md", isEnabled: true),
        ]
        let command = try command(provider: .codex, scope: scope)
        XCTAssertTrue(command.contains("\\\"ills"), command)
    }

    /// The skill list is only worth sending when something is actually off.
    func testCodexSendsNoSkillListWhenNothingIsExcluded() throws {
        var scope = ProjectExtensionScope()
        scope.skills = [
            .init(name: "a", path: "/tmp/skills/a/SKILL.md", isEnabled: true)
        ]
        XCTAssertFalse(try command(provider: .codex, scope: scope).contains("skills.config"))
    }

    /// A provider with no per-session mechanism must not have flags invented
    /// for it — see `AgentProvider.extensionScoping`.
    func testAProviderThatCannotBeScopedGetsNoScopingFlags() throws {
        var scope = ProjectExtensionScope()
        scope.excludedMCPNames = ["figma"]
        let command = try command(provider: .gemini, scope: scope)
        XCTAssertFalse(command.contains("enabled=false"), command)
        XCTAssertFalse(command.contains("--strict-mcp-config"), command)
    }

    // MARK: - OpenCode's inline config

    func testOpenCodeSwitchesOffRefusedServersInline() throws {
        let record = SessionRecord(
            projectID: projectA, provider: .opencode, accountID: nil, title: "t"
        )
        var scope = ProjectExtensionScope()
        scope.excludedMCPNames = ["figma"]
        let content = try XCTUnwrap(TerminalRegistry.openCodeConfigContent(
            for: record, binaryPath: "/tmp/uncoil-mcp", scope: scope
        ))
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertNotNil(mcp[ControlPlaneMCPName])
        let figma = try XCTUnwrap(mcp["figma"] as? [String: Any])
        XCTAssertEqual(figma["enabled"] as? Bool, false)
        // Nothing else about the server is restated, so nothing about it can be
        // lost by being restated wrongly.
        XCTAssertEqual(figma.count, 1)
    }

    // MARK: - The provider matrix

    /// What the picker tells the user and what the launcher does have to come
    /// from the same answer, or the screen becomes a lie.
    func testTheScopingMatrixMatchesWhatTheLauncherImplements() {
        XCTAssertEqual(AgentProvider.codex.extensionScoping, .strict)
        XCTAssertEqual(AgentProvider.claude.extensionScoping, .mcpOnly)
        XCTAssertEqual(AgentProvider.opencode.extensionScoping, .mcpOnly)
        XCTAssertEqual(AgentProvider.gemini.extensionScoping, .none)
        XCTAssertEqual(AgentProvider.hermes.extensionScoping, .none)
        XCTAssertEqual(AgentProvider.terminal.extensionScoping, .none)

        // Scoping needs a per-session registration channel, which is exactly
        // what `wiresControlPlane` records.
        for provider in AgentProvider.allCases where provider.extensionScoping != .none {
            XCTAssertTrue(provider.wiresControlPlane, provider.rawValue)
        }
    }

    // MARK: - Selection round-trip

    func testTheSelectionRoundTripsThroughTheStoredRecords() {
        let excluded: Set<String> = ["codex:figma", "local:drop"]
        let bindings = ProjectExtensionPicker.bindings(
            excluding: excluded, projectID: projectA
        )
        XCTAssertEqual(bindings.count, 2)
        XCTAssertTrue(bindings.allSatisfy { !$0.isEnabled && $0.projectID == projectA })
        XCTAssertEqual(
            ProjectExtensionPicker.excludedIDs(in: bindings, projectID: projectA),
            excluded
        )
        // Another project's records are not this project's selection.
        XCTAssertTrue(
            ProjectExtensionPicker.excludedIDs(in: bindings, projectID: projectB).isEmpty
        )
    }

    /// Allowing something is the absence of a record, not a record saying yes.
    /// That is what lets an extension installed tomorrow reach the project.
    func testAllowingSomethingWritesNoRecord() {
        XCTAssertTrue(
            ProjectExtensionPicker.bindings(excluding: [], projectID: projectA).isEmpty
        )
    }
}
