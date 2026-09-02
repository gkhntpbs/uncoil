import XCTest
@testable import Uncoil

final class AgentLaunchOptionsTests: XCTestCase {
    private let claudeHelp = """
      --effort <level>                      Effort level for the current session
                                            (low, medium, high, xhigh, max)
      --model <model>                       Model for the current session.
      --permission-mode <mode>              Permission mode to use
    """

    private let codexHelp = """
      -m, --model <MODEL>
              Model the agent should use
      -s, --sandbox <SANDBOX_MODE>
    """

    // MARK: - Detection from real CLI output shapes

    func testClaudeCapabilitiesComeFromItsHelpText() {
        let caps = AgentLaunchCatalog.capabilities(for: .claude, helpText: claudeHelp)
        XCTAssertEqual(caps.models.map(\.id), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(caps.efforts.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(caps.workingModes, AgentWorkingMode.options(for: .claude))
    }

    /// An older build without the flags gets no picker instead of a guessed one.
    func testAClaudeBuildWithoutTheFlagsOffersNothing() {
        let caps = AgentLaunchCatalog.capabilities(for: .claude, helpText: "usage: claude")
        XCTAssertTrue(caps.models.isEmpty)
        XCTAssertTrue(caps.efforts.isEmpty)
    }

    func testCodexDefaultModelIsReadFromItsOwnConfig() {
        let config = """
        codex_hooks = true
        model = "gpt-5.6-sol"
        model_reasoning_effort = "low"

        [projects."/x"]
        model = "not-this-one"
        """
        let caps = AgentLaunchCatalog.capabilities(
            for: .codex, helpText: codexHelp, codexConfig: config
        )
        XCTAssertEqual(caps.models.map(\.id), ["gpt-5.6-sol"])
        XCTAssertEqual(caps.defaultModelDetail, "gpt-5.6-sol")
        XCTAssertEqual(caps.efforts.map(\.id), ["minimal", "low", "medium", "high", "xhigh"])
    }

    func testASectionNeverLeaksItsModelAsTheTopLevelOne() {
        let config = "[projects.\"/x\"]\nmodel = \"wrong\"\n"
        XCTAssertNil(AgentLaunchCatalog.codexConfigValue(config, key: "model"))
    }

    // MARK: - Arguments

    func testClaudeArgumentsUseItsOwnFlags() {
        let arguments = AgentLaunchCatalog.launchArguments(
            for: .claude,
            selection: AgentLaunchSelection(model: "opus", effort: "high", workingMode: .plan)
        )
        XCTAssertEqual(
            arguments,
            ["--model", "opus", "--effort", "high", "--permission-mode", "plan"]
        )
    }

    func testCodexEffortGoesThroughConfigNotAFlag() {
        let arguments = AgentLaunchCatalog.launchArguments(
            for: .codex,
            selection: AgentLaunchSelection(model: "gpt-5.6-sol", effort: "xhigh", workingMode: .fullAccess)
        )
        XCTAssertEqual(
            arguments,
            [
                "-m", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=\"xhigh\"",
                "--sandbox", "danger-full-access", "--ask-for-approval", "never",
            ]
        )
    }

    func testTheDefaultSelectionAddsNoFlagsAtAll() {
        XCTAssertEqual(
            AgentLaunchCatalog.launchArguments(for: .claude, selection: .providerDefault), []
        )
        XCTAssertEqual(
            AgentLaunchCatalog.launchArguments(for: .codex, selection: .providerDefault), []
        )
        XCTAssertTrue(AgentLaunchSelection.providerDefault.isDefault)
        XCTAssertNil(AgentLaunchSelection.providerDefault.summary)
    }

    /// A Claude-only mode picked while Codex is the provider is normalized, not
    /// passed through as a flag Codex would reject.
    func testAForeignModeIsNormalizedForTheProvider() {
        let arguments = AgentLaunchCatalog.launchArguments(
            for: .codex,
            selection: AgentLaunchSelection(workingMode: .auto)
        )
        XCTAssertEqual(
            arguments,
            ["--sandbox", "workspace-write", "--ask-for-approval", "never"]
        )
    }

    // MARK: - Launch command composition

    func testTheSelectionRidesTheLaunchCommand() {
        var record = SessionRecord(
            projectID: UUID(), provider: .claude, accountID: nil, title: "t"
        )
        record.launchSelection = AgentLaunchSelection(model: "sonnet", effort: "low")
        let command = TerminalRegistry.launchCommand(
            for: record, binaryPath: "/usr/local/bin/claude", resume: .fresh(nil),
            extraArguments: nil, modeArguments: ["--permission-mode", "manual"]
        )
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("--model") && command!.contains("sonnet"), command!)
        XCTAssertTrue(command!.contains("--effort") && command!.contains("low"), command!)
        // No mode in the selection: the settings-wide mode flags stay.
        XCTAssertTrue(command!.contains("--permission-mode"), command!)
    }

    func testASelectionModeReplacesTheSettingsMode() {
        var record = SessionRecord(
            projectID: UUID(), provider: .claude, accountID: nil, title: "t"
        )
        record.launchSelection = AgentLaunchSelection(workingMode: .plan)
        let command = TerminalRegistry.launchCommand(
            for: record, binaryPath: "/usr/local/bin/claude", resume: .fresh(nil),
            extraArguments: nil, modeArguments: ["--permission-mode", "manual"]
        )
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("plan"), command!)
        XCTAssertFalse(command!.contains("manual"), command!)
    }

