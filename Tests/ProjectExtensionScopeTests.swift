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

    // MARK: - Precedence between the two axes

    /// The regression that the per-agent tabs made reachable. Both a record for
    /// this agent and one for every agent can name the same extension in the
    /// same project; the agent's own has to win. A single `first(where:)` over
    /// the mixed list answered with whichever the store happened to hold first,
    /// so the same project could scope differently between two launches.
    func testAnAgentsOwnRecordBeatsTheAllAgentsOne() {
        let allAgents = ProjectBinding(
            extensionID: "codex:figma", projectID: projectA, agent: nil, isEnabled: false
        )
        let forCodex = ProjectBinding(
            extensionID: "codex:figma", projectID: projectA, agent: .codex, isEnabled: true
        )
        // Both orderings, because the bug was an ordering dependency.
        for bindings in [[allAgents, forCodex], [forCodex, allAgents]] {
            XCTAssertTrue(
                ProjectExtensionScope.allows(
                    extensionID: "codex:figma", projectID: projectA,
                    agent: .codex, projectBindings: bindings
                ),
                "codex names it explicitly and must win"
            )
            XCTAssertFalse(
                ProjectExtensionScope.allows(
                    extensionID: "codex:figma", projectID: projectA,
                    agent: .claudeCode, projectBindings: bindings
                ),
                "claude says nothing, so the all-agents rule applies"
            )
        }
    }

    /// A project-scoped record beats a global one on the same agent axis.
    func testThisProjectBeatsTheGlobalRule() {
        let bindings = [
            ProjectBinding(extensionID: "codex:figma", projectID: nil, isEnabled: false),
            ProjectBinding(extensionID: "codex:figma", projectID: projectA, isEnabled: true),
        ]
        XCTAssertTrue(ProjectExtensionScope.allows(
            extensionID: "codex:figma", projectID: projectA,
            agent: .codex, projectBindings: bindings
        ))
        XCTAssertFalse(ProjectExtensionScope.allows(
            extensionID: "codex:figma", projectID: projectB,
            agent: .codex, projectBindings: bindings
        ))
    }

    // MARK: - Selection round-trip

    func testTheSelectionRoundTripsThroughTheStoredRecords() {
        var selection = ProjectExtensionSelection()
        selection.toggle("codex:figma", for: nil)
        selection.toggle("local:drop", for: nil)
        selection.toggle("codex:figma", for: .codex)   // an exception: back on

        let all = selection.bindings(for: nil, projectID: projectA)
        let codex = selection.bindings(for: .codex, projectID: projectA)
        XCTAssertEqual(all.map(\.extensionID), ["codex:figma", "local:drop"])
        XCTAssertTrue(all.allSatisfy { !$0.isEnabled && $0.agent == nil })
        XCTAssertEqual(codex.map(\.extensionID), ["codex:figma"])
        XCTAssertEqual(codex.first?.isEnabled, true)

        let reloaded = ProjectExtensionSelection.load(
            from: all + codex, projectID: projectA
        )
        XCTAssertEqual(reloaded, selection)
        // Another project's records are not this project's selection.
        XCTAssertEqual(
            ProjectExtensionSelection.load(from: all + codex, projectID: projectB),
            ProjectExtensionSelection()
        )
    }

    /// Allowing something is the absence of a record, not a record saying yes.
    /// That is what lets an extension installed tomorrow reach the project.
    func testAllowingSomethingWritesNoRecord() {
        XCTAssertTrue(
            ProjectExtensionSelection().bindings(for: nil, projectID: projectA).isEmpty
        )
    }

    /// An exception that stops being an exception stops being stored, so an
    /// agent goes back to inheriting instead of carrying a record that happens
    /// to agree.
    func testAnAgentGoesBackToInheritingWhenItAgreesAgain() {
        var selection = ProjectExtensionSelection()
        selection.toggle("codex:figma", for: nil)          // off everywhere
        selection.toggle("codex:figma", for: .codex)       // on for Codex
        XCTAssertEqual(selection.opinionCount(for: .codex), 1)
        XCTAssertEqual(
            selection.disagreements(with: "codex:figma", among: [.codex, .claudeCode]),
            [.codex]
        )

        selection.toggle("codex:figma", for: .codex)       // off for Codex again
        XCTAssertEqual(selection.opinionCount(for: .codex), 0)
        XCTAssertTrue(
            selection.bindings(for: .codex, projectID: projectA).isEmpty
        )
        XCTAssertTrue(
            selection.disagreements(with: "codex:figma", among: [.codex]).isEmpty
        )
    }

    /// The selection the picker produces has to mean, at launch, what the
    /// picker showed. This walks the whole path rather than trusting either end.
    func testWhatThePickerShowsIsWhatTheLaunchEnforces() {
        var selection = ProjectExtensionSelection()
        selection.toggle("codex:figma", for: nil)
        selection.toggle("codex:figma", for: .codex)

        let stored = selection.bindings(for: nil, projectID: projectA)
            + selection.bindings(for: .codex, projectID: projectA)

        XCTAssertTrue(selection.isAllowed("codex:figma", for: .codex))
        XCTAssertTrue(ProjectExtensionScope.allows(
            extensionID: "codex:figma", projectID: projectA,
            agent: .codex, projectBindings: stored
        ))

        XCTAssertFalse(selection.isAllowed("codex:figma", for: .claudeCode))
        XCTAssertFalse(ProjectExtensionScope.allows(
            extensionID: "codex:figma", projectID: projectA,
            agent: .claudeCode, projectBindings: stored
        ))
    }

    // MARK: - Getting a long prompt into a session intact

    /// A newline written into a PTY *is* Enter. A blueprint's prompt, or the
    /// brief for an authoring session, is several paragraphs — sent raw it
    /// arrives as several submissions and the agent answers only the last
    /// fragment, which is exactly what it used to do.
    func testAMultiLinePromptIsPastedRatherThanTypedLineByLine() {
        let prompt = "First paragraph.\n\nSecond paragraph.\n\nThird."
        let delivered = TerminalRegistry.deliverable(prompt, bracketedPaste: true)
        XCTAssertTrue(delivered.hasPrefix("\u{1B}[200~"), delivered)
        XCTAssertTrue(delivered.hasSuffix("\u{1B}[201~"), delivered)
        XCTAssertTrue(delivered.contains(prompt), "the text itself must be untouched")
    }

    /// Without the mode there is no way to deliver the shape, so the shape is
    /// what gets given up — not the content.
    func testWithoutBracketedPasteTheNewlinesGoRatherThanTheText() {
        let delivered = TerminalRegistry.deliverable(
            "First paragraph.\n\nSecond paragraph.", bracketedPaste: false
        )
        XCTAssertEqual(delivered, "First paragraph. Second paragraph.")
        XCTAssertFalse(delivered.contains("\n"))
    }

    /// The common case is one line, and it must come out byte-for-byte as it
    /// went in — every existing caller is on this path.
    func testASingleLinePromptIsUntouched() {
        for bracketed in [true, false] {
            XCTAssertEqual(
                TerminalRegistry.deliverable("just one line", bracketedPaste: bracketed),
                "just one line"
            )
        }
    }

    // MARK: - Isolated config roots

    /// A session running on an account profile reads that profile's config, not
    /// `~/.codex`. The decisions are subtractive, so a name resolved from the
    /// wrong file is not a no-op: Codex meets `mcp_servers.supabase` with no
    /// command and refuses the whole config with `invalid transport`.
    @MainActor
    func testRebasingAnInstallationKeepsEachFileName() {
        let account = URL(fileURLWithPath: "/tmp/profiles/codex/work")
        let moved = ProjectScopeService.rebase(installation(), onto: account)
        XCTAssertEqual(moved.configDirectory, account.path)
        XCTAssertEqual(moved.mcpConfigPath, account.appendingPathComponent("config.toml").path)
        XCTAssertEqual(moved.skillsDirectory, account.appendingPathComponent("skills").path)
    }

    @MainActor
    func testRebasingOntoNothingChangesNothing() {
        let detected = installation()
        XCTAssertEqual(ProjectScopeService.rebase(detected, onto: nil), detected)
    }

    /// Claude Code keeps its config in a dotfile beside the root rather than a
    /// named file inside it; moving the root must not rename it.
    @MainActor
    func testRebasingKeepsClaudeCodesDotfileName() {
        var claude = installation(agent: .claudeCode)
        claude.mcpConfigPath = "/Users/someone/.claude.json"
        let moved = ProjectScopeService.rebase(
            claude, onto: URL(fileURLWithPath: "/tmp/profiles/claude/work")
        )
        XCTAssertEqual(moved.mcpConfigPath, "/tmp/profiles/claude/work/.claude.json")
    }

    /// The end of the bug: a profile whose `config.toml` declares nothing
    /// excludes nothing, so no `enabled=false` override is ever produced for a
    /// server that account never had.
    @MainActor
    func testAnAccountWithoutTheServerExcludesNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncoil-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "model = \"gpt-5\"\n".write(
            to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        var adapter = CodexAdapter()
        adapter.binaryPathOverride = "/usr/local/bin/codex"
        let moved = ProjectScopeService.rebase(
            adapter.detectInstallations()[0], onto: root
        )
        let configuration = try adapter.readConfiguration(moved)
        XCTAssertTrue(configuration.mcpServers.isEmpty)
        let scope = ProjectExtensionScope.resolve(
            configuration: configuration,
            packages: [],
            projectBindings: [
                ProjectBinding(
                    extensionID: "codex:supabase", projectID: projectA,
                    agent: .codex, isEnabled: false
                ),
            ],
            projectID: projectA
        )
        XCTAssertTrue(scope.excludedMCPNames.isEmpty)
        XCTAssertTrue(scope.isUnrestricted)
    }

    /// `.terminal` has no configuration to scope, and Amp is not a provider
    /// Uncoil launches — the reverse mapping has to say so rather than guess.
    func testTheProviderToAgentMappingRoundTrips() {
        for agent in ExtensionAgentID.allCases {
            guard let provider = agent.provider else { continue }
            XCTAssertEqual(provider.extensionAgent, agent, agent.rawValue)
        }
        XCTAssertNil(AgentProvider.terminal.extensionAgent)
        XCTAssertNil(ExtensionAgentID.amp.provider)
    }
}
