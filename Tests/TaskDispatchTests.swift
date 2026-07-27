import XCTest
@testable import Uncoil

final class TaskPromptBuilderTests: XCTestCase {
    private let projectID = UUID()

    private var document: TaskDocument {
        TodoParser.parse("""
        # Aşama 4

        ## 4.1 Runtime daemon

        - [ ] daemon heartbeat ekle
          Heartbeat aralığı yapılandırılabilir olmalı.
          - [ ] ping komutu
          - [ ] pong yanıtı
        - [ ] log rotation ekle
        """, path: "/repo/TODO.md")
    }

    private var project: Project {
        Project(id: projectID, name: "uncoil", rootPath: "/repo")
    }

    private func context(
        role: TaskAgentRole = .implementer,
        worktreePath: String? = nil,
        permissionProfile: [String] = [],
        tasksMCPAvailable: Bool = true
    ) -> TaskPromptBuilder.Context {
        let document = document
        let task = document.tasks.first { $0.text == "daemon heartbeat ekle" }!
        return TaskPromptBuilder.context(
            for: task, in: document, project: project, role: role,
            worktreePath: worktreePath, permissionProfile: permissionProfile,
            tasksMCPAvailable: tasksMCPAvailable
        )
    }

    // MARK: - Context

    func testContextCarriesEveryDocumentedInput() {
        let context = context(
            worktreePath: "/repo/.uncoil-worktrees/heartbeat",
            permissionProfile: ["sessions.read", "artifacts.write"]
        )
        XCTAssertEqual(context.projectName, "uncoil")
        XCTAssertEqual(context.projectPath, "/repo")
        XCTAssertEqual(context.sourcePath, "/repo/TODO.md")
        XCTAssertEqual(context.headingPath, ["Aşama 4", "4.1 Runtime daemon"])
        XCTAssertTrue(context.rawBlock.contains("daemon heartbeat ekle"))
        XCTAssertTrue(
            context.rawBlock.contains("Heartbeat aralığı"),
            "the attached description travels with the task"
        )
        XCTAssertEqual(context.subtaskBlocks.count, 2)
        XCTAssertEqual(context.role, .implementer)
        XCTAssertEqual(context.worktreePath, "/repo/.uncoil-worktrees/heartbeat")
        XCTAssertEqual(context.permissionProfile, ["sessions.read", "artifacts.write"])
    }

    // MARK: - Prompt

    func testPromptStatesWhereTheWorkLives() {
        let prompt = TaskPromptBuilder.prompt(context())
        XCTAssertTrue(prompt.contains("Project: uncoil"))
        XCTAssertTrue(prompt.contains("Project path: /repo"))
        XCTAssertTrue(prompt.contains("TODO file: /repo/TODO.md"))
        XCTAssertTrue(prompt.contains("Aşama 4 › 4.1 Runtime daemon"))
        XCTAssertTrue(prompt.contains("Role: Implementer"))
    }

    func testPromptIncludesTheRawBlockSubtasksAndDescription() {
        let prompt = TaskPromptBuilder.prompt(context())
        XCTAssertTrue(prompt.contains("- [ ] daemon heartbeat ekle"))
        XCTAssertTrue(prompt.contains("Heartbeat aralığı yapılandırılabilir olmalı."))
        XCTAssertTrue(prompt.contains("Subtasks"))
        XCTAssertTrue(prompt.contains("ping komutu"))
        XCTAssertTrue(prompt.contains("pong yanıtı"))
    }

    func testPromptAlwaysProtectsTheFilesFormatting() {
        for role in TaskAgentRole.allCases {
            let prompt = TaskPromptBuilder.prompt(context(role: role))
            XCTAssertTrue(
                prompt.contains("Preserve `TODO.md`'s formatting"),
                "\(role): the file's formatting rule is never omitted"
            )
            XCTAssertTrue(prompt.contains("never regenerate the file"), role.rawValue)
        }
    }

    func testOnlyWritingRolesAreToldToTickTheCheckbox() {
        XCTAssertTrue(
            TaskPromptBuilder.prompt(context(role: .implementer)).contains("- [x]")
        )
        XCTAssertTrue(TaskPromptBuilder.prompt(context(role: .tester)).contains("- [x]"))
        XCTAssertFalse(TaskPromptBuilder.prompt(context(role: .reviewer)).contains("- [x]"))
        XCTAssertFalse(TaskPromptBuilder.prompt(context(role: .observer)).contains("- [x]"))
    }

    func testRoleSpecificRules() {
        XCTAssertTrue(
            TaskPromptBuilder.prompt(context(role: .reviewer)).contains("review only")
        )
        XCTAssertTrue(
            TaskPromptBuilder.prompt(context(role: .tester)).contains("Run the tests")
        )
        XCTAssertTrue(
            TaskPromptBuilder.prompt(context(role: .observer)).contains("Do not modify any file")
        )
        XCTAssertTrue(
            TaskPromptBuilder.prompt(context(role: .orchestrator)).contains("Break the work into subtasks")
        )
    }

