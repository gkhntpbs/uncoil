import Foundation

/// What a session hands back to the run at the end of its turn.
///
/// Every role ends its reply with one fenced `uncoil-handoff` block of JSON.
/// The block is the structured result; the prose around it is for whoever
/// opens the session. A reply without a block is still a result — its text,
/// clipped, becomes the summary — so an agent that forgets the format slows
/// the run down without breaking it.
struct AutoHandoff: Codable, Equatable {
    var summary: String?
    /// done, partial, failed, blocked.
    var status: String?
    /// Explorer: relevant files. Worker: changed files.
    var files: [String]?
    var findings: [String]?
    var risks: [String]?
    var nextSteps: [String]?
    var sources: [String]?
    var constraints: [String]?
    /// Worker: what it ran to check its work, and how that went.
    var tests: [String]?
    var errors: [String]?
    var remaining: [String]?
    /// Advisor: proceed, revise or stop.
    var verdict: String?
    var concerns: [String]?
    /// Main: the plan, step by step.
    var plan: [String]?
    /// Main: what the Worker is asked to do. Empty ⇒ nothing to implement.
    var workerTask: String?

    /// Whether the text carried a block at all.
    var structured = true

    enum CodingKeys: String, CodingKey {
        case summary, status, files, findings, risks, sources, constraints, tests, errors, remaining
        case verdict, concerns, plan
        case nextSteps = "next_steps"
        case workerTask = "worker_task"
    }

    static let fence = "uncoil-handoff"
    static let summaryLimit = 1_500

    init(summary: String? = nil, status: String? = nil, structured: Bool = true) {
        self.summary = summary
        self.status = status
        self.structured = structured
    }

