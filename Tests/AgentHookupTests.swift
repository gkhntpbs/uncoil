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

// MARK: - Locations the user chose

/// A fixed list of eight directories cannot cover every way a CLI gets onto a
/// Mac — nix, pipx, mise, a company image, an install kept on an external disk
/// — so a user can point Uncoil at one. These pin what that promise means.
final class BinarySearchPathUserLocationTests: XCTestCase {
    private let home = "/Users/tester"

    /// Picking the launcher itself is the "I know exactly where it is" answer.
    func testAChosenExecutableIsUsedDirectly() {
        let resolved = BinarySearchPath.resolveUserLocation(
            "/Volumes/Disk/hermes",
            command: "hermes",
            isDirectory: { _ in false },
            isExecutable: { $0 == "/Volumes/Disk/hermes" }
        )
        XCTAssertEqual(resolved, "/Volumes/Disk/hermes")
    }

    func testAChosenDirectoryIsSearchedForTheCommand() {
        let resolved = BinarySearchPath.resolveUserLocation(
            "/Volumes/Disk/tools",
            command: "hermes",
            isDirectory: { $0 == "/Volumes/Disk/tools" },
            isExecutable: { $0 == "/Volumes/Disk/tools/hermes" }
        )
        XCTAssertEqual(resolved, "/Volumes/Disk/tools/hermes")
    }

    /// Pointing at an install root rather than at its `bin` is the mistake
    /// everybody makes once, and it is cheap to forgive.
    func testABinSubdirectoryIsTriedToo() {
        let resolved = BinarySearchPath.resolveUserLocation(
            "/opt/hermes",
            command: "hermes",
            isDirectory: { $0 == "/opt/hermes" },
            isExecutable: { $0 == "/opt/hermes/bin/hermes" }
        )
        XCTAssertEqual(resolved, "/opt/hermes/bin/hermes")
    }

    /// Every directory carries the executable bit, so a folder must never be
    /// mistaken for the binary just because it is named after it.
    func testADirectoryIsNeverItselfTheBinary() {
        XCTAssertNil(
            BinarySearchPath.resolveUserLocation(
                "/opt/hermes",
                command: "hermes",
                isDirectory: { $0 == "/opt/hermes" },
                // The folder itself reads as executable, as every folder does;
                // nothing inside it does.
                isExecutable: { $0 == "/opt/hermes" }
            )
        )
    }

    func testAnEmptyDirectoryResolvesToNothing() {
        XCTAssertNil(
            BinarySearchPath.resolveUserLocation(
                "/opt/empty",
                command: "hermes",
                isDirectory: { $0 == "/opt/empty" },
                isExecutable: { _ in false }
            )
        )
    }

    func testTildeIsExpanded() {
        let resolved = BinarySearchPath.resolveUserLocation(
            "~/tools/hermes",
            command: "hermes",
            isDirectory: { _ in false },
            isExecutable: { !$0.hasPrefix("~") && $0.hasSuffix("/tools/hermes") }
        )
        XCTAssertNotNil(resolved)
        XCTAssertFalse(resolved!.hasPrefix("~"))
    }

    /// They were explicit. An override that lost to whatever happened to be in
    /// `/usr/local/bin` would be a setting that appears to do nothing.
    func testAChosenLocationWinsOverTheFixedList() {
        let path = BinarySearchPath.locate(
            "hermes",
            home: home,
            userLocation: "/Volumes/Disk/hermes",
            isDirectory: { _ in false },
            isExecutable: { _ in true }
        )
        XCTAssertEqual(path, "/Volumes/Disk/hermes")
    }

    /// Ejecting a drive must not make an agent that is also installed normally
    /// disappear from every screen.
    func testAnUnreachableChosenLocationFallsBackToTheUsualSearch() {
        let path = BinarySearchPath.locate(
            "hermes",
            home: home,
            userLocation: "/Volumes/Ejected/hermes",
            isDirectory: { _ in false },
            isExecutable: { $0 == "\(self.home)/.local/bin/hermes" }
        )
        XCTAssertEqual(path, "\(home)/.local/bin/hermes")
    }

    func testTheRegisteredLocationsAreWhatLocateConsults() {
        defer { BinarySearchPath.setUserLocations([:]) }
        BinarySearchPath.setUserLocations(["hermes": "/Volumes/Disk/hermes"])
        XCTAssertEqual(BinarySearchPath.userLocation(for: "hermes"), "/Volumes/Disk/hermes")
        XCTAssertNil(BinarySearchPath.userLocation(for: "codex"))
        XCTAssertEqual(
            BinarySearchPath.locate(
                "hermes", home: home, isDirectory: { _ in false }, isExecutable: { _ in true }
            ),
            "/Volumes/Disk/hermes"
        )
        BinarySearchPath.setUserLocations([:])
        XCTAssertNil(BinarySearchPath.userLocation(for: "hermes"))
    }

    /// Nothing chosen is trivially reachable; the question only bites once
    /// somebody has answered it.
    func testReachabilityIsTrueWhenNothingWasChosen() {
        BinarySearchPath.setUserLocations([:])
        XCTAssertTrue(BinarySearchPath.userLocationIsReachable(for: "hermes"))
    }

    func testReachabilityIsFalseForALocationThatWentAway() {
        defer { BinarySearchPath.setUserLocations([:]) }
        BinarySearchPath.setUserLocations(
            ["hermes": "/Volumes/NoSuchDisk-\(UUID().uuidString)/hermes"]
        )
        XCTAssertFalse(BinarySearchPath.userLocationIsReachable(for: "hermes"))
    }
}

// MARK: - Integration levels

final class AgentIntegrationLevelTests: XCTestCase {
    func testLevelsAreOrderedFromLeastToMostCapable() {
        XCTAssertLessThan(AgentIntegrationLevel.none, .observed)
        XCTAssertLessThan(AgentIntegrationLevel.observed, .controlPlane)
        XCTAssertLessThan(AgentIntegrationLevel.controlPlane, .hooks)
    }

    /// The two agents that actually publish a hook system, and nobody else.
    ///
    /// This started out as "only Claude Code", which was true until Hermes was
    /// read: it fires `on_session_start`, `pre_tool_call`, `on_session_end` and
    /// `subagent_stop`, each handed a JSON payload on stdin carrying a
    /// `session_id`, each able to block the call or inject context from what it
    /// writes back. That is the same capability, so the ceiling says so. What
    /// separates the two is `isAutomatic`, which the next test pins.
    func testOnlyAgentsWithARealHookSystemReachLiveEvents() {
        let hookCapable: Set<ExtensionAgentID> = [.claudeCode, .hermes]
        for agent in ExtensionAgentID.allCases {
            let ceiling = AgentIntegrationSupport.forAgent(agent).ceiling
            if hookCapable.contains(agent) {
                XCTAssertEqual(ceiling, .hooks, "\(agent.displayName) has a hook system")
            } else {
                XCTAssertLessThan(
                    ceiling, .hooks,
                    "\(agent.displayName) claims a hook system it does not have"
                )
            }
        }
    }

    /// Both hook-capable agents are wired by Uncoil rather than by hand, and an
    /// agent that reaches `.hooks` but cannot be connected would be a row
    /// offering a level with no way to get there.
    func testEveryHookCapableAgentCanBeWiredByUncoil() {
        for agent in ExtensionAgentID.allCases {
            let support = AgentIntegrationSupport.forAgent(agent)
            guard support.ceiling == .hooks else { continue }
            XCTAssertTrue(
                support.isAutomatic,
                "\(agent.displayName) reaches live events with no way to get there"
            )
            XCTAssertNil(support.ceilingReason, agent.displayName)
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
