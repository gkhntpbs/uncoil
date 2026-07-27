import SwiftUI

// MARK: - First project

/// Point Uncoil at a folder. Everything downstream — worktrees, tasks, runs —
/// hangs off a project, so this is the one step worth nudging.
struct OnboardingProjectStep: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @Binding var addedProjectPath: String?
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var showPicker = false

    private var addedProject: Project? {
        guard let addedProjectPath else { return nil }
        return projectStore.projects.first { $0.rootPath == addedProjectPath }
    }

    private var isGitRepository: Bool {
        guard let path = addedProjectPath else { return false }
        return FileManager.default.fileExists(atPath: path + "/.git")
    }

    var body: some View {
        OnboardingScaffold(
            step: .project,
            title: String(localized: "Add your first project"),
            subtitle: String(localized: "Point Uncoil at a folder you work in. You can always add more later."),
            primaryTitle: addedProject == nil ? nil : String(localized: "Continue"),
            primaryAction: addedProject == nil ? nil : onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 14) {
                if let project = addedProject {
                    OnboardingCard(
                        symbol: "folder.fill",
                        title: project.name,
                        badge: isGitRepository
                            ? String(localized: "Git repository")
                            : String(localized: "Not a git repository"),
                        badgeTint: isGitRepository ? Theme.ok : Theme.warn,
                        detail: isGitRepository
                            ? String(localized: "Worktrees, task branches and diffs are available for this project.")
                            : String(localized: "Sessions work fine; worktrees and task branches need a git repository.")
                    ) {
                        Text(project.rootPath)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.textDim)
                        Button(String(localized: "Choose folder…")) { showPicker = true }
                            .buttonStyle(AccentButtonStyle())
                            .accessibilityIdentifier("onboarding.chooseFolder")
                    }
                    .padding(.vertical, 16)
                }

                OnboardingCard(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "Editor"),
                    detail: String(localized: "“Open in editor” launches this app.")
                ) {
                    Picker("", selection: Binding(
                        get: { settings.preferredEditor },
                        set: { settings.preferredEditor = $0; settings.save() }
                    )) {
                        ForEach(PreferredEditor.allCases) { editor in
                            Text(editor.isInstalled
                                 ? editor.displayName
                                 : "\(editor.displayName) (not installed)")
                                .tag(editor)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("onboarding.editor")
                }

                OnboardingSkipLink(action: onSkip)
            }
        }
        .sheet(isPresented: $showPicker) {
            FolderPickerSheet { url in
                projectStore.addProject(at: url)
                addedProjectPath = url.standardizedFileURL.path
            }
        }
    }
}

// MARK: - Tasks

/// TODO.md, met where the user already is: if the project they just added has
/// one, it is read and counted; if not, the feature is offered with a shortcut
/// that writes a starter file — and never overwrites an existing one.
struct OnboardingTasksStep: View {
    let projectPath: String?
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var found: [TodoDiscovery.Found] = []
    @State private var openTaskCount = 0
    @State private var scanning = true
    @State private var createError: String?
    @State private var createdPath: String?

    var body: some View {
        OnboardingScaffold(
            step: .tasks,
            title: String(localized: "Tasks come from your TODO.md"),
            subtitle: String(localized: "Uncoil reads the task files already in your project and turns them into a board you can hand out from. The file stays yours — only the line that changed is patched, never the whole file."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                if projectPath == nil {
                    OnboardingCard(
                        symbol: "folder.badge.questionmark",
                        title: String(localized: "No project yet"),
                        detail: String(localized: "Add a project and Uncoil scans it for task files. You can come back to this from the sidebar.")
                    )
                } else if scanning {
                    OnboardingCard(
                        symbol: "magnifyingglass",
                        title: String(localized: "Scanning the project…"),
                        detail: String(localized: "Build output and dependency folders are skipped.")
                    )
                } else if found.isEmpty {
                    OnboardingCard(
                        symbol: "doc.badge.plus",
                        title: String(localized: "No TODO.md in this project"),
                        detail: String(localized: "Add one and every task in it shows up on the board: assign it to an agent, watch it work in its own worktree, and let it tick the box when it is done.")
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let createdPath {
                                Text(createdPath)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.ok)
                            } else {
                                Button(String(localized: "Create a TODO.md")) { createTodo() }
                                    .buttonStyle(AccentButtonStyle())
                                    .accessibilityIdentifier("onboarding.createTodo")
                            }
                            if let createError {
                                Text(createError)
                                    .font(Theme.ui(.small))
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                    }
                } else {
                    OnboardingCard(
                        symbol: "checklist",
                        title: String(localized: "\(found.count) task sources found"),
                        badge: String(localized: "\(openTaskCount) open"),
                        badgeTint: Theme.ok,
                        detail: String(localized: "Open the project's Tasks tab to see the board.")
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(found.prefix(5)) { source in
                                Text(source.displayPath)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }

                OnboardingCard(
                    symbol: "person.2.badge.gearshape",
                    title: String(localized: "How a task becomes work"),
                    detail: String(localized: "Pick a task → Uncoil starts an agent with it, optionally in its own git worktree → the agent works, ticks the checkbox, and hands back a diff you review before anything merges.")
                )

                OnboardingSkipLink(action: onSkip)
            }
        }
        .task { await scan() }
    }

    private func scan() async {
        guard let projectPath else { return scanning = false }
        let sources = await Task.detached(priority: .utility) {
            TodoDiscovery.find(projectRoot: projectPath)
        }.value
        let open = await Task.detached(priority: .utility) {
            sources.reduce(into: 0) { total, source in
                guard let raw = try? String(contentsOfFile: source.path, encoding: .utf8) else { return }
                total += TodoParser.parse(raw, path: source.path).openTasks.count
            }
        }.value
        found = sources
        openTaskCount = open
        scanning = false
    }

    /// Writes a starter file, and refuses if one is already there: the point of
    /// the shortcut is to save typing, not to touch a file the user owns.
    /// The template and the rule live in `TodoStarter`, shared with the offer
    /// the project screen makes to anyone who never saw this step.
    private func createTodo() {
        guard let projectPath else { return }
        switch TodoStarter.create(in: projectPath) {
        case .success(let path):
            createdPath = path
            createError = nil
            Task { await scan() }
        case .failure(.alreadyExists):
            createError = String(localized: "There is already a TODO.md here.")
        case .failure(.write(let message)):
            createError = message
        }
    }
}
