import Foundation

/// Human-readable metadata for every control-plane capability grant key, so the
/// Settings → İzinler pane can present grants as labelled, grouped toggles. The
/// catalog is total: `entry(for:)` returns non-nil for every key in
/// `PolicyEngine.defaultGrants ∪ PolicyEngine.optionalGrants` (asserted by a
/// unit test). Pure data — no view dependencies — so it stays testable.
enum CapabilityCatalog {
    /// Capability domains, in display order.
    enum Domain: String, CaseIterable, Identifiable {
        case projects, worktrees, sessions, tasks, runs, browser, computer, artifacts
        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Projects"
            case .worktrees: "Worktree"
            case .sessions: "Sessions"
            case .tasks: "Tasks"
            case .runs: "Run"
            case .browser: "Browser"
            case .computer: "Bilgisayar"
            case .artifacts: "Artifact"
            }
        }

        var iconName: String {
            switch self {
            case .projects: "folders"
            case .worktrees: "git-branch"
            case .sessions: "messages"
            case .tasks: "list-check"
            case .runs: "player-play"
            case .browser: "world"
            case .computer: "device-desktop"
            case .artifacts: "file-text"
            }
        }
    }

    struct Entry: Identifiable {
        let key: String
        let domain: Domain
        let label: String
        let detail: String
        /// Elevated-risk grant: control that reaches beyond the agent's own
        /// sandbox (foreground control, cross-project, other sessions, personal
        /// browser profile). Surfaced with a warning hint in the UI.
        let risky: Bool

        var id: String { key }
    }

    /// Every grant key the policy engine understands, with Turkish labels.
    static let all: [Entry] = [
        .init(key: "projects.read", domain: .projects,
              label: "Projeleri oku",
              detail: "Sees the project list and its metadata.", risky: false),

        .init(key: "worktrees.read", domain: .worktrees,
              label: "Worktree'leri oku",
              detail: "Mevcut worktree'leri listeler.", risky: false),
        .init(key: "worktrees.create", domain: .worktrees,
              label: "Create a worktree",
              detail: "Can open a new git worktree.", risky: false),

        .init(key: "sessions.read", domain: .sessions,
              label: "Read sessions",
              detail: "Sees the sessions in the same project.", risky: false),
        .init(key: "sessions.read_all", domain: .sessions,
              label: "Read every session",
              detail: "Sees sessions in other projects too.", risky: true),
        .init(key: "sessions.control_children", domain: .sessions,
              label: "Manage child sessions",
              detail: "Sends input to, and closes, the child sessions it started itself.", risky: false),
        .init(key: "sessions.control_all", domain: .sessions,
              label: "Manage sessions",
              detail: "Sends input to other sessions, interrupts and closes them.", risky: false),
        .init(key: "sessions.create_children", domain: .sessions,
              label: "Create a child session",
              detail: "Can start new child sessions from presets.", risky: false),
        .init(key: "sessions.cross_project", domain: .sessions,
              label: "Cross-project session",
              detail: "Can interact with sessions in different projects.", risky: true),
        .init(key: "sessions.organize", domain: .sessions,
              label: "Edit sessions",
              detail: "Creates groups and moves sessions into them.", risky: false),

        .init(key: "tasks.read", domain: .tasks,
              label: "Read tasks",
              detail: "Reads the project's TODO.md files and task states.", risky: false),
        .init(key: "tasks.write", domain: .tasks,
              label: "Edit tasks",
              detail: "Adds tasks, changes their text, completes and moves them.", risky: false),
        .init(key: "tasks.delete", domain: .tasks,
              label: "Delete a task",
              detail: "Removes the task block from TODO.md; cannot be undone.", risky: true),
        .init(key: "tasks.orchestrate", domain: .tasks,
              label: "Start an agent for a task",
              detail: "Distributes a task across child sessions and collects their results.", risky: true),
        .init(key: "tasks.worktree", domain: .tasks,
              label: "Open a task worktree",
              detail: "Creates a separate git worktree for a task.", risky: false),
        .init(key: "tasks.merge", domain: .tasks,
              label: "Send a task to merge",
              detail: "Prepares the task's branch for merging.", risky: true),

        .init(key: "browser.use", domain: .browser,
              label: "Use the browser",
              detail: "Can drive the managed browser.", risky: false),
        .init(key: "browser.persistent_state", domain: .browser,
              label: "Persistent browser profile",
              detail: "Uses the personal browser profile you are signed in to.", risky: true),

        .init(key: "computer.inspect", domain: .computer,
              label: "Inspect the screen",
              detail: "Takes screenshots, reads the interface.", risky: false),
        .init(key: "computer.background_control", domain: .computer,
              label: "Arka planda kontrol",
              detail: "Controls the focused app without stealing it.", risky: true),
        .init(key: "computer.foreground_control", domain: .computer,
              label: "Foreground control",
              detail: "Takes over your mouse and keyboard — full control.", risky: true),

        .init(key: "runs.read", domain: .runs,
              label: "Read runs",
              detail: "Reads run configurations, their states and their logs.", risky: false),
        .init(key: "runs.write", domain: .runs,
              label: "Edit the configuration",
              detail: "Detects and edits the run configurations in .uncoil/run.json.", risky: false),
        .init(key: "runs.control", domain: .runs,
              label: "Start / stop",
              detail: "Starts and stops the project's dev servers and build processes.", risky: true),

        .init(key: "artifacts.read", domain: .artifacts,
              label: "Artifact oku",
              detail: "Reads session artifacts.", risky: false),
        .init(key: "artifacts.write", domain: .artifacts,
              label: "Artifact yaz",
              detail: "Creates and updates session artifacts.", risky: false),
    ]

    private static let byKey: [String: Entry] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func entry(for key: String) -> Entry? { byKey[key] }

    /// Entries grouped by domain, in domain display order, each preserving the
    /// declared order of `all`.
    static func grouped() -> [(domain: Domain, entries: [Entry])] {
        Domain.allCases.compactMap { domain in
            let entries = all.filter { $0.domain == domain }
            return entries.isEmpty ? nil : (domain, entries)
        }
    }

    /// The full set of keys a session can be granted (default ∪ optional).
    static var allKeys: Set<String> {
        PolicyEngine.defaultGrants.union(PolicyEngine.optionalGrants)
    }
}
