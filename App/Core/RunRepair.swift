import AppKit
import Foundation

/// Routes a failed run to a coding agent: builds a repair prompt that points
/// the agent at the `uncoil_run` MCP tool, submits it to the project's most
/// recently active agent session, and focuses that session. Falls back to the
/// clipboard when the project has no live agent to hand the problem to.
@MainActor
enum RunRepair {
    static func prompt(
        config: RunConfiguration,
        issue: RunIssue?,
        logTail: String,
        language: PromptLanguage = .english
    ) -> String {
        let tail = logTail.suffix(1200)
        var lines = [
            "The project's '\(config.id)' run configuration failed; repair it with the uncoil_run tool in the Uncoil MCP.",
            "Diagnosis: \(issue.map { "\($0.code) — \($0.hint)" } ?? "none")",
            "Steps: inspect the failure with {\"action\":\"status\",\"id\":\"\(config.id)\"} and {\"action\":\"logs\",\"id\":\"\(config.id)\"},",
            "repair the configuration in .uncoil/run.json with {\"action\":\"update\",\"configuration\":{...}} if needed,",
            "then retry with {\"action\":\"start\",\"id\":\"\(config.id)\"}; repeat until it runs (at most 3 rounds) and report the result.",
        ]
        if !tail.isEmpty {
            lines.append("Last output:\n\(tail)")
        }
        if let directive = language.directive {
            lines.append(directive)
        }
        return lines.joined(separator: "\n")
    }

    /// The best session to hand the repair to: a live agent (not a plain
    /// terminal) in this project, most recently active first.
    static func candidateSession(project: Project, projectStore: ProjectStore) -> SessionRecord? {
        projectStore.sessions
            .filter { $0.projectID == project.id && $0.provider != .terminal && $0.endedAt == nil }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// Returns true when the prompt was handed to a session; false when it was
    /// copied to the clipboard instead.
    @discardableResult
    static func dispatch(
        project: Project,
        config: RunConfiguration,
        issue: RunIssue?,
        logTail: String,
        projectStore: ProjectStore,
        language: PromptLanguage = .english
    ) -> Bool {
        let text = prompt(config: config, issue: issue, logTail: logTail, language: language)
        guard let session = candidateSession(project: project, projectStore: projectStore) else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }
        MainRoute.shared.request(.session(session.id))
        Task {
            await TerminalRegistry.shared.submitText(text, for: session.id, provider: session.provider)
        }
        return true
    }
}
