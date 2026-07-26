import AppKit
import Foundation

/// Routes a failed run to a coding agent: builds a repair prompt that points
/// the agent at the `uncoil_run` MCP tool, submits it to the project's most
/// recently active agent session, and focuses that session. Falls back to the
/// clipboard when the project has no live agent to hand the problem to.
@MainActor
enum RunRepair {
    static func prompt(config: RunConfiguration, issue: RunIssue?, logTail: String) -> String {
        let tail = logTail.suffix(1200)
        var lines = [
            "Projenin '\(config.id)' run yapılandırması başarısız oldu; Uncoil MCP'deki uncoil_run aracıyla düzelt.",
            "Teşhis: \(issue.map { "\($0.code) — \($0.hint)" } ?? "yok")",
            "Adımlar: {\"action\":\"status\",\"id\":\"\(config.id)\"} ve {\"action\":\"logs\",\"id\":\"\(config.id)\"} ile hatayı inceleyip",
            "gerekirse {\"action\":\"update\",\"configuration\":{...}} ile .uncoil/run.json'daki yapılandırmayı onar,",
            "sonra {\"action\":\"start\",\"id\":\"\(config.id)\"} ile yeniden dene; çalışana kadar (en fazla 3 tur) yinele ve sonucu raporla.",
        ]
        if !tail.isEmpty {
            lines.append("Son çıktı:\n\(tail)")
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
        projectStore: ProjectStore
    ) -> Bool {
        let text = prompt(config: config, issue: issue, logTail: logTail)
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
