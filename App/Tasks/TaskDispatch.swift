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
    }

    static func context(
        for task: ProjectTask,
        in document: TaskDocument,
        project: Project,
        role: TaskAgentRole,
        worktreePath: String?,
        permissionProfile: [String],
        tasksMCPAvailable: Bool = true
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
            taskID: task.id
        )
    }

    static func prompt(_ context: Context) -> String {
        var lines: [String] = []

        lines.append("## Görev")
        lines.append("")
        lines.append("Proje: \(context.projectName)")
        lines.append("Proje yolu: \(context.projectPath)")
        lines.append("TODO dosyası: \(context.sourcePath)")
        if !context.headingPath.isEmpty {
            lines.append("Başlık zinciri: \(context.headingPath.joined(separator: " › "))")
        }
        lines.append("Rol: \(context.role.label)")
        if let worktreePath = context.worktreePath {
            lines.append("Worktree: \(worktreePath)")
            lines.append("Bu worktree dışında değişiklik yapma.")
        }
        if !context.permissionProfile.isEmpty {
            lines.append("İzin profili: \(context.permissionProfile.sorted().joined(separator: ", "))")
        }

        lines.append("")
        lines.append("### Görev bloğu")
        lines.append("")
        lines.append(context.rawBlock)

        if !context.subtaskBlocks.isEmpty {
            lines.append("")
            lines.append("### Alt görevler")
            lines.append("")
            lines.append(contentsOf: context.subtaskBlocks)
        }

        lines.append("")
        lines.append("### Kurallar")
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
            rules.append("- Kod yazma; yalnızca incele ve bulgularını bildir.")
            rules.append("- Checkbox'ı sen işaretleme.")
        case .tester:
            rules.append("- Testleri çalıştır ve çıktıyı olduğu gibi bildir.")
            rules.append("- Test geçmedikçe görevi tamamlandı sayma.")
        case .observer:
            rules.append("- Hiçbir dosyayı değiştirme; yalnızca durumu bildir.")
        case .orchestrator:
            rules.append("- İşi alt görevlere böl, gerekiyorsa alt oturum aç.")
            rules.append("- Alt oturumların sonuçlarını topla ve tek raporda bildir.")
        case .owner, .implementer:
            rules.append("- Görevi uygula ve değişiklikleri açıkla.")
            rules.append("- İlgili testleri çalıştır; geçmezse tamamlandı sayma.")
        }

        // The file belongs to the user: these two rules are never omitted.
        rules.append(
            "- `TODO.md` biçimini koru: yalnızca ilgili satırı değiştir, dosyayı yeniden üretme."
        )
        rules.append(
            "- Başlıkları, girintileri, boş satırları, yorumları ve code block'ları olduğu gibi bırak."
        )
        if context.role.writes {
            rules.append(
                "- Görev gerçekten bittiğinde `- [ ]` yerine `- [x]` yaz; başka bir işaret kullanma."
            )
        }
        if context.tasksMCPAvailable {
            rules.append(
                "- İlerlemeyi `uncoil_tasks` MCP aracıyla bildir (report_progress / complete / block)."
            )
            rules.append("- Bu görevin kimliği: \(context.taskID)")
        } else {
            rules.append("- İlerlemeyi mesaj olarak bildir; Tasks MCP bu oturumda kapalı.")
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
        return """
        Bu oturum \(sessionProjectName) projesine ait, görev ise \(taskProjectName) \
        projesinden. Agent'ın çalışma dizini görevin dosyasıyla eşleşmeyecek.
        """
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
