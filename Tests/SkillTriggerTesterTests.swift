import XCTest
@testable import Uncoil

final class SkillTriggerTesterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)

    private func candidate(
        _ name: String,
        _ description: String,
        agents: [ExtensionAgentID] = [.claudeCode, .codex]
    ) -> SkillTriggerTester.Candidate {
        .init(extensionID: "acme/\(name)", name: name, description: description, agents: agents)
    }

    // MARK: - Reading the description the agent sees

    func testReadsDescriptionFromFrontMatter() {
        let markdown = """
        ---
        name: app-store-screens
        description: Create App Store ready screenshot campaigns from a real app project.
        ---

        # App Store Screens
        Uzun anlatım burada.
        """
        XCTAssertEqual(
            SkillTriggerTester.description(inSkillMarkdown: markdown),
            "Create App Store ready screenshot campaigns from a real app project."
        )
    }

    func testReadsFoldedMultiLineDescription() {
        let markdown = """
        ---
        name: dataviz
        description: >
          Use this when creating any chart, graph or dashboard.
          Covers colour palettes and axis rules.
        ---
        # Dataviz
        """
        let description = SkillTriggerTester.description(inSkillMarkdown: markdown)
        XCTAssertTrue(description.contains("chart"))
        XCTAssertTrue(description.contains("axis rules"))
        XCTAssertFalse(description.contains("---"))
    }

    func testFallsBackToTheFirstProseParagraphWithoutFrontMatter() {
        let markdown = """
        # Formatter

        Bir Swift dosyasını biçimlendirir ve sonucu gösterir.

        ## Detay
        Başka şeyler.
        """
        XCTAssertEqual(
            SkillTriggerTester.description(inSkillMarkdown: markdown),
            "Bir Swift dosyasını biçimlendirir ve sonucu gösterir."
        )
    }

    // MARK: - Matching

    func testSingleMatchIsReportedAsSuch() {
        let result = SkillTriggerTester.test(
            prompt: "App Store için ekran görüntüsü kampanyası hazırla",
            candidates: [
                candidate("app-store-screens", "App Store ekran görüntüsü kampanyası üretir."),
                candidate("dataviz", "Grafik ve dashboard tasarımı için renk paleti kuralları."),
            ],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.verdict, .single)
        XCTAssertEqual(result.matches.map(\.candidate.name), ["app-store-screens"])
        XCTAssertFalse(result.matches[0].matchedTerms.isEmpty, "the match is explainable")
    }

    func testNoMatchSuggestsTheDescriptionsMayBeTooNarrow() {
        let result = SkillTriggerTester.test(
            prompt: "Veritabanı migration yaz",
            candidates: [candidate("app-store-screens", "App Store ekran görüntüsü üretir.")],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.verdict, .noMatch)
        XCTAssertTrue(result.verdict.advice.contains("narrow"))
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testTwoMatchesAreReportedAsAConflict() {
        let result = SkillTriggerTester.test(
            prompt: "grafik tasarımı",
            candidates: [
                candidate("dataviz", "grafik tasarımı"),
                candidate("charts", "grafik tasarımı"),
                candidate("other", "veritabanı migration"),
            ],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.verdict, .conflict(count: 2))
        XCTAssertTrue(result.verdict.advice.contains("distinct"))
    }

    func testManyMatchesSuggestTheDescriptionsAreTooBroad() {
        let candidates = (0..<6).map { candidate("skill\($0)", "kod yazma") }
        let result = SkillTriggerTester.test(
            prompt: "kod yazma", candidates: candidates, agent: .claudeCode, now: now
        )
        XCTAssertEqual(result.verdict, .tooBroad(count: 6))
        XCTAssertTrue(result.verdict.advice.contains("broad"))
    }

    func testMatchesAreOrderedByScore() {
        let result = SkillTriggerTester.test(
            prompt: "swift formatter biçimlendirme",
            candidates: [
                candidate("broad", "swift formatter biçimlendirme kod analiz test derleme paket"),
                candidate("tight", "swift formatter biçimlendirme"),
            ],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.matches.map(\.candidate.name), ["tight", "broad"])
        XCTAssertGreaterThan(result.matches[0].score, result.matches[1].score)
    }

    func testASingleFillerWordIsNotATrigger() {
        let result = SkillTriggerTester.test(
            prompt: "bu bir test için",
            candidates: [candidate("x", "Veritabanı migration üretir ve şema değişikliği uygular.")],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.verdict, .noMatch)
    }

    // MARK: - Per-agent results

    func testResultsDifferPerAgentBasedOnAssignments() {
        let candidates = [
            candidate("claude-only", "grafik tasarımı", agents: [.claudeCode]),
            candidate("codex-only", "grafik tasarımı", agents: [.codex]),
        ]
        let results = SkillTriggerTester.testAll(
            prompt: "grafik tasarımı", candidates: candidates, now: now
        )
        XCTAssertEqual(
            results.count, ExtensionAgentID.supported.count,
            "every managed agent is reported, matching or not"
        )
        XCTAssertEqual(
            results.first { $0.agent == .claudeCode }?.matches.map(\.candidate.name),
            ["claude-only"]
        )
        XCTAssertEqual(
            results.first { $0.agent == .codex }?.matches.map(\.candidate.name),
            ["codex-only"]
        )
        XCTAssertEqual(
            results.first { $0.agent == .cursor }?.matches.count, 0,
            "an agent nothing is assigned to matches nothing"
        )
    }

    func testUnassignedSkillNeverTriggers() {
        let result = SkillTriggerTester.test(
            prompt: "grafik tasarımı",
            candidates: [candidate("orphan", "grafik tasarımı", agents: [])],
            agent: .claudeCode,
            now: now
        )
        XCTAssertEqual(result.verdict, .noMatch)
    }

    // MARK: - Candidate building

    @MainActor
    func testCandidatesSkipSkillsWithoutAReadableDescription() {
        let packages = [
            ExtensionPackage(id: "a", kind: .skill, name: "a", source: .local(path: "/a")),
            ExtensionPackage(id: "b", kind: .skill, name: "b", source: .local(path: "/b")),
        ]
        let candidates = SkillTriggerTester.candidates(
            skills: packages,
            agentBindings: [AgentBinding(extensionID: "a", agent: .codex)]
        ) { package in
            package.id == "a" ? "---\ndescription: Bir şey yapar.\n---\n" : nil
        }
        XCTAssertEqual(candidates.map(\.extensionID), ["a"])
        XCTAssertEqual(candidates[0].agents, [.codex])
    }

    @MainActor
    func testEmptyDescriptionIsNotACandidate() {
        let candidates = SkillTriggerTester.candidates(
            skills: [ExtensionPackage(id: "a", kind: .skill, name: "a", source: .local(path: "/a"))],
            agentBindings: []
        ) { _ in "# Only a heading\n" }
        XCTAssertTrue(candidates.isEmpty)
    }
}

