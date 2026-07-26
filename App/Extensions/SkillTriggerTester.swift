import Foundation

/// Predicts which skills a prompt could trigger, from exactly the descriptions
/// the agent itself would see.
///
/// This is a description-quality tool, not a model: it cannot know what an agent
/// will really pick. What it can show is whether a description is so narrow that
/// nothing matches, or so broad that everything does — the two failure modes a
/// user cannot otherwise see until an agent behaves oddly.
enum SkillTriggerTester {
    /// One skill as the agent sees it: the name and the description text from
    /// its `SKILL.md` front matter.
    struct Candidate: Equatable, Identifiable {
        var id: String { extensionID }
        var extensionID: String
        var name: String
        var description: String
        /// Agents this skill is currently assigned to, so per-agent results can
        /// differ for the same prompt.
        var agents: [ExtensionAgentID]
    }

    struct Match: Equatable, Identifiable {
        var id: String { candidate.extensionID }
        var candidate: Candidate
        /// 0…1, from how much of the description's vocabulary the prompt hits.
        var score: Double
        /// Words that produced the match, so the result is explainable.
        var matchedTerms: [String]
    }

    enum Verdict: Equatable {
        case noMatch
        case single
        case conflict(count: Int)
        /// So many matches that the descriptions are probably too broad.
        case tooBroad(count: Int)

        var label: String {
            switch self {
            case .noMatch: "No match"
            case .single: "One match"
            case .conflict(let count): "\(count) skills clash"
            case .tooBroad(let count): "\(count) skills matched"
            }
        }

        var advice: String {
            switch self {
            case .noMatch:
                "No description covers this prompt; the descriptions may be too narrow."
            case .single:
                "A single skill triggers; the description is distinctive for this prompt."
            case .conflict:
                "Several skills claim the same prompt; make their descriptions distinct."
            case .tooBroad:
                "Too many skills match; the descriptions may be too broad."
            }
        }
    }

    struct Result: Equatable, Identifiable {
        var id: String { "\(agent.rawValue)|\(prompt)" }
        var agent: ExtensionAgentID
        var prompt: String
        var matches: [Match]
        var verdict: Verdict
        var testedAt: Date
    }

    /// Matches above this score count; below it, a single shared word is not
    /// treated as a trigger.
    static let matchThreshold = 0.2
    /// Beyond this many matches the problem is the descriptions, not the prompt.
    static let tooBroadThreshold = 4

    // MARK: - Reading descriptions

    /// Reads the description an agent would see. Supports the `---`/`description:`
    /// front matter skills use, and falls back to the first prose paragraph so a
    /// skill without front matter is still testable.
    static func description(inSkillMarkdown text: String) -> String {
        if let frontMatter = frontMatterDescription(text) { return frontMatter }
        return text
            .components(separatedBy: "\n")
            .drop { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func frontMatterDescription(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var collected: [String] = []
        var isCollecting = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if isCollecting {
                // A following indented line continues a folded YAML value.
                guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
                collected.append(trimmed)
                continue
            }
            guard trimmed.lowercased().hasPrefix("description:") else { continue }
            let value = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value != ">", value != "|" { collected.append(value) }
            isCollecting = true
        }
        let joined = collected.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// Builds the candidate list from the registry's skills, reading each active
    /// revision's own `SKILL.md`.
    @MainActor
    static func candidates(
        skills: [ExtensionPackage],
        agentBindings: [AgentBinding],
        readMarkdown: (ExtensionPackage) -> String?
    ) -> [Candidate] {
        skills.compactMap { package in
            guard let markdown = readMarkdown(package) else { return nil }
            let text = description(inSkillMarkdown: markdown)
            guard !text.isEmpty else { return nil }
            return Candidate(
                extensionID: package.id,
                name: package.name,
                description: text,
                agents: SkillAssignment.activeAgents(
                    extensionID: package.id, agentBindings: agentBindings
                )
            )
        }
    }

    // MARK: - Matching

    static func test(
        prompt: String,
        candidates: [Candidate],
        agent: ExtensionAgentID,
        now: Date = .now
    ) -> Result {
        let promptTerms = terms(in: prompt)
        let matches = candidates
            .filter { $0.agents.contains(agent) }
            .compactMap { candidate -> Match? in
                let descriptionTerms = terms(in: "\(candidate.name) \(candidate.description)")
                guard !descriptionTerms.isEmpty else { return nil }
                let shared = descriptionTerms.intersection(promptTerms)
                guard !shared.isEmpty else { return nil }
                let score = Double(shared.count) / Double(descriptionTerms.count)
                guard score >= matchThreshold else { return nil }
                return Match(
                    candidate: candidate,
                    score: score,
                    matchedTerms: shared.sorted()
                )
            }
            .sorted { $0.score > $1.score }

        return Result(
            agent: agent,
            prompt: prompt,
            matches: matches,
            verdict: verdict(for: matches),
            testedAt: now
        )
    }

    /// One result per agent, because the same prompt can hit different skills
    /// depending on what each agent is assigned.
    static func testAll(
        prompt: String,
        candidates: [Candidate],
        agents: [ExtensionAgentID] = ExtensionAgentID.supported,
        now: Date = .now
    ) -> [Result] {
        agents.map { test(prompt: prompt, candidates: candidates, agent: $0, now: now) }
    }

    static func verdict(for matches: [Match]) -> Verdict {
        switch matches.count {
        case 0: .noMatch
        case 1: .single
        case 2...tooBroadThreshold: .conflict(count: matches.count)
        default: .tooBroad(count: matches.count)
        }
    }

    /// Words worth matching on: lowercased, punctuation-free, and without the
    /// filler that would otherwise match everything.
    static func terms(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    /// Turkish and English filler. Deliberately small: an over-eager stop list
    /// would hide real matches.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "when",
        "use", "used", "using", "you", "your", "ают", "are", "was", "were",
        "bir", "bu", "this", "ile", "for", "olan", "veya", "gibi", "daha",
        "sonra", "before", "ama", "her", "many", "kullan", "kullanarak",
    ]
}

/// Optional, persisted history of trigger tests, so a description can be tuned
/// across sessions. Off by default — a prompt is user content.
@MainActor
final class SkillTriggerHistory: ObservableObject {
    /// Shared so a skill's card can show the last test that mentioned it.
    static let shared = SkillTriggerHistory()

    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID
        var prompt: String
        var agent: ExtensionAgentID
        var matchedNames: [String]
        var verdict: String
        var testedAt: Date

        init(
            id: UUID = UUID(),
            prompt: String,
            agent: ExtensionAgentID,
            matchedNames: [String],
            verdict: String,
            testedAt: Date
        ) {
            self.id = id
            self.prompt = prompt
            self.agent = agent
            self.matchedNames = matchedNames
            self.verdict = verdict
            self.testedAt = testedAt
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var isEnabled: Bool

    private let fileURL: URL

    init(layout: ExtensionStoreLayout = .default(), isEnabled: Bool = false) {
        fileURL = layout.scans.appendingPathComponent("trigger-tests.json")
        self.isEnabled = isEnabled
        load()
    }

    func record(_ result: SkillTriggerTester.Result) {
        guard isEnabled else { return }
        entries.insert(
            Entry(
                prompt: result.prompt,
                agent: result.agent,
                matchedNames: result.matches.map(\.candidate.name),
                verdict: result.verdict.label,
                testedAt: result.testedAt
            ),
            at: 0
        )
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        save()
    }

    /// Clearing also removes the file: turning history off must not leave old
    /// prompts behind on disk.
    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        AtomicFile.write(data, to: fileURL)
    }
}
