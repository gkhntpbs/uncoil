import XCTest
@testable import Uncoil

/// How an agent CLI was installed, and therefore how it is updated.
///
/// The paths below are real ones, taken off a Mac with all three agents on it
/// by three different routes. Invented paths would have kept passing against
/// the detection that shipped broken: `~/.nvm/versions/node/v24.1.0/bin/gemini`
/// contains none of the substrings that version looked for.
final class AgentInstallSourceTests: XCTestCase {
    private let nvmLauncher = "/Users/x/.nvm/versions/node/v24.1.0/bin/gemini"
    private let nvmPackage =
        "/Users/x/.nvm/versions/node/v24.1.0/lib/node_modules/@google/gemini-cli/bundle/gemini.js"

    // MARK: - npm under a version manager

    /// The bug: this read as `.unknown`, and an unknown install had no update
    /// command at all.
    func testAnNpmPackageUnderNvmIsRecognisedAsNpm() {
        XCTAssertEqual(
            AgentCLIInstall.source(
                path: nvmLauncher, resolvedPath: nvmPackage, provider: .gemini
            ),
            .npm(prefix: "/Users/x/.nvm/versions/node/v24.1.0")
        )
    }

    /// The prefix is the whole point: it names the Node whose npm owns this
    /// copy, so the update goes back where the binary came from.
    func testThePrefixIsTheNodeThePackageBelongsTo() {
        XCTAssertEqual(
            AgentCLIInstall.npmPrefix(fromPackagePath: nvmPackage),
            "/Users/x/.nvm/versions/node/v24.1.0"
        )
    }

    func testAPathWithNoPackageDirectoryHasNoPrefix() {
        XCTAssertNil(AgentCLIInstall.npmPrefix(fromPackagePath: "/opt/homebrew/bin/codex"))
    }

    /// A launcher whose symlink cannot be followed still has to be placed, and
    /// a version manager's bin directory says enough on its own.
    func testAVersionManagerLauncherIsPlacedWithoutFollowingTheSymlink() {
        XCTAssertEqual(
            AgentCLIInstall.source(path: nvmLauncher, resolvedPath: nil, provider: .gemini),
            .npm(prefix: "/Users/x/.nvm/versions/node/v24.1.0")
        )
    }

    func testFnmAndAsdfLayoutsAreRecognisedToo() {
        XCTAssertEqual(
            AgentCLIInstall.nodeManagerPrefix(
                binaryPath: "/Users/x/Library/fnm/node-versions/v22.0.0/installation/bin/gemini"
            ),
            "/Users/x/Library/fnm/node-versions/v22.0.0/installation"
        )
        XCTAssertEqual(
            AgentCLIInstall.nodeManagerPrefix(
                binaryPath: "/Users/x/.asdf/installs/nodejs/22.0.0/bin/gemini"
            ),
            "/Users/x/.asdf/installs/nodejs/22.0.0"
        )
    }

    // MARK: - Homebrew

    func testAHomebrewCaskIsRecognised() {
        XCTAssertEqual(
            AgentCLIInstall.source(
                path: "/opt/homebrew/bin/codex",
                resolvedPath: "/opt/homebrew/Caskroom/codex/0.146.0/bin/codex",
                provider: .codex
            ),
            .homebrew(formula: "codex")
        )
    }

    /// An npm global installed under Homebrew's Node lives inside Homebrew's
    /// tree and `brew upgrade` cannot touch it. Checking the prefix first is
    /// what used to get this wrong.
    func testAnNpmPackageInsideHomebrewsTreeIsStillNpm() {
        XCTAssertEqual(
            AgentCLIInstall.source(
                path: "/opt/homebrew/bin/gemini",
                resolvedPath: "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/gemini.js",
                provider: .gemini
            ),
            .npm(prefix: "/opt/homebrew")
        )
    }

    /// `brew upgrade gemini` and `brew upgrade claude` are both "No available
    /// formula" — which is what deriving the name from the provider produced.
    func testHomebrewsNamesAreNotTheCommandsNames() {
        XCTAssertEqual(AgentCLIInstall.brewFormula(for: .gemini), "gemini-cli")
        XCTAssertEqual(AgentCLIInstall.brewFormula(for: .claude), "claude-code")
        XCTAssertEqual(AgentCLIInstall.brewFormula(for: .codex), "codex")
    }

    // MARK: - Claude's own installer

    func testClaudesNativeInstallIsRecognised() {
        XCTAssertEqual(
            AgentCLIInstall.source(
                path: "/Users/x/.local/bin/claude",
                resolvedPath: "/Users/x/.local/share/claude/versions/2.1.220",
                provider: .claude
            ),
            .nativeInstaller
        )
    }

    func testSomethingUnplaceableIsAdmittedRatherThanGuessedAt() {
        XCTAssertEqual(
            AgentCLIInstall.source(
                path: "/Users/x/bin/gemini", resolvedPath: nil, provider: .gemini
            ),
            .unknown
        )
    }
}

