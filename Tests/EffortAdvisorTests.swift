import XCTest
@testable import Uncoil

/// The effort advisor's pure parts: the ladder and its bounds, the policy
/// that places a reading on it, the heuristic, and the Laya wire format.
final class EffortAdvisorTests: XCTestCase {
    let claude = EffortLadder(provider: .claude, levels: ["low", "medium", "high", "xhigh", "max"])
    let codex = EffortLadder(provider: .codex, levels: ["minimal", "low", "medium", "high", "xhigh"])

    func features(
        _ complexity: Double, failed: Double = 0, design: Double = 0, multi: Double = 0,
        distribution: [Double]? = nil
    ) -> EffortFeatures {
        EffortFeatures(
            complexity: complexity,
            distribution: distribution ?? HeuristicEffortAdvisor.softDistribution(around: complexity),
            questionOnly: 0, multiStep: multi, afterFailure: failed, needsDesign: design, source: .heuristic)
    }

    // MARK: - Bounds

    func testBoundsFitTheLadderTheCLIOffersToday() {
        XCTAssertEqual(AgentEffortPolicy().range(in: claude), 0...4)
        XCTAssertEqual(AgentEffortPolicy(minimum: "medium", maximum: "high").range(in: claude), 1...2)
        XCTAssertEqual(AgentEffortPolicy(minimum: "high", maximum: "low").range(in: claude), 0...2,
                       "bounds saved the wrong way round are swapped, not emptied")
        XCTAssertEqual(AgentEffortPolicy(minimum: "gone", maximum: "gone").range(in: claude), 0...4,
                       "a level the CLI no longer has falls back to the ladder's end")
        XCTAssertNil(AgentEffortPolicy().range(in: EffortLadder(provider: .gemini, levels: [])))
    }

    // MARK: - Policy

    func testComplexityPicksAPlaceOnTheLadder() {
        let policy = AgentEffortPolicy()
        XCTAssertEqual(EffortPolicy.decide(features(0), ladder: claude, policy: policy, current: nil)?.level, "low")
        XCTAssertEqual(EffortPolicy.decide(features(2), ladder: claude, policy: policy, current: nil)?.level, "high")
        XCTAssertEqual(EffortPolicy.decide(features(4), ladder: claude, policy: policy, current: nil)?.level, "max")
        XCTAssertEqual(EffortPolicy.decide(features(0), ladder: codex, policy: policy, current: nil)?.level, "minimal")
    }

    func testTheSuggestionStaysInsideTheUsersRange() {
        let policy = AgentEffortPolicy(minimum: "medium", maximum: "high")
        XCTAssertEqual(EffortPolicy.decide(features(0), ladder: claude, policy: policy, current: nil)?.level, "medium")
        XCTAssertEqual(EffortPolicy.decide(features(4, failed: 0.9, design: 0.9), ladder: claude, policy: policy, current: nil)?.level, "high")
    }

    func testAFailedAttemptOrADesignQuestionLiftsTheEffort() {
        let policy = AgentEffortPolicy()
        let plain = EffortPolicy.decide(features(1), ladder: claude, policy: policy, current: nil)
        let failed = EffortPolicy.decide(features(1, failed: 0.8), ladder: claude, policy: policy, current: nil)
        let designed = EffortPolicy.decide(features(1, failed: 0.8, design: 0.8), ladder: claude, policy: policy, current: nil)
        XCTAssertEqual(plain?.level, "medium")
        XCTAssertEqual(failed?.level, "high")
        XCTAssertEqual(designed?.level, "xhigh")
        XCTAssertTrue(designed?.reasons.contains("an earlier attempt did not work") == true)
    }

    func testConfidenceIsTheMassOfTheBucketsThatLandOnTheLevel() {
        let split = features(2, distribution: [0.5, 0, 0, 0, 0.5])
        let low = EffortPolicy.decide(split, ladder: claude, policy: AgentEffortPolicy(), current: nil)
        XCTAssertEqual(low?.level, "high")
        XCTAssertEqual(low?.confidence ?? -1, 0, accuracy: 0.001, "a reading split between the ends is not sure of the middle")

        let narrow = AgentEffortPolicy(minimum: "low", maximum: "medium")
        let sure = EffortPolicy.decide(features(0.4, distribution: [0.7, 0.3, 0, 0, 0]), ladder: claude, policy: narrow, current: nil)
        XCTAssertEqual(sure?.level, "low")
        XCTAssertEqual(sure?.confidence ?? -1, 1, accuracy: 0.001)
    }

