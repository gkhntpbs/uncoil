import XCTest
@testable import Uncoil

// MARK: - Search path

final class BinarySearchPathTests: XCTestCase {
    private let home = "/Users/tester"

    func testSearchPathCoversEveryLocationTheOldThreeListsKnew() {
        let directories = BinarySearchPath.directories(home: home)
        // The union is the whole point: before this existed, an install under
        // ~/.volta/bin was visible to Extensions and invisible to session
        // launch, and ~/.npm-global/bin the other way round.
        for expected in [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ] {
            XCTAssertTrue(
                directories.contains(expected),
                "\(expected) missing from the shared search path"
            )
        }
    }

    func testUserLocalInstallsWinOverSystemOnes() {
        let directories = BinarySearchPath.directories(home: home)
        let local = directories.firstIndex(of: "\(home)/.local/bin")
        let system = directories.firstIndex(of: "/usr/local/bin")
        XCTAssertNotNil(local)
        XCTAssertNotNil(system)
        XCTAssertLessThan(local!, system!)
    }

    func testLocateReturnsFirstExecutableMatch() {
        let path = BinarySearchPath.locate("claude", home: home) { candidate in
            candidate == "/usr/local/bin/claude" || candidate == "\(home)/.local/bin/claude"
        }
        XCTAssertEqual(path, "\(home)/.local/bin/claude")
    }

    func testLocatePrefersExtraDirectoriesOverEverythingElse() {
        let path = BinarySearchPath.locate(
            "codex",
            home: home,
            extraDirectories: ["/opt/custom/bin"]
        ) { _ in true }
        XCTAssertEqual(path, "/opt/custom/bin/codex")
    }

    func testLocateReturnsNilWhenNothingIsExecutable() {
        XCTAssertNil(BinarySearchPath.locate("nope", home: home) { _ in false })
    }
}

// MARK: - Integration levels

final class AgentIntegrationLevelTests: XCTestCase {
    func testLevelsAreOrderedFromLeastToMostCapable() {
        XCTAssertLessThan(AgentIntegrationLevel.none, .observed)
        XCTAssertLessThan(AgentIntegrationLevel.observed, .controlPlane)
        XCTAssertLessThan(AgentIntegrationLevel.controlPlane, .hooks)
    }

    func testOnlyClaudeCodeReachesLiveEvents() {
        XCTAssertEqual(AgentIntegrationSupport.forAgent(.claudeCode).ceiling, .hooks)
        for agent in ExtensionAgentID.allCases where agent != .claudeCode {
            XCTAssertLessThan(
                AgentIntegrationSupport.forAgent(agent).ceiling,
                .hooks,
                "\(agent.displayName) claims a hook system it does not have"
            )
        }
    }

    func testEveryCeilingBelowHooksExplainsItself() {
        for agent in ExtensionAgentID.allCases {
            let support = AgentIntegrationSupport.forAgent(agent)
            if support.ceiling < .hooks {
                XCTAssertNotNil(
                    support.ceilingReason,
                    "\(agent.displayName) is capped with no explanation for the user"
                )
            }
        }
    }

    func testSupportTableMatchesWhatTheAppActuallyWires() {
        // The table is a claim about the rest of the app; if `wiresControlPlane`
        // changes, this is what catches the table drifting away from it.
        for agent in ExtensionAgentID.allCases {
            guard let provider = agent.provider, provider.wiresControlPlane else { continue }
            XCTAssertGreaterThanOrEqual(
                AgentIntegrationSupport.forAgent(agent).ceiling,
                .controlPlane,
                "\(agent.displayName) wires the control plane but is capped below it"
            )
        }
    }
}

// MARK: - Hook-capable decision table

final class AgentIntegrationStateTests: XCTestCase {
    private func installation(_ agent: ExtensionAgentID) -> AgentInstallation {
        AgentInstallation(
            agent: agent,
            binaryPath: "/usr/local/bin/\(agent.rawValue)",
            configDirectory: "/Users/tester/.\(agent.rawValue)",
            skillsDirectory: nil,
            mcpConfigPath: nil,
            version: nil,
            isAuthenticated: nil,
            detectedAt: .distantPast
        )
    }

    func testUninstalledAgentHasNothingToDo() {
        let state = AgentIntegrationState.forHookCapableAgent(
            .claudeCode,
            installation: nil,
            hookStatus: .notInstalled,
            hasStaleCommands: false
        )
        XCTAssertFalse(state.isInstalled)
        XCTAssertEqual(state.active, AgentIntegrationLevel.none)
        XCTAssertNil(state.pendingAction)
        // Never offer to connect something that is not there.
        XCTAssertFalse(state.isFullyWired)
    }