/// What updating an install would actually run.
final class AgentUpdatePlanTests: XCTestCase {
    private func plan(
        _ provider: AgentProvider, _ source: AgentInstallSource, npmAt: [String] = []
    ) -> AgentUpdatePlan {
        AgentCLIInstall.updatePlan(provider: provider, source: source) { npmAt.contains($0) }
    }

    /// The fix that matters. Running whichever `npm` the login shell resolves
    /// is how an update exits 0 and changes nothing: it installs into a
    /// different Node while the binary on PATH stays exactly as old as it was.
    func testAnNpmUpdateUsesTheNpmOfTheNodeThePackageBelongsTo() {
        let prefix = "/Users/x/.nvm/versions/node/v24.1.0"
        XCTAssertEqual(
            plan(.gemini, .npm(prefix: prefix), npmAt: ["\(prefix)/bin/npm"]),
            .run("\"\(prefix)/bin/npm\" install -g @google/gemini-cli@latest")
        )
    }

    /// pnpm and Yarn put packages under `lib/node_modules` and keep no npm
    /// beside them, so the prefix is right and the binary is not there.
    func testAPrefixWithNoNpmFallsBackToWhateverIsOnPath() {
        XCTAssertEqual(
            plan(.gemini, .npm(prefix: "/Users/x/Library/pnpm/global/5")),
            .run("npm install -g @google/gemini-cli@latest")
        )
    }

    func testGeminiHasAnUpdatePathAtAll() {
        // It had none: every Gemini case except Homebrew fell through to nil.
        if case .cannot = plan(.gemini, .npm(prefix: nil)) {
            XCTFail("Gemini should have an npm update path")
        }
    }

    func testHomebrewUpdatesByItsOwnName() {
        XCTAssertEqual(
            plan(.gemini, .homebrew(formula: "gemini-cli")),
            .run("brew upgrade gemini-cli")
        )
    }

    func testVoltaUsesItsOwnInstaller() {
        XCTAssertEqual(plan(.gemini, .volta), .run("volta install @google/gemini-cli@latest"))
    }

    func testClaudeUpdatesItselfWhereverItCameFrom() {
        XCTAssertEqual(plan(.claude, .nativeInstaller), .run("claude update"))
        XCTAssertEqual(plan(.claude, .unknown), .run("claude update"))
    }

    /// Guessing `npm install -g` here installs a second copy somewhere else on
    /// PATH while the one in use stays as old as it was — an update that
    /// reports success and changes nothing. Saying so beats doing that.
    func testAnUnplaceableInstallIsNotGuessedAt() {
        guard case .cannot(let reason) = plan(.gemini, .unknown) else {
            return XCTFail("an unknown install must not be guessed at")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}

/// Telling "the command exited 0" apart from "the tool moved".
final class AgentUpdateOutcomeTests: XCTestCase {
    func testAVersionThatMovedIsAnUpdate() {
        XCTAssertEqual(
            AgentCLIInstall.outcome(succeeded: true, output: "", before: "0.53.1", after: "0.54.0"),
            .updated(from: "0.53.1", to: "0.54.0")
        )
    }

    /// The case this exists for: exactly what "the update keeps failing" looks
    /// like from outside, and what a plain exit-code check reports as success.
    func testACommandThatSucceededAndChangedNothingIsNotAnUpdate() {
        XCTAssertEqual(
            AgentCLIInstall.outcome(succeeded: true, output: "", before: "0.53.1", after: "0.53.1"),
            .ranButUnchanged(version: "0.53.1")
        )
    }

    func testAFailureKeepsWhatTheCommandSaid() {
        XCTAssertEqual(
            AgentCLIInstall.outcome(
                succeeded: false, output: "npm ERR! code EACCES", before: "1.0.0", after: "1.0.0"
            ),
            .failed("npm ERR! code EACCES")
        )
    }

    /// A failure with no output at all still has to say something.
    func testASilentFailureStillReportsSomething() {
        guard case .failed(let message) =
            AgentCLIInstall.outcome(succeeded: false, output: "   ", before: nil, after: nil)
        else { return XCTFail("a failed command is a failure") }
        XCTAssertFalse(message.isEmpty)
    }

    func testAVersionThatCannotBeReadAfterwardsIsNotClaimedAsSuccess() {
        guard case .failed =
            AgentCLIInstall.outcome(succeeded: true, output: "", before: "1.0.0", after: nil)
        else { return XCTFail("an unreadable version is not a successful update") }
    }

    /// A first install has no "before" and is still an update.
    func testAFirstInstallCountsAsAnUpdate() {
        XCTAssertEqual(
            AgentCLIInstall.outcome(succeeded: true, output: "", before: nil, after: "1.0.0"),
            .updated(from: nil, to: "1.0.0")
        )
    }

    func testOnlyRealSuccessIsReportedAsSuccess() {
        XCTAssertFalse(AgentUpdateOutcome.updated(from: nil, to: "1").isFailure)
        XCTAssertTrue(AgentUpdateOutcome.ranButUnchanged(version: "1").isFailure)
        XCTAssertTrue(AgentUpdateOutcome.failed("x").isFailure)
    }
}
