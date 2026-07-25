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
            for: record, binaryPath: "/usr/local/bin/claude", extraArguments: nil,
            modeArguments: ["--permission-mode", "manual"]
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
            for: record, binaryPath: "/usr/local/bin/claude", extraArguments: nil,
            modeArguments: ["--permission-mode", "manual"]
        )
        XCTAssertNotNil(command)
        XCTAssertTrue(command!.contains("plan"), command!)
        XCTAssertFalse(command!.contains("manual"), command!)
    }
}
