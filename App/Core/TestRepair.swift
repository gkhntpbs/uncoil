import AppKit
import Foundation

/// Routes a failing test suite to a coding agent.
///
/// Peer of `RunRepair`, and deliberately the same shape: a prompt that points
/// the agent at the `uncoil_run` MCP tool, submitted to the project's most
/// recently active agent session, falling back to the clipboard when there is
/// no live agent to hand it to.
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
        lines.append(
            "Re-run with the uncoil_run tool in the Uncoil MCP — "
                + "{\"action\":\"test_run\",\"id\":\"\(suite.id)\"} — until it passes "
                + "(at most 3 rounds), then report what you changed."
        )
        if !record.summary.isDetailed, !record.logTail.isEmpty {
            // The only thing that explains a failure nobody parsed.
            lines.append("Last output:\n\(record.logTail.suffix(1200))")
        }
        if let directive = language.directive {
            lines.append(directive)
        }
        return lines.joined(separator: "\n")
    }

    /// Returns true when the prompt was handed to a session; false when it was
    /// copied to the clipboard instead.
    @discardableResult
    static func dispatch(
        project: Project,
        suite: TestSuiteConfiguration,
        record: TestRunRecord,
        focus: TestCaseResult? = nil,
        projectStore: ProjectStore,
        language: PromptLanguage = .english
    ) -> Bool {
        let text = prompt(suite: suite, record: record, focus: focus, language: language)
        guard let session = RunRepair.candidateSession(
            project: project, projectStore: projectStore
        ) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return false
        }
        MainRoute.shared.request(.session(session.id))
        Task {
            await TerminalRegistry.shared.submitText(
                text, for: session.id, provider: session.provider, namesTheSession: false
            )
        }
        return true
    }
}
