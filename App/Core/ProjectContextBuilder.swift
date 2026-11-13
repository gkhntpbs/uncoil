import Foundation

/// What Uncoil tells an agent about the project it was started in.
///
/// One block, made of sections, handed to the agent at launch (Claude's
/// `--append-system-prompt`, Codex's `developer_instructions`) and returned by
/// `uncoil_projects {"action":"context"}` for a session that wants the current
/// answer. Remote hosts are the only section today; another kind of project
/// knowledge Uncoil comes to manage is one more section here, and every agent
/// gets it the same way.
///
/// Only ever the project's own hosts. Handing every session the global list
/// would tell an agent working on a personal site about production machines
/// it has no business near.
enum ProjectContextBuilder {
    struct Section: Equatable {
        var title: String
        var body: String
    }

    static func build(for project: Project, hosts: [SSHHost]) -> String? {
        let sections = [sshSection(for: project, hosts: hosts)].compactMap { $0 }
        guard !sections.isEmpty else { return nil }
        return sections.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    static let uncoilToolsSection = Section(
        title: "Uncoil tools",
        body: """
        You run inside Uncoil. Use its MCP tools when the task needs Uncoil-managed state: \
        sessions (uncoil_sessions), worktrees (uncoil_projects), tasks (uncoil_tasks), \
        dev servers (uncoil_run), or its browser (uncoil_browser). Use your normal tools for \
        repository inspection, editing, builds and tests. The user's instructions and project \
        rules take precedence; MCP availability does not require extra tool calls.
        Work in the current session by default. Do not create or delegate to other agents unless \
        the user or project instructions ask for it. When authorized, reuse an appropriate existing \
        session, give each worker a bounded task, and use an idempotency_key when creating one. \
        Use events with wait_s to follow a session rather than repeatedly polling its output. \
        A child reports results with report_to_parent; the parent reads them with read_reports. \
        A delivered prompt is not proof that the task finished.
        Every tool takes {"action": …}; request help only for the tool/action you need. \
        On PERMISSION_REQUIRED, call uncoil_system request_permission with the returned grant_key \
        and target. It opens an approval window and waits for the user's decision. Continue only \
        after approval; do not repeat a denied request or bypass a disabled capability.
        """
    )

    static func withUncoilTools(_ context: String?) -> String {
        let tools = "## \(uncoilToolsSection.title)\n\(uncoilToolsSection.body)"
        guard let context, !context.isEmpty else { return tools }
        return tools + "\n\n" + context
    }

    /// The hosts associated with `project`, in the project's own order.
    static func hosts(for project: Project, in hosts: [SSHHost]) -> [SSHHost] {
        (project.sshHostAliases ?? []).compactMap { alias in hosts.first { $0.alias == alias } }
    }

    static func sshSection(for project: Project, hosts all: [SSHHost]) -> Section? {
        let hosts = hosts(for: project, in: all)
        guard !hosts.isEmpty else { return nil }
        let lines = hosts.map(line(for:))
        let body = lines.joined(separator: "\n") + "\n"
            + "Connect with `ssh <alias>`; these aliases are configured in the user's SSH config. "
            + "Only use them when the task needs it. "
            + "Call uncoil_projects {\"action\":\"context\"} for the current list if it may have changed."
        return Section(title: "Remote hosts for this project (from Uncoil)", body: body)
    }

    static func line(for host: SSHHost) -> String {
        var text = "- \(host.alias)"
        if let note = host.trimmedNote {
            text += " — " + note.replacingOccurrences(of: "\n", with: " ")
        }
        if let destination = host.destinationSummary { text += " (\(destination))" }
        return text
    }
}