    func testNothingIsSuggestedForAnAgentTurnedOffOrWithoutLevels() {
        XCTAssertNil(EffortPolicy.decide(features(1), ladder: claude, policy: AgentEffortPolicy(enabled: false), current: nil))
        XCTAssertNil(EffortPolicy.decide(features(1), ladder: EffortLadder(provider: .gemini, levels: []), policy: AgentEffortPolicy(), current: nil))
    }

    func testASuggestionMatchingTheCurrentEffortIsNotAChange() {
        let same = EffortPolicy.decide(features(0), ladder: claude, policy: AgentEffortPolicy(), current: "low")
        XCTAssertEqual(same?.isChange, false)
        let unknown = EffortPolicy.decide(features(0), ladder: claude, policy: AgentEffortPolicy(), current: nil)
        XCTAssertEqual(unknown?.isChange, true, "the CLI's own default is not assumed to be any level")
    }

    // MARK: - Heuristic

    func testTheHeuristicOrdersEnglishAndTurkishPrompts() {
        func read(_ prompt: String, recent: [String] = []) -> EffortFeatures {
            HeuristicEffortAdvisor.read(EffortContext(prompt: prompt, provider: .claude, recent: recent))
        }
        XCTAssertLessThan(read("Fix the typo in README").complexity,
                          read("Redesign the control plane architecture and plan the migration").complexity)
        XCTAssertLessThan(read("README'deki yazım hatasını düzelt").complexity,
                          read("Kontrol düzlemini yeniden tasarla, mimari ve geçiş planı öner").complexity)
        XCTAssertGreaterThan(read("Terminal hâlâ donuyor").afterFailure, 0.6)
        XCTAssertGreaterThan(read("It still crashes after the fix").afterFailure, 0.6)
        XCTAssertGreaterThan(read("mimariyi tasarla").needsDesign, 0.6)
        XCTAssertGreaterThan(read("What does the --effort flag do?").questionOnly, 0.6)
        XCTAssertLessThan(read("add a button").afterFailure, 0.3)
        XCTAssertGreaterThan(read("try this", recent: ["user: it still does not work"]).afterFailure, 0.3,
                             "a failure earlier in the conversation still counts, less")
    }

    func testTheHeuristicDistributionSumsToOne() {
        for complexity in stride(from: 0.0, through: 4.0, by: 0.5) {
            XCTAssertEqual(HeuristicEffortAdvisor.softDistribution(around: complexity).reduce(0, +), 1, accuracy: 0.0001)
        }
    }

    func testTheRequestComesFirstInWhatTheModelReads() {
        let context = EffortContext(prompt: "fix it", provider: .claude, recent: [String(repeating: "x", count: 5_000)])
        XCTAssertTrue(context.state.hasPrefix("Request: fix it"))
        XCTAssertLessThanOrEqual(context.state.count, EffortContext.stateLimit)
    }

    // MARK: - Laya wire format

    /// Trimmed from a real `laya-apple serve` 1.5.0 answer.
    static let englishAnswer = """
    {"model":"laya-rl-agent","answers":{
      "complexity":{"type":"score","score":2.35,"probabilities":{"0":0.05,"1":0.15,"2":0.3,"3":0.4,"4":0.1},"confidence":0.3},
      "question_only":{"type":"noul","noul":0.27},
      "multi_step":{"type":"noul","noul":0.09},
      "after_failure":{"type":"noul","noul":0.81},
      "needs_design":{"type":"noul","noul":0.0}},
     "usage":{"input_tokens":0,"output_tokens":0},
     "routing":{"model":"english","repo":"convaiinnovations/laya","reason":"auto"}}
    """

