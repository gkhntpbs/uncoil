import SwiftUI

struct SessionDetailView: View {
    let record: SessionRecord
    let project: Project
    @Binding var selection: MainSelection?
    var splitSessionID: Binding<UUID?>?
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var showChangesPanel = false
    @State private var restartToken = 0
    @State private var git = GitService.Snapshot()

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    private var account: AccountProfile? {
        settings.account(id: record.accountID)
    }

    private var workingDirectory: String {
        record.workingDirectory(in: project)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    // Tighter than the sides: the bar sits under the title bar,
                    // and the window's own chrome already supplies the air.
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if let approval = sessionStore.codexApprovals[record.id] {
                    CodexApprovalPanel(
                        request: approval,
                        respond: { decision in
                            if LaunchConfig.shared.codexApprovalFixture {
                                sessionStore.setCodexApproval(nil, for: record.id)
                                sessionStore.setStatus(
                                    .idle,
                                    detail: String(localized: "Fixture approval: \(decision)"),
                                    for: record.id
                                )
                                return
                            }
                            TerminalRegistry.shared.respondToCodexApproval(
                                sessionID: record.id,
                                request: approval,
                                decision: decision
                            )
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                } else if sessionStore.codexAuthentication[record.id] == .required {
                    CodexAuthenticationBanner()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                // A sleeping session must not be revived merely by being looked
                // at: waking is the user's decision, and mounting the terminal
                // here would relaunch the agent behind their back.
                if let mode = record.sleepMode {
                    SleepingSessionView(record: record, mode: mode) {
                        SessionSleepService.wake(
                            record, projectStore: projectStore, sessionStore: sessionStore
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                } else {
                    // Selecting a session always (re)starts its agent: the registry
                    // reuses a live terminal or launches fresh (resuming Claude when
                    // a provider session id is known). No "restart" screen.
                    TerminalHostView(record: record, project: project, account: account)
                        .id(restartToken + (sessionStore.restartCounter[record.id] ?? 0))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }

            if showChangesPanel {
                ChangesPanel(
                    workingDirectory: workingDirectory,
                    git: $git,
                    onClose: { toggleChangesPanel(false) }
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.container")
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let splitBinding = splitSessionID,
                  let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String,
                      let droppedID = UUID(uuidString: string),
                      droppedID != record.id else { return }
                Task { @MainActor in
                    splitBinding.wrappedValue = droppedID
                }
            }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        SessionHeaderBar(
            record: record,
            project: project,
            leadingIcon: "chevron.left",
            leadingHelp: String(localized: "Back to the project dashboard"),
            onLeading: { selection = .project(project.id) },
            onRestart: { restart() },
            onOpenProject: { selection = .project(project.id) }
        ) {
            Rectangle().fill(Theme.border).frame(width: 1, height: 16)

            // The button opens the right-hand panel, so it says so: a chevron
            // only told you a direction, not what was going to happen.
            ControlButton(
                iconName: showChangesPanel
                    ? "layout-sidebar-right-collapse"
                    : "layout-sidebar-right-expand",
                help: showChangesPanel
                    ? String(localized: "Close the changes panel")
                    : String(localized: "Open the changes panel"),
                identifier: "session.changesButton",
                tint: showChangesPanel ? Theme.highlight : nil
            ) {
                toggleChangesPanel(!showChangesPanel)
            }
        }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }

    // MARK: - Actions

    private func restart() {
        TerminalRegistry.shared.closeTerminal(for: record.id)
        projectStore.updateSession(record.id) { $0.lastActivityAt = .now }
        restartToken += 1
    }

    private func toggleChangesPanel(_ show: Bool) {
        withAnimation(Theme.Motion.standard) {
            showChangesPanel = show
        }
    }
}

private struct CodexApprovalPanel: View {
    let request: CodexApprovalRequest
    let respond: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            TablerIcon(name: "shield-lock", size: 16, color: Theme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                if let detail = request.detail {
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer()
            if request.availableDecisions.contains("decline") {
                Button("Deny") { respond("decline") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("session.codexApproval.decline")
            }
            if request.availableDecisions.contains("acceptForSession") {
                Button("For the Session") { respond("acceptForSession") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("session.codexApproval.session")
            }
            if request.availableDecisions.contains("accept") {
                Button("Allow Once") { respond("accept") }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("session.codexApproval.accept")
            }
        }
        .padding(12)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.codexApproval")
    }
}

private struct CodexAuthenticationBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            TablerIcon(name: "user-exclamation", size: 15, color: Theme.warn)
            Text("You need to sign in to your Codex account. You can run `codex login` through the terminal fallback.")
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(11)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .accessibilityIdentifier("session.codexAuthentication.required")
    }
}

// MARK: - Changes panel

/// Right-side sliding panel: uncommitted changes + recent commits for the
/// session's working directory.
private struct ChangesPanel: View {
    let workingDirectory: String
    @Binding var git: GitService.Snapshot
    let onClose: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CHANGES")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(0.6)
                if let branch = git.branch {
                    Text(branch)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !git.isRepo {
                        Text("This folder is not a git repository.")
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.textFaint)
                    } else {
                        if git.changedFiles.isEmpty {
                            Text("Worktree clean")
                                .font(Theme.mono(.body))
                                .foregroundStyle(Theme.ok)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(git.changedFiles) { file in
                                    ChangedFileRow(file: file, workingDirectory: workingDirectory)
                                }
                            }
                        }

                        if !git.recentCommits.isEmpty {
                            Divider().overlay(Theme.border)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(git.recentCommits) { commit in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(commit.subject)
                                            .font(Theme.mono(.body))
                                            .foregroundStyle(Theme.textDim)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(commit.hash)
                                                .font(Theme.mono(.micro))
                                                .foregroundStyle(Theme.highlight)
                                            Text(commit.relativeDate)
                                                .font(Theme.mono(.micro))
                                                .foregroundStyle(Theme.textFaint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .uncoilScrollers()
            }
        }
        .background(Theme.panel)
        .overlay(
            Rectangle().fill(Theme.border).frame(width: 1),
            alignment: .leading
        )
        .task(id: workingDirectory) { await refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.changesPanel")
    }

    private func refresh() async {
        let dir = workingDirectory
        git = await Task.detached(priority: .utility) {
            GitService.snapshot(repoPath: dir)
        }.value
    }
}

private struct ChangedFileRow: View {
    let file: GitService.ChangedFile
    let workingDirectory: String
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false

    var body: some View {
        Button {
            let url = URL(fileURLWithPath: workingDirectory).appendingPathComponent(file.path)
            settings.preferredEditor.open(url)
        } label: {
            HStack(spacing: 8) {
                Text(file.status)
                    .font(Theme.mono(.small, .bold))
                    .foregroundStyle(file.status == "??" ? Theme.textFaint : Theme.warn)
                    .frame(width: 20, alignment: .leading)
                Text(file.path)
                    .font(Theme.mono(.body))
                    .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open with \(settings.preferredEditor.displayName)")
    }
}

struct EmptyDetailView: View {
    @Binding var showFolderPicker: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ProviderMark(provider: .claude, size: 20)
                ProviderMark(provider: .codex, size: 20)
            }
            Text("Hover a project, pick an agent")
                .font(Theme.mono(.large, .medium))
                .foregroundStyle(Theme.text)
            Text("Every agent opens side by side on the same project.")
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textFaint)
            Button("Add Project") { showFolderPicker = true }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("empty.addProjectButton")
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// Right half of a drag-to-split: the same session header as the pane it was
/// dragged out of, over the same terminal.
struct SplitSessionPane: View {
    let record: SessionRecord
    let project: Project
    let onClose: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var restartToken = 0

    var body: some View {
        VStack(spacing: 0) {
            SessionHeaderBar(
                record: record,
                project: project,
                leadingIcon: "xmark",
                leadingHelp: String(localized: "Close the pane"),
                onLeading: onClose,
                onRestart: { restart() },
                trailing: { EmptyView() }
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)

            TerminalHostView(
                record: record,
                project: project,
                account: settings.account(id: record.accountID)
            )
            .id(restartToken + (sessionStore.restartCounter[record.id] ?? 0))
            .padding([.horizontal, .bottom], 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.splitPane")
    }

    private func restart() {
        TerminalRegistry.shared.closeTerminal(for: record.id)
        projectStore.updateSession(record.id) { $0.lastActivityAt = .now }
        restartToken += 1
    }
}