    /// Strings or lists of strings: agents write both.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let list = try? container.decodeIfPresent([String].self, forKey: key) { return list.joined(separator: "\n") }
            return nil
        }
        func list(_ key: CodingKeys) -> [String]? {
            if let value = try? container.decodeIfPresent([String].self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value.isEmpty ? [] : [value] }
            if let objects = try? container.decodeIfPresent([JSONValue].self, forKey: key) {
                return objects.map(Self.describe)
            }
            return nil
        }
        summary = text(.summary)
        status = text(.status)?.lowercased()
        files = list(.files)
        findings = list(.findings)
        risks = list(.risks)
        nextSteps = list(.nextSteps)
        sources = list(.sources)
        constraints = list(.constraints)
        tests = list(.tests)
        errors = list(.errors)
        remaining = list(.remaining)
        verdict = text(.verdict)?.lowercased()
        concerns = list(.concerns)
        plan = list(.plan)
        workerTask = text(.workerTask)
    }

    private static func describe(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The last handoff block in `text`, or the text itself as a summary.
    static func parse(_ text: String) -> AutoHandoff {
        if let json = lastBlock(in: text),
           let data = json.data(using: .utf8),
           let handoff = try? JSONDecoder().decode(AutoHandoff.self, from: data) {
            return handoff
        }
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AutoHandoff(
            summary: prose.isEmpty ? nil : String(prose.prefix(summaryLimit)),
            structured: false)
    }

    private static func lastBlock(in text: String) -> String? {
        guard let open = text.range(of: "```\(fence)", options: .backwards) else { return nil }
        let rest = text[open.upperBound...]
        let body = rest.range(of: "```").map { rest[..<$0.lowerBound] } ?? rest
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The handoff as a short note for the conversation and for the next prompt.
    func digest(limit: Int = 3_000) -> String {
        var parts: [String] = []
        if let summary, !summary.isEmpty { parts.append(summary) }
        func section(_ title: String, _ items: [String]?) {
            guard let items, !items.isEmpty else { return }
            parts.append("\(title):\n" + items.prefix(12).map { "- \($0)" }.joined(separator: "\n"))
        }
        if let status { parts.append("Status: \(status)") }
        if let verdict { parts.append("Verdict: \(verdict)") }
        section("Files", files)
        section("Findings", findings)
        section("Plan", plan)
        section("Risks", risks)
        section("Concerns", concerns)
        section("Constraints", constraints)
        section("Sources", sources)
        section("Tests", tests)
        section("Errors", errors)
        section("Remaining", remaining)
        section("Next steps", nextSteps)
        let text = parts.joined(separator: "\n\n")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

/// What each role is told. The built-in instructions are the defaults the
/// user can replace per role in Settings; the handoff contract is always
/// added, because the run reads it.
enum AutoPrompts {
    static func defaultInstructions(for role: AutoRole) -> String {
        switch role {
        case .explorer:
            """
            You are the Explorer in an Uncoil Auto run. Investigate the repository for the task below and report only what the main agent needs: the relevant files, how the existing architecture works around them, call sites, tests, dependencies and likely risks. Do not change any file. Be concise: your report replaces a long search, it must not repeat it.
            """
        case .researcher:
            """
            You are the Researcher in an Uncoil Auto run. Find the outside information the task below depends on — documentation, SDK or API behaviour, release notes, framework changes, known issues. Cite your sources and say which versions they apply to. Do not change any file. Return a concise result, not your whole search.
            """
        case .worker:
            """
            You are the Worker in an Uncoil Auto run. Implement exactly the brief below, in the working directory you were started in. Build and run the relevant tests yourself, fix what fails, and report honestly what you changed, what you ran and what is still wrong. Do not commit, push or merge.
            """
        case .advisor:
            """
            You are the Advisor in an Uncoil Auto run: a rare, deep second opinion. Read the packet below and judge the approach, not the details. Is it targeting the right problem? Are there architectural risks, missing requirements, regressions or untested paths? Are repeated failures a sign the wrong layer is being debugged? Do not change any file.
            """
        }
    }

    static func contract(for role: AutoRole) -> String {
        let fields: String
        switch role {
        case .explorer:
            fields = #""summary": "...", "files": ["path — why it matters"], "findings": ["..."], "risks": ["..."], "next_steps": ["..."]"#
        case .researcher:
            fields = #""summary": "...", "sources": ["url or reference"], "constraints": ["..."], "findings": ["version-specific facts"], "next_steps": ["recommendations"]"#
        case .worker:
            fields = #""status": "done | partial | failed | blocked", "summary": "...", "files": ["changed paths"], "tests": ["command — result"], "errors": ["..."], "remaining": ["..."]"#
        case .advisor:
            fields = #""verdict": "proceed | revise | stop", "summary": "...", "concerns": ["..."], "next_steps": ["..."]"#
        }
        return """
        End your reply with exactly one fenced block in this form, valid JSON, and nothing after it:
        ```\(AutoHandoff.fence)
        {\(fields)}
        ```
        """
    }

    static func specialist(_ role: AutoRole, instructions: String, body: String) -> String {
        let lead = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            lead.isEmpty ? defaultInstructions(for: role) : lead,
            body,
            contract(for: role),
        ].joined(separator: "\n\n")
    }

    // MARK: - Main

    static let mainContract = """
    End your reply with exactly one fenced block in this form, valid JSON, and nothing after it:
    ```\(AutoHandoff.fence)
    {"summary": "...", "plan": ["step"], "worker_task": "the complete, self-contained brief for the Worker, or empty if nothing needs to change", "risks": ["..."]}
    ```
    """

    static func plan(task: String, findings: [(role: AutoRole, handoff: AutoHandoff)], notes: [String]) -> String {
        var parts = [
            "Uncoil Auto is running this task with you as the main agent. You own the plan and the final answer; specialists do focused work for you.",
            "Task:\n\(task)",
        ]
        for finding in findings {
            parts.append("\(finding.role.displayName) report:\n\(finding.handoff.digest())")
        }
        parts += notes
        parts.append("Write the plan. Do not implement it yourself: the Worker will, from your brief, in its own session. The brief must stand on its own — the Worker has not seen this conversation.")
        parts.append(mainContract)
        return parts.joined(separator: "\n\n")
    }

    static func revisePlan(concerns: AutoHandoff) -> String {
        """
        The Advisor reviewed your plan before any work started:

        \(concerns.digest())

        Revise the plan if you agree, or keep it and say why.

        \(mainContract)
        """
    }

    static func rebrief(failure: String, worker: AutoHandoff) -> String {
        """
        The Worker's change did not pass verification and was sent back to you.

        Worker report:
        \(worker.digest())

        Verification:
        \(failure)

        Decide what the Worker should do instead and write a new, complete brief.

        \(mainContract)
        """
    }

    static func implementYourself(task: String) -> String {
        """
        No Worker is enabled for Uncoil Auto, so implement the plan yourself now, then build and test it.

        Task:
        \(task)

        \(contract(for: .worker))
        """
    }

    static func finalReview(worker: AutoHandoff?, verification: String, advisor: AutoHandoff?, worktree: String?) -> String {
        var parts = ["The Auto run's work is finished. Review it and give the user the final answer: what changed, how it was verified, and anything still open."]
        if let worker { parts.append("Worker report:\n\(worker.digest())") }
        parts.append("Verification:\n\(verification)")
        if let advisor { parts.append("Advisor's final review:\n\(advisor.digest())") }
        if let worktree {
            parts.append("The changes are in the worktree at \(worktree), on its own branch. They are not merged; merging is the user's decision.")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Worker and Advisor

    static func workerBrief(task: String, brief: String, worktree: String?) -> String {
        var body = "Brief:\n\(brief)\n\nOriginal task, for context:\n\(task)"
        if let worktree { body += "\n\nYou are working in an isolated worktree: \(worktree)." }
        return body
    }

    static func workerRetry(failure: String, advice: AutoHandoff?) -> String {
        var parts = ["Verification failed:\n\(failure)"]
        if let advice { parts.append("An Advisor reviewed the repeated failure:\n\(advice.digest())") }
        parts.append("Fix the cause, rebuild and rerun the tests.")
        parts.append(contract(for: .worker))
        return parts.joined(separator: "\n\n")
    }

    static func advisorPacket(checkpoint: AutoAdvisorCheckpoint, task: String, sections: [(String, String)]) -> String {
        var body = "Checkpoint: \(checkpoint.rawValue)\n\nTask:\n\(task)"
        for (title, text) in sections where !text.isEmpty {
            body += "\n\n\(title):\n\(text)"
        }
        return body
    }
}

/// Where in a run the Advisor is consulted.
enum AutoAdvisorCheckpoint: String, Codable {
    case prePlan = "pre_plan"
    case repeatedFailure = "repeated_failure"
    case preCompletion = "pre_completion"
}