    func testInstalledWithoutHooksIsObservedAndOffersToConnect() {
        let state = AgentIntegrationState.forHookCapableAgent(
            .claudeCode,
            installation: installation(.claudeCode),
            hookStatus: .notInstalled,
            hasStaleCommands: false
        )
        XCTAssertEqual(state.active, .observed)
        XCTAssertEqual(state.pendingAction, .installHooks)
        XCTAssertFalse(state.isFullyWired)
    }

    func testFullyHookedAgentIsWiredAndHasNoPendingAction() {
        let state = AgentIntegrationState.forHookCapableAgent(
            .claudeCode,
            installation: installation(.claudeCode),
            hookStatus: .installed,
            hasStaleCommands: false
        )
        XCTAssertEqual(state.active, .hooks)
        XCTAssertNil(state.pendingAction)
        XCTAssertTrue(state.isFullyWired)
    }

    func testPartialInstallReportsWhichEventsAreMissing() {
        let state = AgentIntegrationState.forHookCapableAgent(
            .claudeCode,
            installation: installation(.claudeCode),
            hookStatus: .partiallyInstalled(missing: ["Stop", "SessionEnd"]),
            hasStaleCommands: false
        )
        XCTAssertEqual(state.pendingAction, .completeHooks(missing: ["Stop", "SessionEnd"]))
        // A half-installed hook set cannot be trusted for state, so the level
        // must not claim `.hooks`.
        XCTAssertEqual(state.active, .observed)
    }

    func testStalePathOutranksAnApparentlyCompleteInstall() {
        // The hooks are all present, so `status()` says installed — but they
        // name a helper that is gone, and every tool call logs a failure.
        // Repair has to win, otherwise the row reads "connected" while broken.
        let state = AgentIntegrationState.forHookCapableAgent(
            .claudeCode,
            installation: installation(.claudeCode),
            hookStatus: .installed,
            hasStaleCommands: true
        )
        XCTAssertEqual(state.pendingAction, .repairHooks)
        XCTAssertEqual(state.active, .observed)
        XCTAssertFalse(state.isFullyWired)
    }

    // MARK: Hookless agents

    func testCodexIsControlPlaneWithoutAnySetup() {
        // Uncoil registers its MCP server per session for Codex, so this is
        // true on a machine whose ~/.codex/config.toml never mentions Uncoil.
        let state = AgentIntegrationState.forHooklessAgent(
            .codex,
            installation: installation(.codex),
            hasUncoilMCPServer: false
        )
        XCTAssertEqual(state.active, .controlPlane)
        XCTAssertTrue(state.isFullyWired)
        XCTAssertNil(state.pendingAction)
    }

    func testGeminiIsOnlyObservedEvenThoughItIsLaunchable() {
        let state = AgentIntegrationState.forHooklessAgent(
            .geminiCLI,
            installation: installation(.geminiCLI),
            hasUncoilMCPServer: false
        )
        XCTAssertEqual(state.active, .observed)
        XCTAssertTrue(state.isFullyWired, "observed is Gemini's ceiling, so it is done")
    }

    func testActiveLevelNeverRisesAboveTheCeiling() {
        // A Gemini config can name Uncoil's MCP server, but no session serves
        // it — the server only answers "control plane unavailable". Claiming
        // the level off the config entry would advertise tools that don't work.
        let state = AgentIntegrationState.forHooklessAgent(
            .geminiCLI,
            installation: installation(.geminiCLI),
            hasUncoilMCPServer: true
        )
        XCTAssertEqual(state.active, .observed)
    }

    func testAgentAtADetectedOnlyCeilingIsNeverCountedAsWired() {
        // Tests the rule rather than a particular agent: no shipped agent sits
        // at this ceiling today, but one added tomorrow must not be tallied as
        // "fully connected" just for being at a ceiling of nothing.
        let state = AgentIntegrationState(
            agent: .grok,
            installation: installation(.grok),
            support: AgentIntegrationSupport(
                ceiling: .none, isAutomatic: true, ceilingReason: "not supported"
            ),
            active: .none,
            pendingAction: nil
        )
        XCTAssertFalse(state.isFullyWired)
    }

    func testUninstalledHooklessAgentIsInert() {
        for agent in ExtensionAgentID.allCases where agent != .claudeCode {
            let state = AgentIntegrationState.forHooklessAgent(
                agent,
                installation: nil,
                hasUncoilMCPServer: true
            )
            XCTAssertEqual(state.active, AgentIntegrationLevel.none)
            XCTAssertNil(state.pendingAction)
        }
    }
}
