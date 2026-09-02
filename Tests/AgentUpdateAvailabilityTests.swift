import XCTest
@testable import Uncoil

/// Who gets asked what the newest version is.
///
/// The whole point of the type: asking the wrong channel is how a row came to
/// advertise an update the button could not deliver.
final class AgentVersionSourceTests: XCTestCase {
    func testAHomebrewInstallIsAskedOfHomebrew() {
        XCTAssertEqual(
            AgentUpdateCheck.versionSource(
                provider: .codex, source: .homebrew(formula: "codex", isCask: true)
            ),
            .homebrew(name: "codex")
        )
    }

    func testAnNpmInstallIsAskedOfNpm() {
        XCTAssertEqual(
            AgentUpdateCheck.versionSource(provider: .gemini, source: .npm(prefix: nil)),
            .npm(package: "@google/gemini-cli")
        )
    }

    /// Volta installs npm packages, so npm is still the right place to ask.
    func testVoltaIsAskedOfNpm() {
        XCTAssertEqual(
            AgentUpdateCheck.versionSource(provider: .gemini, source: .volta),
            .npm(package: "@google/gemini-cli")
        )
    }

    /// The bug this type exists for: Codex is published on npm *and* packaged
    /// as a Homebrew cask, and the two release on their own schedules. Reading
    /// npm for a cask install is what produced "new: 0.152.1" over a button
    /// that ran `brew upgrade` and found nothing newer.
    func testACaskInstallIsNeverAskedOfNpm() {
        XCTAssertNotEqual(
            AgentUpdateCheck.versionSource(
                provider: .codex, source: .homebrew(formula: "codex", isCask: true)
            ),
            .npm(package: "@openai/codex")
        )
    }

    /// Cursor and Hermes publish no version list Uncoil can read, and the npm
    /// packages that share their names are other people's software.
    func testASelfInstallingToolHasNoVersionSource() {
        for provider in [AgentProvider.cursor, .hermes] {
            XCTAssertEqual(
                AgentUpdateCheck.versionSource(provider: provider, source: .nativeInstaller),
                .none,
                "\(provider.rawValue) has nothing to ask"
            )
        }
    }

    /// Grok will not be found in a registry, but it answers the question
    /// itself. Read off the installed CLI's own help, and its output checked:
    /// `grok update --check --json` prints `latestVersion`.
    func testGrokIsAskedOfItself() {
        XCTAssertEqual(
            AgentUpdateCheck.versionSource(provider: .grok, source: .nativeInstaller),
            .selfReport(arguments: ["update", "--check", "--json"])
        )
    }

    /// Claude is the exception, and a real one: Anthropic publishes the same
    /// release to npm and to the installer `claude update` uses.
    func testClaudesOwnInstallerIsStillAnsweredByNpm() {
        XCTAssertEqual(
            AgentUpdateCheck.versionSource(provider: .claude, source: .nativeInstaller),
            .npm(package: "@anthropic-ai/claude-code")
        )
    }
}

/// What a row says, and whether it offers a button.
final class AgentUpdateAvailabilityTests: XCTestCase {
    private func availability(
        installed: String?,
        latest: String?,
        plan: AgentUpdatePlan = .run("brew upgrade x"),
        versionSource: AgentVersionSource = .npm(package: "x")
    ) -> AgentUpdateAvailability {
        AgentUpdateCheck.availability(
            installed: installed,
            latest: latest,
            plan: plan,
            versionSource: versionSource,
            isNewer: CLIToolService.isNewer
        )
    }

    func testANewerVersionIsOffered() {
        XCTAssertEqual(
            availability(installed: "0.53.1", latest: "0.58.0"),
            .available(installed: "0.53.1", latest: "0.58.0")
        )
    }

    func testTheSameVersionIsUpToDate() {
        XCTAssertEqual(
            availability(installed: "1.18.26", latest: "1.18.26"),
            .upToDate(installed: "1.18.26")
        )
    }

    /// Only a version Uncoil has actually seen counts. A tool that can only be
    /// asked by running its updater would otherwise sit in the badge forever.
    func testOnlyAKnownNewerVersionIsPending() {
        XCTAssertTrue(availability(installed: "1.0.0", latest: "1.1.0").isPending)
        XCTAssertFalse(availability(installed: "1.0.0", latest: "1.0.0").isPending)
        XCTAssertFalse(
            availability(installed: "1.0.0", latest: nil, versionSource: .none).isPending
        )
    }

    /// The four self-updating agents had no button at all, because the only
    /// thing that produced one was a version comparison they could not take
    /// part in.
    func testAToolWithNoVersionSourceIsStillOfferedAnUpdate() {
        let state = availability(installed: "1.0.4", latest: nil, versionSource: .none)
        XCTAssertEqual(state, .selfChecking)
        XCTAssertTrue(state.isActionable)
    }

    /// "Up to date" is a claim. Before the check comes back there is nothing
    /// to claim.
    func testAnAnswerThatHasNotArrivedIsNotUpToDate() {
        XCTAssertEqual(availability(installed: "1.0.0", latest: nil), .unchecked)
    }

    func testNotInstalledOutranksEverything() {
        XCTAssertEqual(availability(installed: nil, latest: "2.0.0"), .notInstalled)
    }

    /// A row with no runnable command must not offer one, whatever the
    /// registry says.
    func testNoUpdaterMeansNoButton() {
        let state = availability(
            installed: "1.0.0", latest: "2.0.0", plan: .cannot("no idea how this got here")
        )
        XCTAssertEqual(state, .noUpdater(reason: "no idea how this got here"))
        XCTAssertFalse(state.isActionable)
        XCTAssertFalse(state.isPending)
    }
}

