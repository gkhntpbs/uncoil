import XCTest
@testable import Uncoil

private func package(
    objective: String? = nil,
    responded: Bool = false,
    changed: [String] = [],
    branch: String? = "feature/x",
    task: HandoffPackage.TaskContext? = nil
) -> HandoffPackage {
    var result = HandoffPackage(
        projectName: "Uncoil",
        projectPath: "/work/uncoil",
        workingDirectory: "/work/uncoil",
        worktreePath: nil,
        branch: branch,
        changedFiles: changed.map { HandoffPackage.ChangedFile(status: "M", path: $0) },
        diff: nil,
        task: task,
        fromProvider: .claude,
        fromAccountName: "Work",
        fromSessionTitle: "the refactor",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    result.objective = objective
    result.agentResponded = responded
    return result
}

/// What the outgoing agent is asked, and what the incoming one is told.
final class HandoffPromptTests: XCTestCase {

    // MARK: - The request

    /// The request has to ask for the thing a summary is not. An agent told
    /// only "write a handover" writes a recap of the conversation, which is
    /// exactly what the next agent cannot use.
    func testTheRequestAsksForDecisionsAndDeadEnds() {
        let request = HandoffPrompt.request(remainingPercent: 8, windowTitle: "Weekly limit")
        XCTAssertTrue(request.contains("decisions"))
        XCTAssertTrue(request.contains("knownProblems"))
        XCTAssertTrue(request.contains("did not work"))
        XCTAssertTrue(request.contains("suggestedNextStep"))
        XCTAssertTrue(request.contains("JSON and nothing else"))
    }

    /// It says how much is left, because an agent asked to stop deserves the
    /// reason, and it says not to carry on — the point is to capture the state,
    /// not to spend the last of the quota.
    func testTheRequestExplainsItselfAndSaysToStop() {
        let request = HandoffPrompt.request(remainingPercent: 8, windowTitle: "Weekly limit")
        XCTAssertTrue(request.contains("8%"))
        XCTAssertTrue(request.contains("weekly limit"))
        XCTAssertTrue(request.lowercased().contains("do not continue the work"))
    }

    /// And it does not ask for what Uncoil already has, or the agent spends its
    /// last tokens retyping a diff.
    func testTheRequestDoesNotAskForWhatIsAlreadyKnown() {
        let request = HandoffPrompt.request(remainingPercent: nil, windowTitle: nil)
        XCTAssertTrue(request.contains("do not repeat those"))
    }

    // MARK: - The handover

    func testTheHandoverCarriesTheGround() {
        let text = HandoffPrompt.handover(package(
            changed: ["App/A.swift", "Tests/ATests.swift"],
            task: .init(text: "Add search", sourcePath: "TODO.md", headingPath: ["Interface"])
        ))
        XCTAssertTrue(text.contains("/work/uncoil"))
        XCTAssertTrue(text.contains("feature/x"))
        XCTAssertTrue(text.contains("App/A.swift"))
        XCTAssertTrue(text.contains("Add search"))
        XCTAssertTrue(text.contains("Interface"))
    }

    /// The previous agent's words are text written by one agent and read as
    /// instructions by another. Fenced and attributed, exactly as the control
    /// plane already fences external content — an agent that takes them as its
    /// own orders is steerable by whatever the last one happened to say.
    func testTheAgentsWordsAreFencedAndAttributed() {
        var built = package(objective: "Finish the parser", responded: true)
        built.decisions = ["Kept the old API"]
        built.suggestedNextStep = "Run the tests"
        let text = HandoffPrompt.handover(built)

        XCTAssertTrue(text.contains("<previous_agent_handover>"))
        XCTAssertTrue(text.contains("</previous_agent_handover>"))
        XCTAssertTrue(text.contains("written by that agent, not by me"))
        XCTAssertTrue(text.contains("Kept the old API"))
    }

    /// Silence is stated. An agent that read the absence as "nothing to report"
    /// would carry on as though the ground had been surveyed.
    func testASilentAgentIsReportedAsSilent() {
        var built = package()
        built.agentFailureReason = "it did not answer in time"
        let text = HandoffPrompt.handover(built)

        XCTAssertTrue(text.contains("it did not answer in time"))
        XCTAssertFalse(text.contains("<previous_agent_handover>"))
        XCTAssertTrue(text.contains("read the diff before assuming"))
    }

    /// The notes describe a moment that has already passed, and the next agent
    /// is told so rather than left to trust them.
    func testTheHandoverTellsTheNextAgentToCheckForItself() {
        let text = HandoffPrompt.handover(package(objective: "x", responded: true))
        XCTAssertTrue(text.contains("Check the current state yourself"))
    }

    func testAWorktreeIsFencedInTheHandover() {
        var built = package()
        built.worktreePath = "/work/uncoil-worktrees/feature"
        let text = HandoffPrompt.handover(built)
        XCTAssertTrue(text.contains("stay inside it"))
    }

    // MARK: - Reading the answer

    func testTheAgentsJSONIsMerged() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "objective": "Finish the usage layer",
          "workDone": ["parsers", "tests"],
          "decisions": ["kept the tolerant reader"],
          "openItems": ["wire the UI"],
          "knownProblems": ["the keychain prompts on every rebuild"],
          "suggestedNextStep": "run the live probes"
        }
        """.utf8))
        let merged = HandoffPrompt.merge(agentJSON: json, into: package())

        XCTAssertTrue(merged.agentResponded)
        XCTAssertEqual(merged.objective, "Finish the usage layer")
        XCTAssertEqual(merged.workDone, ["parsers", "tests"])
        XCTAssertEqual(merged.knownProblems.first, "the keychain prompts on every rebuild")
        // The ground truth survives the merge.
        XCTAssertEqual(merged.branch, "feature/x")
    }

    /// This is text produced by a language model. A parser that refused the
    /// whole answer over one missing key would throw away the fields that did
    /// arrive.
    func testAPartialAnswerIsKept() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"objective": "Finish it", "nonsense": {"nested": 1}}
        """.utf8))
        let merged = HandoffPrompt.merge(agentJSON: json, into: package())
        XCTAssertTrue(merged.agentResponded)
        XCTAssertEqual(merged.objective, "Finish it")
        XCTAssertTrue(merged.decisions.isEmpty)
    }

    /// A string where a list was asked for is still an answer.
    func testASingleStringIsAcceptedForAList() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"workDone": "wrote the parser"}
        """.utf8))
        XCTAssertEqual(
            HandoffPrompt.merge(agentJSON: json, into: package()).workDone, ["wrote the parser"]
        )
    }

    /// An empty object is a file, not an answer — and the difference decides
    /// what the next agent is told.
    func testAnEmptyAnswerIsNotAResponse() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("{}".utf8))
        XCTAssertFalse(HandoffPrompt.merge(agentJSON: json, into: package()).agentResponded)
    }
}

// MARK: - Destinations

@MainActor
final class HandoffDestinationTests: XCTestCase {
    private func entry(_ remaining: Double) -> UsageEntry {
        var entry = UsageEntry()
        entry.snapshot = UsageSnapshot(
            provider: .codex,
            primaryWindow: UsageWindow(id: "w", title: "Session", usedPercent: 100 - remaining),
            source: .codexOAuthAPI, updatedAt: Date()
        )
        return entry
    }

    private let from = UsageKey(provider: .claude, accountID: nil)

    func testTheAccountBeingLeftIsNotOffered() {
        let destinations = HandoffService.destinations(
            from: from, accounts: [], installedProviders: [.claude, .codex],
            usage: [:], threshold: 15
        )
        XCTAssertFalse(destinations.contains { $0.id == "claude:default" })
        XCTAssertTrue(destinations.contains { $0.provider == .codex })
    }

    /// Most people never make a profile, so a list that only offered profiles
    /// would be empty on an ordinary machine.
    func testTheProvidersOwnLoginIsADestination() {
        let destinations = HandoffService.destinations(
            from: from, accounts: [], installedProviders: [.codex], usage: [:], threshold: 15
        )
        XCTAssertEqual(destinations.count, 1)
        XCTAssertNil(destinations[0].accountID)
    }

    /// A second login of the same provider is as valid a destination as another
    /// provider — and on a machine with two subscriptions, the likelier answer.
    func testASecondLoginOfTheSameProviderIsOffered() {
        let work = AccountProfile(provider: .claude, name: "Work")
        let destinations = HandoffService.destinations(
            from: from, accounts: [work], installedProviders: [.claude],
            usage: [:], threshold: 15
        )
        XCTAssertEqual(destinations.map(\.accountID), [work.id])
        XCTAssertEqual(destinations[0].label, "Claude · Work")
    }

    /// An agent that is not installed is not somewhere work can go.
    func testAnUninstalledProviderIsNotOffered() {
        let destinations = HandoffService.destinations(
            from: from, accounts: [], installedProviders: [.claude], usage: [:], threshold: 15
        )
        XCTAssertTrue(destinations.isEmpty)
    }

    /// Ordered by room, because that is the question being asked. An account we
    /// cannot read sorts last: unknown is not a promise of room.
    func testTheMostRoomIsOfferedFirstAndUnknownIsLast() {
        let gemini = UsageKey(provider: .gemini, accountID: nil)
        let codex = UsageKey(provider: .codex, accountID: nil)
        let destinations = HandoffService.destinations(
            from: from, accounts: [], installedProviders: [.codex, .gemini],
            usage: [codex: entry(70)], threshold: 15
        )
        XCTAssertEqual(destinations.first?.provider, .codex)
        XCTAssertEqual(destinations.first?.remainingPercent, 70)
        XCTAssertNil(destinations.last?.remainingPercent)
        XCTAssertEqual(destinations.last?.provider, .gemini)
        _ = gemini
    }

    /// A low destination is still offered, and marked. Hiding it would leave
    /// someone with no options at all on a machine where everything is low.
    func testALowDestinationIsOfferedAndMarked() {
        let codex = UsageKey(provider: .codex, accountID: nil)
        let destinations = HandoffService.destinations(
            from: from, accounts: [], installedProviders: [.codex],
            usage: [codex: entry(4)], threshold: 15
        )
        XCTAssertEqual(destinations.count, 1)
        XCTAssertTrue(destinations[0].isAlerting)
    }
}

// MARK: - The package

final class HandoffPackageTests: XCTestCase {

    /// The ground truth alone is worth handing over: a next agent given a
    /// branch, a diff and a task is far better off than one given nothing.
    func testGroundTruthAloneIsUsable() {
        XCTAssertTrue(package(changed: ["A.swift"]).isUsable)
        XCTAssertTrue(package(branch: "main").isUsable)
    }

    func testAnEmptyPackageIsNot() {
        var empty = package(branch: nil)
        empty.changedFiles = []
        XCTAssertFalse(empty.isUsable)
    }

    func testItSurvivesACodableRoundTrip() throws {
        var built = package(objective: "x", responded: true, changed: ["A.swift"])
        built.decisions = ["kept it"]
        built.testResults = [.init(suite: "UncoilTests", passed: false, detail: "3 failing")]
        let data = try JSONEncoder().encode(built)
        XCTAssertEqual(try JSONDecoder().decode(HandoffPackage.self, from: data), built)
    }
}

// MARK: - The list the sheet actually builds

/// Reproduces the sheet's own computation against this machine.
///
/// Written because the UI test reached the sheet and found it empty, and no
/// amount of reading the code said why. This asks the same question the sheet
/// asks, one layer down, where the answer can be printed.
@MainActor
final class HandoffDestinationDiscoveryTests: XCTestCase {

    /// Exactly what `HandoffSheet.destinations` passes for `installedProviders`.
    private func installedProviders() -> Set<AgentProvider> {
        Set(AgentProvider.agents.filter { provider in
            provider.launchCommand.flatMap { AgentAdapterSupport.locateBinary($0) } != nil
        })
    }

    func testWhatThisMachineOffers() throws {
        let installed = installedProviders()
        for provider in AgentProvider.agents {
            let command = provider.launchCommand ?? "—"
            let path = provider.launchCommand.flatMap { AgentAdapterSupport.locateBinary($0) }
            print("provider=\(provider.rawValue) command=\(command) path=\(path ?? "not found")")
        }

        let destinations = HandoffService.destinations(
            from: UsageKey(provider: .claude, accountID: nil),
            accounts: [],
            installedProviders: installed,
            usage: [:],
            threshold: 15
        )
        print("installed=\(installed.map(\.rawValue).sorted()) destinations=\(destinations.map(\.id))")

        // The machine this runs on has Codex, so an empty list is the bug.
        XCTAssertFalse(
            destinations.isEmpty,
            "no destinations from installed=\(installed.map(\.rawValue).sorted())"
        )
    }
}

/// Runs the real producer against a real conversation.
///
/// Skipped unless `UNCOIL_HANDOFF_LIVE=1`: it spends quota and needs a logged-in
/// CLI. It exists because every failure in this feature so far was invisible
/// from the outside — the app said "it did not answer" while the CLI was saying
/// something specific and useful.
final class HandoffProducerLiveTests: XCTestCase {
    func testItAsksTheRealAgent() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UNCOIL_HANDOFF_LIVE"] == "1",
            "Set UNCOIL_HANDOFF_LIVE=1 to run the live producer"
        )
        let directory = ProcessInfo.processInfo.environment["UNCOIL_HANDOFF_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("UncoilUITest/demo-project").path
        let executable = try XCTUnwrap(AgentAdapterSupport.locateBinary("claude"))

        let result = HandoffProducer.produce(
            provider: .claude,
            executable: executable,
            providerSessionID: nil,
            workingDirectory: directory,
            request: HandoffPrompt.request(remainingPercent: 8, windowTitle: "Weekly limit")
        )

        print("=== producer ===")
        print("failure: \(result.failure ?? "none")")
        print("bytes: \(result.rawLength)")
        if let json = result.json,
           let data = try? JSONEncoder().encode(json),
           let text = String(data: data, encoding: .utf8) {
            print("json: \(text.prefix(600))")
        }
        print("================")

        XCTAssertNil(result.failure, "the producer failed: \(result.failure ?? "")")
        XCTAssertNotNil(result.json, "no JSON came back")
    }
}