@MainActor
final class SkillTriggerHistoryTests: XCTestCase {
    private var layout: ExtensionStoreLayout!
    private let now = Date(timeIntervalSince1970: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        layout = ExtensionStoreLayout(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("UncoilTrigger-\(UUID().uuidString)", isDirectory: true)
        )
        try layout.ensure()
    }

    private func result() -> SkillTriggerTester.Result {
        SkillTriggerTester.test(
            prompt: "grafik tasarımı",
            candidates: [
                .init(
                    extensionID: "a", name: "dataviz", description: "grafik tasarımı",
                    agents: [.claudeCode]
                ),
            ],
            agent: .claudeCode,
            now: now
        )
    }

    func testHistoryIsOffByDefaultSoPromptsAreNotStored() {
        let history = SkillTriggerHistory(layout: layout)
        XCTAssertFalse(history.isEnabled)
        history.record(result())
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(
            SkillTriggerHistory(layout: layout).entries.isEmpty,
            "nothing reached disk"
        )
    }

    func testEnabledHistoryPersistsAcrossReload() {
        let history = SkillTriggerHistory(layout: layout, isEnabled: true)
        history.record(result())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].matchedNames, ["dataviz"])
        XCTAssertEqual(history.entries[0].verdict, "One match")

        let reloaded = SkillTriggerHistory(layout: layout, isEnabled: true)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].prompt, "grafik tasarımı")
    }

    func testClearingRemovesStoredPromptsFromDisk() {
        let history = SkillTriggerHistory(layout: layout, isEnabled: true)
        history.record(result())
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(SkillTriggerHistory(layout: layout, isEnabled: true).entries.isEmpty)
    }
}