    // MARK: - Codex approval

    /// The flags and the app-server fields are two spellings of one choice,
    /// and they had drifted: everything the app server did not name fell
    /// through to workspace-write. Read Only could therefore write, which is
    /// the one thing its name promises it cannot.
    func testTheAppServerAndTheFlagsAgreeOnEveryMode() {
        let expected: [AgentWorkingMode: [String]] = [
            .readOnly: ["read-only", "on-request"],
            .askForApproval: ["workspace-write", "on-request"],
            .approveForMe: ["workspace-write", "never"],
            .fullAccess: ["danger-full-access", "never"],
        ]
        for (mode, pair) in expected {
            let flags = mode.launchArguments(for: .codex)
            XCTAssertEqual(flags, ["--sandbox", pair[0], "--ask-for-approval", pair[1]], "\(mode)")
            let served = AgentLaunchCatalog.codexApproval(mode: mode, config: nil)
            XCTAssertEqual(served.sandbox, pair[0], "\(mode)")
            XCTAssertEqual(served.approvalPolicy, pair[1], "\(mode)")
        }
    }

    /// "The provider's own settings" has to mean the user's file, not Uncoil's
    /// idea of a sensible pair.
    func testProviderDefaultTakesTheUsersOwnCodexConfig() {
        let config = """
        model = "gpt-5.6-sol"
        approval_policy = "never"
        sandbox_mode = "danger-full-access"

        [projects."/repo"]
        trust_level = "trusted"
        """
        let served = AgentLaunchCatalog.codexApproval(mode: .providerDefault, config: config)
        XCTAssertEqual(served.approvalPolicy, "never")
        XCTAssertEqual(served.sandbox, "danger-full-access")
        // And adds no flags at all on the command-line path.
        XCTAssertTrue(AgentWorkingMode.providerDefault.launchArguments(for: .codex).isEmpty)
    }

    /// A config that says nothing keeps the pair Uncoil sent before there was
    /// a way to ask it to leave the choice alone.
    func testAnEmptyCodexConfigFallsBackToTheConservativePair() {
        let served = AgentLaunchCatalog.codexApproval(mode: .providerDefault, config: nil)
        XCTAssertEqual(served.approvalPolicy, "on-request")
        XCTAssertEqual(served.sandbox, "workspace-write")
    }

    // MARK: - Hermes

    /// Hermes names its reasoning levels in prose rather than in parentheses,
    /// and argparse wraps the sentence across lines. Verbatim from
    /// `hermes --help`, wrapping and all.
    func testHermesReasoningLevelsAreReadFromItsOwnHelpText() {
        let help = """
          --reasoning LEVEL     Reasoning effort for this invocation: none, minimal,
                                low, medium, high, xhigh, max, or ultra. Overrides
                                agent.reasoning_effort in config.yaml for this run
                                only.
        """
        XCTAssertEqual(
            AgentLaunchCatalog.reasoningLevels(fromHelp: help),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
    }

    /// No picker beats a picker offering a level the CLI would reject.
    func testHermesOffersNoEffortsWhenTheFlagIsAbsent() {
        let capabilities = AgentLaunchCatalog.capabilities(
            for: .hermes, helpText: "usage: hermes [-h] [--version]"
        )
        XCTAssertTrue(capabilities.efforts.isEmpty)
        // Its model ids are `provider/model` from the account's own providers,
        // so no list is offered on any machine.
        XCTAssertTrue(capabilities.models.isEmpty)
    }

    func testHermesPassesTheFlagsItsHelpDocuments() {
        let arguments = AgentLaunchCatalog.launchArguments(
            for: .hermes,
            selection: AgentLaunchSelection(
                model: "anthropic/claude-sonnet-4.6",
                effort: "high",
                workingMode: .dangerouslySkipPermissions
            )
        )
        XCTAssertEqual(
            arguments,
            ["-m", "anthropic/claude-sonnet-4.6", "--reasoning", "high", "--yolo"]
        )
    }
}
