import SwiftUI

/// Project home: every session, git state, and the file tree in one place.
struct ProjectDashboardView: View {
    let project: Project
    @Binding var selection: MainSelection?
    let onOrganizeSessions: () -> Void
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    /// Git state, worktrees, pull requests and task presence live in a store
    /// that outlives the view, so leaving the screen and coming back draws the
    /// last known page immediately instead of re-running a scan, three git
    /// subprocesses and a GitHub request before showing anything.
    @ObservedObject private var pages = ProjectPageStore.shared
    @ObservedObject private var runs = RunRegistry.shared
    @State private var newWorktreeName = ""
    @State private var worktreeError: String?
    @State private var creatingWorktree = false

    private var page: ProjectPageStore.Snapshot { pages.snapshot(for: project.id) }
    private var git: GitService.Snapshot { page.git }
    private var worktrees: [GitService.Worktree] { page.worktrees }
    private var pullRequests: [GitHubService.PullRequest] { page.pullRequests }
    private var prMessage: String? { page.prMessage }
    /// True only before a project has ever been loaded — the one moment there
    /// is nothing to draw and a skeleton belongs.
    private var isFirstLoad: Bool { !page.hasLoaded }

    /// Which area of the project screen is showing. Tasks is a peer of the
    /// overview rather than a panel inside it, so a long TODO.md gets the room.
    private enum Area: String, CaseIterable, Identifiable {
        case overview
        case tasks
        case run

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "General"
            case .tasks: "Tasks"
            case .run: "Run"
            }
        }

        var iconName: String {
            switch self {
            case .overview: "layout-dashboard"
            case .tasks: "checkbox"
            case .run: "player-play"
            }
        }
    }

    @State private var area: Area = .overview
    /// How wide the header actually is. Drives what the header may drop before
    /// it would otherwise wrap: the path, the branch, then the tab labels.
    @State private var headerWidth: CGFloat = 1_000
    /// Below this the tabs keep their icons and lose their words — the labels
    /// are what wrapped onto a second line in a narrow window.
    private var tabsAreIconOnly: Bool { headerWidth < 720 }
    /// Whether the project has any task source on disk; without one the Tasks
    /// tab is not offered at all, instead of opening onto an empty state.
    private var hasTaskSources: Bool { page.hasTaskSources }
    private var openTaskCount: Int { page.openTaskCount }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if area == .tasks, hasTaskSources {
                    ProjectTasksView(project: project, selection: $selection)
                } else if area == .run {
                    ProjectRunView(project: project)
                } else {
                    overviewContent
                }
            }
            // Same 8pt above the header bar as a session's, so switching
            // between the two screens does not shift the bar up and down.
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 8)
            .uncoilScrollers()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.container")
        // Cheap and idempotent: it returns straight away while the snapshot is
        // fresh, so switching back to a project costs nothing.
        .task(id: project.id) {
            await pages.refreshIfNeeded(project: project)
            if LaunchConfig.shared.projectArea == "tasks", hasTaskSources {
                area = .tasks
            }
            if !hasTaskSources { area = .overview }
        }
    }

    private func refreshGit() async {
        await pages.refresh(project: project)
    }

    /// The tab row lives inside the header card: switching area is part of what
    /// the project header is, not a floating control under it.
    private var areaTabs: some View {
        HStack(spacing: 2) {
            ForEach(Area.allCases) { candidate in
                if candidate != .tasks || hasTaskSources {
                    let isOn = area == candidate
                    Button {
                        area = candidate
                    } label: {
                        HStack(spacing: 6) {
                            TablerIcon(
                                name: candidate.iconName,
                                size: 12,
                                color: isOn ? Theme.text : Theme.textFaint
                            )
                            if !tabsAreIconOnly {
                                Text(candidate.title)
                                    .font(Theme.mono(.body, isOn ? .semibold : .regular))
                                    .foregroundStyle(isOn ? Theme.text : Theme.textDim)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: true)
                            }
                            if candidate == .run, runs.runningCount(projectID: project.id) > 0 {
                                Circle()
                                    .fill(Theme.ok)
                                    .frame(width: 6, height: 6)
                            }
                            if candidate == .tasks, openTaskCount > 0 {
                                Text("\(openTaskCount)")
                                    .font(Theme.mono(.micro, .semibold))
                                    .foregroundStyle(isOn ? Theme.bg : Theme.textFaint)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        isOn ? Theme.highlight : Theme.panel,
                                        in: Capsule()
                                    )
                            }
                        }
                        .padding(.horizontal, tabsAreIconOnly ? 8 : 12)
                        .padding(.vertical, 6)
                        .background(
                            isOn ? Theme.panelActive : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dashboard.area.\(candidate.rawValue)")
                    // Icon-only tabs lose their words, so the name has to be
                    // reachable some other way.
                    .help(candidate.title)
                }
            }
        }
        .padding(3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1)
        )
        // Never compressed: the row keeps its intrinsic width, and when that no
        // longer fits it is the labels that go, not the layout.
        .fixedSize()
        .accessibilityIdentifier("dashboard.areaPicker")
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionsPanel
            if !projectStore.sessionHistory(for: project.id).isEmpty {
                historyPanel
            }
            if git.isRepo {
                worktreesPanel
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    gitPanel
                    if git.isRepo {
                        pullRequestsPanel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                filesPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }


    // MARK: - Pull requests

    private var pullRequestsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Pull Request'ler", count: pullRequests.count)

            if isFirstLoad || (prMessage == nil && pullRequests.isEmpty) {
                // Pull requests come off the network, so this panel is the last
                // to fill in — and the one where a placeholder is worth most.
                SkeletonListRows(count: 2)
                    .padding(14)
            } else if let prMessage {
                Text(prMessage)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(spacing: 1) {
                    ForEach(pullRequests) { pr in
                        PullRequestRow(pullRequest: pr)
                    }
                }
                .padding(6)
            }
        }
        .panel(radius: 12)
    }

    // MARK: - Worktrees

    private var worktreesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Worktree'ler", count: max(0, worktrees.count - 1))

            VStack(spacing: 1) {
                ForEach(worktrees) { worktree in
                    WorktreeRow(worktree: worktree, project: project, selection: $selection)
                }
            }
            .padding(6)

            Divider().overlay(Theme.border)

            HStack(spacing: 8) {
                TextField("New worktree name (isolated task branch)", text: $newWorktreeName)
                    .accessibilityIdentifier("dashboard.worktrees.nameField")
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                    .onSubmit { createWorktree() }
                Button(creatingWorktree ? "Creating…" : "Create") { createWorktree() }
                    .accessibilityIdentifier("dashboard.worktrees.createButton")
                    .buttonStyle(GhostButtonStyle())
                    .disabled(creatingWorktree || newWorktreeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)

            if let worktreeError {
                Text(worktreeError)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .panel(radius: 12)
    }

    private func createWorktree() {
        let name = newWorktreeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creatingWorktree else { return }
        creatingWorktree = true
        worktreeError = nil
        let path = project.rootPath
        Task {
            let result = await Task.detached(priority: .utility) {
                GitService.createWorktree(repoPath: path, name: name)
            }.value
            creatingWorktree = false
            switch result {
            case .success:
                newWorktreeName = ""
                await refreshGit()
            case .failure(let failure):
                worktreeError = failure.message
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: headerWidth < 620 ? 8 : 12) {
            ProjectIcon(project: project, size: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(Theme.mono(.title, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if headerWidth >= 560 {
                    Text(displayPath)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // The title is the one thing allowed to give way; every control to
            // its right keeps its intrinsic size instead of being squeezed into
            // a second line.
            .layoutPriority(-1)

            Spacer(minLength: 8)

            // Always shown: the row filters Tasks out on its own when the
            // project has no task source, and hiding the whole row also hid
            // the Run tab on every project without a TODO.md.
            areaTabs

            if let branch = git.branch, headerWidth >= 460 {
                BranchBadge(branch: branch)
            }

            // The project's own root, in the same control the session header
            // uses — one gesture means one thing wherever it appears.
            EditorOpenControl(directory: project.rootPath)
                .padding(3)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )

            AgentLauncherStrip(project: project, selection: $selection)
        }
        .padding(14)
        .panel(radius: 12)
        .measureWidth { headerWidth = $0 }
    }

    /// Branch only. The change count moved out: it is already spelled out in
    /// the git panel below, and in the header it was the part that pushed the
    /// row into wrapping.
    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if project.rootPath.hasPrefix(home) {
            return "~" + project.rootPath.dropFirst(home.count)
        }
        return project.rootPath
    }

    // MARK: - Sessions

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PanelHeading(
                    title: "Sessions",
                    count: projectStore.activeSessions(for: project.id).count
                )
                Spacer()
                Button {
                    onOrganizeSessions()
                } label: {
                    HStack(spacing: 6) {
                        TablerIcon(name: "sparkles", size: 12, color: Theme.highlight)
                        Text("Organise Automatically")
                            .font(Theme.mono(.small, .medium))
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("dashboard.sessions.organize")
                .padding(.trailing, 10)
            }

            let records = projectStore.activeSessions(for: project.id)
            if records.isEmpty {
                Text("No sessions yet — start an agent from the top right.")
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        SessionCard(record: record) {
                            selection = .session(record.id)
                        }
                    }
                }
                .padding(6)
            }
        }
        .panel(radius: 12)
    }

    private var historyPanel: some View {
        let records = projectStore.sessionHistory(for: project.id)
        return VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Closed Sessions", count: records.count)
            VStack(spacing: 1) {
                ForEach(records) { record in
                    SessionCard(record: record) {
                        selection = .session(record.id)
                    }
                }
            }
            .padding(6)
        }
        .panel(radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.sessionHistory")
    }

    // MARK: - Git

    private var gitPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Git", count: git.changedFiles.count)

            if isFirstLoad {
                // Nothing is known about this project yet — not even whether it
                // is a repo — so the panel says "a list is coming" rather than
                // asserting the wrong empty state for a second.
                SkeletonRows(count: 4)
                    .padding(14)
            } else if !git.isRepo {
                Text("This folder is not a git repository.")
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if git.changedFiles.isEmpty {
                        Label {
                            Text("Worktree clean")
                                .font(Theme.mono(.body))
                                .foregroundStyle(Theme.ok)
                        } icon: {
                            Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(git.changedFiles.prefix(12)) { file in
                                HStack(spacing: 8) {
                                    Text(file.status)
                                        .font(Theme.mono(.small, .bold))
                                        .foregroundStyle(statusColor(file.status))
                                        .frame(width: 20, alignment: .leading)
                                    Text(file.path)
                                        .font(Theme.mono(.body))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            if git.changedFiles.count > 12 {
                                Text("+ \(git.changedFiles.count - 12) more files")
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }

                    if !git.recentCommits.isEmpty {
                        Divider().overlay(Theme.border)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(git.recentCommits) { commit in
                                HStack(spacing: 8) {
                                    Text(commit.hash)
                                        .font(Theme.mono(.small))
                                        .foregroundStyle(Theme.highlight)
                                    Text(commit.subject)
                                        .font(Theme.mono(.body))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(commit.relativeDate)
                                        .font(Theme.mono(.micro))
                                        .foregroundStyle(Theme.textFaint)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .panel(radius: 12)
    }

    private func statusColor(_ code: String) -> Color {
        switch code {
        case "M", "MM": Theme.warn
        case "A": Theme.ok
        case "D": Theme.danger
        case "??": Theme.textFaint
        default: Theme.textDim
        }
    }

    // MARK: - Files

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Files", count: nil)
            FileTreeView(rootURL: project.rootURL)
                .padding(6)
        }
        .panel(radius: 12)
    }
}

// MARK: - Pieces

private struct PanelHeading: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.textDim)
                .textCase(.uppercase)
                .kerning(0.6)
            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.mono(.small, .medium))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.panelActive, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct SessionCard: View {
    let record: SessionRecord
    let onOpen: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var hovering = false

    private var status: AgentSessionStatus { sessionStore.status(of: record.id) }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ProviderMark(provider: record.provider, size: 12)
                    .opacity(status == .terminated ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.displayTitle)
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(status == .terminated ? Theme.textDim : Theme.text)
                        .lineLimit(1)
                    Text(record.provider.displayName)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusOrb(status: status, size: 11)
                    Text(status.label)
                        .font(Theme.mono(.small))
                        .foregroundStyle(status.color)
                }
                Text(RelativeClock.short(since: record.lastActivityAt))
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.session.\(record.title)")
        .onHover { hovering = $0 }
    }
}

private struct PullRequestRow: View {
    let pullRequest: GitHubService.PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = pullRequest.htmlURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                TablerIcon(
                    name: "git-pull-request",
                    size: 12,
                    color: pullRequest.isDraft ? Theme.textFaint : Theme.ok
                )
                Text("#\(pullRequest.number)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.highlight)
                Text(pullRequest.title)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if pullRequest.isDraft {
                    Text("draft")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.panelActive, in: Capsule())
                }
                Spacer(minLength: 4)
                Text(pullRequest.author)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct WorktreeRow: View {
    let worktree: GitService.Worktree
    let project: Project
    @Binding var selection: MainSelection?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(worktree.isMain ? Theme.textFaint : Theme.warn.opacity(0.85))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.isMain ? "ana kopya" : URL(fileURLWithPath: worktree.path).lastPathComponent)
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
                Text(worktree.branch ?? "detached")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            if hovering {
                AgentLauncherStrip(
                    project: project,
                    worktreePath: worktree.isMain ? nil : worktree.path,
                    selection: $selection
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovering = value }
        }
    }
}
