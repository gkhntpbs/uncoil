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
