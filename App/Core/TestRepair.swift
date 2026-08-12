import Foundation

/// Routes a failing test suite to a coding agent.
///
/// Peer of `RunRepair`, and deliberately *not* the same in one respect: this
/// opens a new session rather than talking into whichever agent happened to be
/// active. A failure is its own piece of work — dropping it into a session
/// halfway through something else buries both — and a fresh session starts on
/// the user's default provider and settings, with nothing in its context to
/// argue with.
///
/// What differs is the instruction. A failed run is a configuration to repair;
/// a failed test is a claim about the code, and the agent is told to find out
/// which of the two is wrong before changing either. An agent that "fixes" a
/// suite by weakening its assertions has done the one thing nobody wanted.
@MainActor
enum TestRepair {
    /// How many failures travel with the prompt. Enough to show the shape of a
    /// breakage, few enough that the agent's context is not spent on a list.
    static let failureLimit = 10

    /// The whole suite, or one test of it when `focus` names one.
    static func prompt(
        suite: TestSuiteConfiguration,
        record: TestRunRecord,
        focus: TestCaseResult? = nil,
        language: PromptLanguage = .english
    ) -> String {
        var lines: [String] = []
        if let focus {
            lines.append(
                "The test '\(focus.id)' in the project's '\(suite.id)' suite is failing. "
                    + "Work out why and fix it."
            )
        } else if record.summary.isDetailed {
            lines.append(
                "\(record.summary.failed) of \(record.summary.total) tests in the project's "
                    + "'\(suite.id)' suite are failing. Work out why and fix them."
            )
        } else {
            lines.append(
                "The project's '\(suite.id)' suite failed. Work out why and fix it."
            )
        }
        lines.append("Command: \(suite.command) (in \(suite.cwd), \(suite.framework.displayName))")

        let failures = focus.map { [$0] } ?? Array(record.failedCases.prefix(failureLimit))
        if !failures.isEmpty {
            lines.append("Failing:")
            for failure in failures {
                var line = "- \(failure.id)"
                if let message = failure.message, !message.isEmpty {
                    line += ": \(message.replacingOccurrences(of: "\n", with: " "))"
                }
                lines.append(line)
            }
            let remaining = record.failedCases.count - failures.count
            if focus == nil, remaining > 0 {
                lines.append("- …and \(remaining) more")
            }
        }
        // Artifacts are paths rather than contents: the agent can open the ones
        // it wants, and a screenshot pasted into a prompt is unreadable anyway.
        let artifacts = (focus?.artifacts ?? record.allArtifacts).prefix(5)
        if !artifacts.isEmpty {
            lines.append("The run wrote: \(artifacts.map(\.path).joined(separator: ", "))")
        }
        // Said, not implied. This is the failure mode that matters: a suite
        // turned green by deleting what it was checking is worse than a red one.
        lines.append(
            "Decide first whether the test or the code is wrong, and say which. Do not weaken "
                + "or delete an assertion to make it pass; if the test is the thing that is wrong, "
                + "explain why before changing it."
        )
        lines.append(mcpNote(suiteID: suite.id))
        if !record.summary.isDetailed, !record.logTail.isEmpty {
            // The only thing that explains a failure nobody parsed.
            lines.append("Last output:\n\(record.logTail.suffix(1200))")
        }
        if let directive = language.directive {
            lines.append(directive)
        }
        return lines.joined(separator: "\n")
    }

    /// What the agent can drive this suite with.
    ///
    /// Spelled out rather than left to be discovered: a fresh session has no
    /// idea Uncoil is holding its results, and an agent that does not know
    /// about `test_run` re-runs the suite by hand and reads its own scrollback.
    static func mcpNote(suiteID: String) -> String {
        [
            "Uncoil's MCP drives the tests for you, under the uncoil_run tool:",
            "- {\"action\":\"test_run\",\"id\":\"\(suiteID)\"} runs the suite and returns its"
                + " result: per-test failures with their messages, the files it wrote, and the"
                + " exit code.",
            "- {\"action\":\"test_results\",\"id\":\"\(suiteID)\"} is the last result without"
                + " running anything.",
            "- {\"action\":\"test_list\"} is every suite of this project,"
                + " {\"action\":\"test_update\"} edits one in .uncoil/tests.json, and"
                + " {\"action\":\"help\"} documents all of them.",
            "Use test_run to check your fix — at most 3 rounds — and report what you changed.",
        ].joined(separator: "\n")
    }

    /// Opens a session for this failure and hands it the prompt.
    @discardableResult
    static func dispatch(
        project: Project,
        suite: TestSuiteConfiguration,
        record: TestRunRecord,
        focus: TestCaseResult? = nil,
        projectStore: ProjectStore,
        provider: AgentProvider,
        language: PromptLanguage = .english
    ) -> SessionRecord {
        let text = prompt(suite: suite, record: record, focus: focus, language: language)
        let session = projectStore.createSession(
            projectID: project.id,
            provider: provider,
            // Default account and default launch settings: the user's own
            // defaults are what a session opened on their behalf should use.
            accountID: nil,
            title: title(suite: suite, focus: focus)
        )
        MainRoute.shared.request(.session(session.id))
        Task {
            await TerminalRegistry.shared.submitText(
                text, for: session.id, provider: session.provider, namesTheSession: false
            )
        }
        return session
    }

    /// What the new session is called in the sidebar. Names the thing that is
    /// wrong, so a row full of sessions still says which failure is which.
    static func title(suite: TestSuiteConfiguration, focus: TestCaseResult?) -> String {
        if let focus { return "fix \(focus.name)" }
        return "fix \(suite.name)"
    }
}