    func testWorktreeAndPermissionProfileAppearWhenSet() {
        let prompt = TaskPromptBuilder.prompt(context(
            worktreePath: "/repo/.uncoil-worktrees/heartbeat",
            permissionProfile: ["artifacts.write", "sessions.read"]
        ))
        XCTAssertTrue(prompt.contains("/repo/.uncoil-worktrees/heartbeat"))
        XCTAssertTrue(prompt.contains("Do not change anything outside this worktree."))
        XCTAssertTrue(prompt.contains("Permission profile: artifacts.write, sessions.read"))

        let plain = TaskPromptBuilder.prompt(context())
        XCTAssertFalse(plain.contains("Worktree:"))
        XCTAssertFalse(plain.contains("Permission profile:"))
    }

    func testReportingInstructionFollowsWhetherTheTasksMCPIsAvailable() {
        let withMCP = TaskPromptBuilder.prompt(context(tasksMCPAvailable: true))
        XCTAssertTrue(withMCP.contains("uncoil_tasks"))
        XCTAssertTrue(withMCP.contains("This task's id:"))

        let withoutMCP = TaskPromptBuilder.prompt(context(tasksMCPAvailable: false))
        XCTAssertFalse(withoutMCP.contains("uncoil_tasks"))
        XCTAssertTrue(withoutMCP.contains("the Tasks MCP is off for this session"))
    }

    func testPromptIsPreviewableBeforeSending() {
        // The builder is pure, which is what makes a preview possible at all.
        let first = TaskPromptBuilder.prompt(context())
        let second = TaskPromptBuilder.prompt(context())
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    // MARK: - Existing sessions

    func testEligibleSessionsSeparateProjectsAndSkipDeadOnes() {
        let otherProject = UUID()
        let live = SessionRecord(
            projectID: projectID, provider: .claude, accountID: nil, title: "claude: canlı"
        )
        let dead = SessionRecord(
            projectID: projectID, provider: .claude, accountID: nil, title: "claude: kapalı"
        )
        let shell = SessionRecord(
            projectID: projectID, provider: .terminal, accountID: nil, title: "terminal"
        )
        let elsewhere = SessionRecord(
            projectID: otherProject, provider: .codex, accountID: nil, title: "codex: başka proje"
        )

        let result = TaskPromptBuilder.eligibleSessions(
            [live, dead, shell, elsewhere],
            statuses: [live.id: .idle, dead.id: .terminated, elsewhere.id: .running],
            taskProjectID: projectID
        )
        XCTAssertEqual(result.sameProject.map(\.id), [live.id])
        XCTAssertEqual(result.otherProjects.map(\.id), [elsewhere.id])
    }

    func testCrossProjectAssignmentWarns() {
        XCTAssertNil(
            TaskPromptBuilder.crossProjectWarning(
                sessionProjectName: "uncoil", taskProjectName: "uncoil"
            )
        )
        let warning = TaskPromptBuilder.crossProjectWarning(
            sessionProjectName: "başka", taskProjectName: "uncoil"
        )
        XCTAssertTrue(warning?.contains("başka") ?? false)
        XCTAssertTrue(warning?.contains("uncoil") ?? false)
    }

    // MARK: - Worktree naming

    func testWorktreeNameIsASafeSlug() {
        let task = document.tasks.first { $0.text == "daemon heartbeat ekle" }!
        let name = TaskPromptBuilder.worktreeName(for: task)
        XCTAssertEqual(name, "daemon-heartbeat-ekle")
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    func testLongTaskTextIsTruncatedToAUsableName() {
        let document = TodoParser.parse(
            "- [ ] " + Array(repeating: "kelime", count: 20).joined(separator: " ") + "\n",
            path: "/repo/TODO.md"
        )
        let name = TaskPromptBuilder.worktreeName(for: document.tasks[0])
        XCTAssertLessThanOrEqual(name.count, 40)
        XCTAssertFalse(name.isEmpty)
    }
}

final class TaskDispatchRequestTests: XCTestCase {
    func testDefaultsToClaudeAsAnImplementer() {
        let request = TaskDispatchRequest()
        XCTAssertEqual(request.provider, .claude)
        XCTAssertEqual(request.role, .implementer)
        XCTAssertFalse(request.createsWorktree)
        XCTAssertFalse(request.isExistingSession)
    }

    func testAnExistingSessionIsRecognised() {
        var request = TaskDispatchRequest()
        request.existingSessionID = UUID()
        XCTAssertTrue(request.isExistingSession)
    }

    func testEveryChoiceTheSheetOffersIsRepresentable() {
        var request = TaskDispatchRequest()
        request.provider = .codex
        request.accountID = UUID()
        request.model = "gpt-5.6-sol"
        request.workingMode = .askForApproval
        request.presetID = "codex-reviewer"
        request.permissionProfile = ["sessions.read"]
        request.role = .reviewer
        request.createsWorktree = true
        request.worktreeName = "review-heartbeat"
        XCTAssertEqual(request.provider, .codex)
        XCTAssertEqual(request.workingMode, .askForApproval)
        XCTAssertEqual(request.presetID, "codex-reviewer")
        XCTAssertEqual(request.role, .reviewer)
        XCTAssertTrue(request.createsWorktree)
    }
}