/// Reading `brew outdated --json=v2`.
final class HomebrewOutdatedTests: XCTestCase {
    private let sample = Data("""
    {
      "formulae": [
        {"name": "opencode", "installed_versions": ["1.18.0"], "current_version": "1.18.26"}
      ],
      "casks": [
        {"name": "codex", "installed_versions": ["0.151.0"], "current_version": "0.152.0"}
      ]
    }
    """.utf8)

    /// Both are folded into one table: which of the two a tool is matters for
    /// the upgrade command, not for whether something newer exists.
    func testFormulaeAndCasksAreBothRead() {
        let latest = HomebrewOutdated.parse(sample)
        XCTAssertEqual(latest["opencode"], "1.18.26")
        XCTAssertEqual(latest["codex"], "0.152.0")
    }

    /// A package from a third-party tap is reported under its qualified name.
    /// Looking it up by the bare name is what the rest of the app has.
    func testATapQualifiedNameIsAlsoFiledUnderItsBareName() {
        let tapped = Data("""
        {"formulae": [{"name": "anomalyco/tap/opencode", "current_version": "1.19.0"}], "casks": []}
        """.utf8)
        let latest = HomebrewOutdated.parse(tapped)
        XCTAssertEqual(latest["opencode"], "1.19.0")
        XCTAssertEqual(latest["anomalyco/tap/opencode"], "1.19.0")
    }

    func testNonsenseIsEmptyRatherThanACrash() {
        XCTAssertTrue(HomebrewOutdated.parse(Data("not json".utf8)).isEmpty)
    }
}

/// Which sessions a "restart this agent" would touch.
final class AgentProcessRestartTests: XCTestCase {
    private func session(_ provider: AgentProvider) -> SessionRecord {
        SessionRecord(
            projectID: UUID(),
            provider: provider,
            accountID: nil,
            title: "s"
        )
    }

    func testOnlyThisAgentsSessionsAreRestarted() {
        let claude = session(.claude)
        let codex = session(.codex)
        XCTAssertEqual(
            AgentProcessRestart.targets(
                sessions: [claude, codex],
                provider: .claude,
                isLive: { _ in true },
                isAsleep: { _ in false }
            ),
            [claude.id]
        )
    }

    func testASessionWithNoProcessIsNotRestarted() {
        let claude = session(.claude)
        XCTAssertTrue(
            AgentProcessRestart.targets(
                sessions: [claude],
                provider: .claude,
                isLive: { _ in false },
                isAsleep: { _ in false }
            ).isEmpty
        )
    }

    /// Hibernation already killed the process; it comes back on the new
    /// version when it is next opened. Waking every sleeping session to
    /// restart it would undo what the user asked for by putting it to sleep.
    func testASleepingSessionIsLeftAsleep() {
        let claude = session(.claude)
        XCTAssertTrue(
            AgentProcessRestart.targets(
                sessions: [claude],
                provider: .claude,
                isLive: { _ in true },
                isAsleep: { _ in true }
            ).isEmpty
        )
    }

    func testNothingRunningOffersNothing() {
        XCTAssertNil(AgentProcessRestart.offer(count: 0, provider: .claude))
        XCTAssertNotNil(AgentProcessRestart.offer(count: 2, provider: .claude))
    }
}


/// A tool's own answer, read back.
final class SelfReportedUpdateTests: XCTestCase {
    /// The shape `grok update --check --json` actually prints, copied from a
    /// real run rather than imagined.
    func testGroksAnswerIsRead() {
        let output = Data(
            #"{"currentVersion":"1.0.4","latestVersion":"1.0.13","updateAvailable":true}"#.utf8
        )
        XCTAssertEqual(SelfReportedUpdate.latestVersion(output), "1.0.13")
    }

    /// There is no convention across vendors here, only JSON with a version in
    /// it somewhere.
    func testTheSnakeCaseSpellingIsAlsoAccepted() {
        XCTAssertEqual(
            SelfReportedUpdate.latestVersion(Data(#"{"latest_version": "2.0.0"}"#.utf8)),
            "2.0.0"
        )
    }

    func testAnUnreadableAnswerIsNoAnswer() {
        XCTAssertNil(SelfReportedUpdate.latestVersion(Data("up to date!".utf8)))
        XCTAssertNil(SelfReportedUpdate.latestVersion(Data(#"{"latestVersion": ""}"#.utf8)))
    }
}


/// The version strings these CLIs actually print, compared.
///
/// Every one of these was read off the installed tool rather than invented,
/// because the comparison is only worth anything if it survives the vendors'
/// own formatting — and each of the seven formats it differently.
final class AgentVersionStringTests: XCTestCase {
    func testEachAgentsOwnVersionStringIsUnderstood() {
        let printed: [(String, [Int])] = [
            ("2.1.252 (Claude Code)", [2, 1, 252]),
            ("codex-cli 0.152.0", [0, 152, 0]),
            ("0.53.1", [0, 53, 1]),
            ("1.18.26", [1, 18, 26]),
            ("grok 1.0.4 (d846eb93d94d) [stable]", [1, 0, 4]),
            ("2026.08.11-e8db854", [2026, 8, 11]),
            ("Hermes Agent v0.20.4 (2026.8.18)", [0, 20, 4]),
        ]
        for (string, expected) in printed {
            XCTAssertEqual(CLIToolService.semver(string), expected, string)
        }
    }

    /// Homebrew answers with a bare number and the tool answers with a
    /// sentence. When Homebrew has nothing newer the two are compared
    /// directly, so they have to agree.
    func testABareHomebrewVersionMatchesTheToolsOwnSentence() {
        XCTAssertFalse(CLIToolService.isNewer("0.152.0", than: "codex-cli 0.152.0"))
        XCTAssertTrue(CLIToolService.isNewer("0.153.0", than: "codex-cli 0.152.0"))
    }
}
