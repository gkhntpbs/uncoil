import Foundation

/// Everything chosen before a task is handed to an agent.
struct TaskDispatchRequest: Equatable {
    var provider: AgentProvider = .claude
    var accountID: UUID?
    var model: String?
    var effort: String?
    var workingMode: AgentWorkingMode?
    /// When false the prompt is typed into the session but not submitted: the
    /// user reads it, edits if they like, and presses Enter themselves.
    var autoStart = true
    /// Named preset to launch with; when set, its arguments and capabilities win.
    var presetID: String?
    /// Capability grants the session should get, by name.
    var permissionProfile: [String] = []
    var role: TaskAgentRole = .implementer
    /// Create a fresh worktree for this task, and what to call it.
    var createsWorktree = false
    var worktreeName: String?
    /// An existing worktree to run in.
    var worktreePath: String?
    /// Reuse a live session instead of creating one.
    var existingSessionID: UUID?

    var isExistingSession: Bool { existingSessionID != nil }
}

/// Builds the prompt an agent receives for a task.
///
/// A task title alone is not enough context to act on: the agent is told where
/// the work lives, what the file already says, what role it is playing, and the
/// rules it must respect — above all that `TODO.md` belongs to the user and its
/// formatting must survive.
enum TaskPromptBuilder {
    struct Context: Equatable {
        var projectName: String
        var projectPath: String
        var sourcePath: String
        var headingPath: [String]
        var rawBlock: String
        /// Raw blocks of the task's nested children, in file order.
        var subtaskBlocks: [String]
        var role: TaskAgentRole
        var worktreePath: String?
        var permissionProfile: [String]
        /// True when the control plane exposes the Tasks MCP to this session.
        var tasksMCPAvailable: Bool
        var taskID: String
        /// The language the agent is asked to answer in. The prompt itself stays
        /// English; only the closing directive changes.
        var language: PromptLanguage = .english
    }

    static func context(
        for task: ProjectTask,
        in document: TaskDocument,
        project: Project,
        role: TaskAgentRole,
        worktreePath: String?,
        permissionProfile: [String],
        tasksMCPAvailable: Bool = true,
        language: PromptLanguage = .english
    ) -> Context {
        Context(
            projectName: project.name,
            projectPath: project.rootPath,
            sourcePath: task.sourcePath,
            headingPath: task.headingPath,
            rawBlock: task.rawBlock.trimmingCharacters(in: .whitespacesAndNewlines),
            subtaskBlocks: task.childIDs.compactMap { childID in
                document.task(id: childID)?.rawBlock
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            },
            role: role,
            worktreePath: worktreePath,
            permissionProfile: permissionProfile,
            tasksMCPAvailable: tasksMCPAvailable,
            taskID: task.id,
            language: language
        )
    }

    static func prompt(_ context: Context) -> String {
        var lines: [String] = []

        lines.append("## Task")
        lines.append("")
        lines.append("Project: \(context.projectName)")
        lines.append("Project path: \(context.projectPath)")
        lines.append("TODO file: \(context.sourcePath)")
        if !context.headingPath.isEmpty {
            lines.append("Heading path: \(context.headingPath.joined(separator: " › "))")
        }
        lines.append("Role: \(context.role.label)")
        if let worktreePath = context.worktreePath {
            lines.append("Worktree: \(worktreePath)")
            lines.append("Do not change anything outside this worktree.")
        }
        if !context.permissionProfile.isEmpty {
            lines.append("Permission profile: \(context.permissionProfile.sorted().joined(separator: ", "))")
        }

        lines.append("")
        lines.append("### Task block")
        lines.append("")
        lines.append(context.rawBlock)

        if !context.subtaskBlocks.isEmpty {
            lines.append("")
            lines.append("### Subtasks")
            lines.append("")
            lines.append(contentsOf: context.subtaskBlocks)
        }

        lines.append("")
        lines.append("### Rules")
        lines.append("")
        lines.append(contentsOf: rules(context))

        return lines.joined(separator: "\n")
    }

    /// The rules every dispatched task carries. Role-specific first, then the
    /// ones that protect the user's file and describe how to report back.
    static func rules(_ context: Context) -> [String] {
        var rules: [String] = []
        switch context.role {
        case .reviewer:
            rules.append("- Do not write code; review only and report your findings.")
            rules.append("- Do not tick the checkbox yourself.")
        case .tester:
            rules.append("- Run the tests and report the output verbatim.")
            rules.append("- Do not treat the task as done until the tests pass.")
        case .observer:
            rules.append("- Do not modify any file; report the state only.")
        case .orchestrator:
            rules.append("- Break the work into subtasks; open child sessions if needed.")
            rules.append("- Collect the child sessions' results and report them as one.")
        case .owner, .implementer:
            rules.append("- Carry out the task and explain what you changed.")
            rules.append("- Run the related tests; do not call it done unless they pass.")
        }

        // The file belongs to the user: these two rules are never omitted.
        rules.append(
            "- Preserve `TODO.md`'s formatting: change only the relevant line, never regenerate the file."
        )
        rules.append(
            "- Leave headings, indentation, blank lines, comments and code blocks exactly as they are."
        )
        if context.role.writes {
            rules.append(
                "- When the task is genuinely finished write `- [x]` in place of `- [ ]`; use no other marker."
            )
        }
        if context.tasksMCPAvailable {
            rules.append(
                "- Report progress through the `uncoil_tasks` MCP tool (report_progress / complete / block)."
            )
            rules.append("- This task's id: \(context.taskID)")
        } else {
            rules.append("- Report progress as a message; the Tasks MCP is off for this session.")
        }
        if let directive = context.language.directive {
            rules.append("- \(directive)")
        }
        return rules
    }

    /// Warning shown when a task would be handed to a session belonging to
    /// another project — the agent's working directory would not match the file.
    static func crossProjectWarning(
        sessionProjectName: String,
        taskProjectName: String
    ) -> String? {
        guard sessionProjectName != taskProjectName else { return nil }
        return String(
            localized: """
            This session belongs to \(sessionProjectName) but the task comes from \
            \(taskProjectName). The agent's working directory will not match the task's file.
            """
        )
    }

    /// Sessions that can take a task: live, and preferably in the same project.
    static func eligibleSessions(
        _ sessions: [SessionRecord],
        statuses: [UUID: AgentSessionStatus],
        taskProjectID: UUID
    ) -> (sameProject: [SessionRecord], otherProjects: [SessionRecord]) {
        let live = sessions.filter { record in
            record.provider != .terminal && statuses[record.id] != .terminated
        }
        return (
            live.filter { $0.projectID == taskProjectID },
            live.filter { $0.projectID != taskProjectID }
        )
    }

    /// Suggested worktree name for a task: short, slug-safe, recognisable.
    static func worktreeName(for task: ProjectTask) -> String {
        let words = TaskFingerprint.normalize(task.text)
            .split(separator: " ")
            .prefix(4)
            .joined(separator: "-")
        let slug = words.isEmpty ? "task" : words
        return String(slug.prefix(40))
    }
}