    func testTheModelsAnswerBecomesFeatures() throws {
        let parsed = try LayaEffortAdvisor.parse(Data(Self.englishAnswer.utf8))
        XCTAssertEqual(parsed.complexity, 2.35, accuracy: 0.001)
        XCTAssertEqual(parsed.distribution, [0.05, 0.15, 0.3, 0.4, 0.1])
        XCTAssertEqual(parsed.afterFailure, 0.81, accuracy: 0.001)
        XCTAssertEqual(parsed.model, "english")
        XCTAssertEqual(parsed.source, .laya)
        XCTAssertThrowsError(try LayaEffortAdvisor.parse(Data(#"{"answers":{}}"#.utf8)))
    }

    func testTheRequestAsksAllFiveQuestionsInOnePass() throws {
        let body = try LayaEffortAdvisor.requestBody(for: EffortContext(prompt: "fix it", provider: .claude))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "Request: fix it")
        let questions = try XCTUnwrap(json["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), ["complexity", "question_only", "multi_step", "after_failure", "needs_design"])
        XCTAssertEqual((questions["complexity"] as? [String: Any])?["type"] as? String, "score")
    }

    func testAMultilingualAnswerIsBlendedWithTheHeuristic() async throws {
        let answer = Self.englishAnswer.replacingOccurrences(of: "\"english\"", with: "\"multilingual\"")
        let advisor = LayaEffortAdvisor(baseURL: URL(string: "http://127.0.0.1:1")!) { request in
            XCTAssertEqual(request.url?.path, "/v1/systemone")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let context = EffortContext(prompt: "README'deki yazım hatasını düzelt", provider: .claude)
        let features = try await advisor.features(for: context)
        let heuristic = HeuristicEffortAdvisor.read(context)
        XCTAssertEqual(features.source, .blended)
        XCTAssertEqual(features.complexity, (2.35 + heuristic.complexity) / 2, accuracy: 0.001)
        XCTAssertNotNil(features.latencyMilliseconds)
    }

    func testAFailingModelFallsBackToTheHeuristic() async throws {
        let broken = LayaEffortAdvisor(baseURL: URL(string: "http://127.0.0.1:1")!) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await broken.features(for: EffortContext(prompt: "x", provider: .claude))
            XCTFail("a 503 is an error")
        } catch {
            XCTAssertEqual(error as? LayaEffortAdvisor.Failure, .status(503))
        }
        let features = try await FallbackEffortAdvisor(primary: broken)
            .features(for: EffortContext(prompt: "fix the typo", provider: .claude))
        XCTAssertEqual(features.source, .heuristic)
    }

    // MARK: - Sidecar

    func testTheSidecarKeepsEverythingInItsOwnDirectory() {
        let root = URL(fileURLWithPath: "/tmp/advisor")
        let environment = LayaSidecar.environment(root: root)
        XCTAssertEqual(environment["UV_CACHE_DIR"], "/tmp/advisor/uv-cache")
        XCTAssertEqual(environment["HF_HOME"], "/tmp/advisor/hf")

        let steps = LayaSidecar.installSteps(uv: "/usr/local/bin/uv", root: root)
        XCTAssertEqual(steps.map(\.executable), ["/usr/local/bin/uv", "/usr/local/bin/uv", "/tmp/advisor/venv/bin/laya-apple"])
        XCTAssertTrue(steps[1].arguments.contains(LayaSidecar.package))
        XCTAssertEqual(steps[2].arguments, ["download", "laya", "laya-multilingual"])

        let serve = LayaSidecar.serveArguments(port: 9000)
        XCTAssertEqual(serve.first, "--offline", "serving never touches the network")
        XCTAssertEqual(serve[serve.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(serve[serve.firstIndex(of: "--port")! + 1], "9000")
        XCTAssertNotNil(LayaSidecar.freePort())
    }

    // MARK: - Settings

    @MainActor
    func testUncoilAutoSettingsRoundTripAndDefaultToNothingWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UncoilAutoSettings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(directory: dir)
        XCTAssertEqual(settings.uncoilAuto, .default)
        XCTAssertTrue(settings.uncoilAuto.allows(.codex), "every agent is open until one is turned off")

        settings.setUncoilAutoAllows(.codex, false)
        settings.updateUncoilAuto {
            $0.advisor.engine = .laya
            $0.advisor.perAgent["claude"] = AgentEffortPolicy(minimum: "low", maximum: "high")
        }
        let reloaded = SettingsStore(directory: dir)
        XCTAssertFalse(reloaded.uncoilAuto.allows(.codex))
        XCTAssertTrue(reloaded.uncoilAuto.allows(.claude))
        XCTAssertEqual(reloaded.uncoilAuto.advisor.engine, .laya)
        XCTAssertEqual(reloaded.uncoilAuto.advisor.policy(for: .claude).maximum, "high")

        reloaded.setUncoilAutoAllows(.codex, true)
        reloaded.updateUncoilAuto { $0 = .default }
        let raw = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("uncoilAuto"), "the default is not written down")
    }

    // MARK: - Applying

    func testHowASuggestionCanReachEachAgent() {
        let running = UncoilAutoRoster.Entry(handle: "claude", provider: .claude, sessionID: UUID(), title: "")
        let codex = UncoilAutoRoster.Entry(handle: "codex", provider: .codex, sessionID: UUID(), title: "")
        let unstarted = UncoilAutoRoster.Entry(handle: "codex", provider: .codex, sessionID: nil, title: "")
        XCTAssertEqual(EffortSuggestionItem.application(for: running, isStructured: false), .command)
        XCTAssertNotEqual(EffortSuggestionItem.application(for: running, isStructured: true), .command,
                          "a structured Claude session has no terminal to type /effort into")
        XCTAssertNotEqual(EffortSuggestionItem.application(for: codex, isStructured: false), .command)
        XCTAssertEqual(EffortSuggestionItem.application(for: unstarted, isStructured: false), .atLaunch)
    }

    func testTheDecisionLogCountsDecisionsAndClears() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decisions-\(UUID()).jsonl")
        let log = EffortDecisionLog(url: url)
        defer { log.clear() }
        log.append(EffortDecisionLog.Decision(
            id: "a", date: .now, provider: "claude", prompt: "fix", state: "Request: fix",
            features: features(0), suggested: "low", confidence: 0.8, current: nil, followed: false))
        log.append(EffortDecisionLog.Outcome(id: "a", date: .now, seconds: 3, result: "completed"))
        XCTAssertEqual(log.count, 1)
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        XCTAssertEqual(lines.count, 2, "one JSON object per line")
        log.clear()
        XCTAssertEqual(log.count, 0)
    }

    // MARK: - Live

    /// Against a real `laya-apple serve`; skipped unless UNCOIL_LAYA_URL
    /// points at one. Prints what each prompt would get on Claude's ladder.
    func testALiveServerOrdersRealPrompts() async throws {
        guard let raw = ProcessInfo.processInfo.environment["UNCOIL_LAYA_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Set UNCOIL_LAYA_URL to run against a live laya-apple server")
        }
        let advisor = LayaEffortAdvisor(baseURL: url, timeout: 10)
        let prompts = [
            "Fix the typo in README: 'recieve' should be 'receive'.",
            "Add a settings toggle for the menu bar monitor and persist it.",
            "The terminal still freezes after resize, the last two fixes did not work. Find the root cause.",
            "Redesign the control plane so agents can orchestrate each other across projects; propose an architecture and migration plan.",
            "README'deki yazım hatasını düzelt.",
            "Terminal yeniden boyutlandırınca hâlâ donuyor, iki düzeltme de işe yaramadı. Kök nedeni bul.",
            "Kontrol düzlemini projeler arası orkestrasyon için yeniden tasarla, mimari ve geçiş planı öner.",
        ]
        var indices: [Int] = []
        for prompt in prompts {
            let features = try await advisor.features(for: EffortContext(prompt: prompt, provider: .claude))
            let suggestion = try XCTUnwrap(EffortPolicy.decide(features, ladder: claude, policy: AgentEffortPolicy(), current: nil))
            indices.append(try XCTUnwrap(claude.index(of: suggestion.level)))
            print(String(format: "LIVE %@ %-6@ %3.0f%% %4.0fms %@ | %@", features.source.rawValue, suggestion.level,
                         suggestion.confidence * 100, features.latencyMilliseconds ?? 0,
                         suggestion.reasons.joined(separator: ", "), String(prompt.prefix(50))))
        }
        XCTAssertLessThan(indices[0], indices[3], "a typo gets less than a redesign")
        XCTAssertLessThan(indices[4], indices[6], "in Turkish too")
        XCTAssertLessThan(indices[0], indices[2], "a failing debug gets more than a typo")
    }
}
