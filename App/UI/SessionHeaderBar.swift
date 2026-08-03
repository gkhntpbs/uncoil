import SwiftUI

/// The bar above a session: who it is, where it runs, how it is doing, and the
/// controls that act on it.
///
/// Shared rather than duplicated, because the pane a session is dragged into is
/// the same session — it was only missing its header, which made the split half
/// look like a lesser thing than the one it was dragged from. `trailing` is what
/// genuinely differs: the full detail view has a changes panel to toggle, the
/// split pane has nothing extra.
struct SessionHeaderBar<Trailing: View>: View {
    let record: SessionRecord
    let project: Project
    let leadingIcon: String
    let leadingHelp: String
    let onLeading: () -> Void
    let onRestart: () -> Void
    @ViewBuilder var trailing: Trailing

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var branch: String?

    private var status: AgentSessionStatus { sessionStore.status(of: record.id) }
    private var account: AccountProfile? { settings.account(id: record.accountID) }
    private var workingDirectory: String { record.workingDirectory(in: project) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onLeading) {
                Image(systemName: leadingIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 22, height: 22)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("session.backButton")
            .help(leadingHelp)

            ProviderMark(provider: record.provider, size: 17)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.provider.displayName)
                        .font(Theme.mono(.large, .bold))
                        .foregroundStyle(Theme.text)
                    Text(record.displayTitle)
                        .font(Theme.mono(.large))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let account {
                        Text(account.name)
                            .font(Theme.mono(.body))
                            .foregroundStyle(record.provider.color.opacity(0.9))
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text(displayPath)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Which branch the work is landing on. A session often runs
                    // in a worktree, so the project's branch is not an answer.
                    // Inline here rather than chipped: this line is metadata,
                    // and a bordered box on it would outweigh the title above.
                    if let branch {
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                        // Switchable, like the project header's chip: the tree
                        // the session is in is the one that moves, which for a
                        // task session is its worktree and not the project.
                        BranchMenuButton(
                            repoPath: workingDirectory,
                            current: branch,
                            // Re-read at once rather than waiting out the 15s
                            // poll; blanking the chip would make it disappear
                            // for the whole gap.
                            onSwitched: { announceSwitch(to: $0) },
                            busyWarning: busyWarning
                        ) {
                            HStack(spacing: 3) {
                                TablerIcon(name: "git-branch", size: 10, color: Theme.textFaint)
                                Text(branch)
                                    .font(Theme.mono(.body, .medium))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // Which tree that branch is checked out in: a
                                // task session runs in a worktree, and the
                                // branch alone does not say which.
                                Text("· \(treeName)")
                                    .font(Theme.mono(.body))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .fixedSize()
                        .help("\(branch) in \(treeName) — click to switch")
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            // A terminal session has no agent, so it has no agent status and
            // no control plane: the MCP binary is never handed to it, and a
            // badge reporting on one it does not have was reporting on nothing.
            if record.provider.isAgent {
                HStack(spacing: 7) {
                    StatusOrb(status: status, size: 13)
                    Text(sessionStore.detail(of: record.id) ?? status.label)
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(status.color.opacity(0.10), in: Capsule())
                .fixedSize()

                McpStatusBadge(sessionID: record.id)
            }

            HStack(spacing: 2) {
                RunDefaultControl(project: project)

                EditorOpenControl(directory: workingDirectory)

                Rectangle().fill(Theme.border).frame(width: 1, height: 16)

                ControlButton(
                    iconName: "refresh",
                    help: String(localized: "Restart the session") +
                        (record.providerSessionID != nil ? " (continues with its history)" : ""),
                    identifier: "session.restartButton",
                    action: onRestart
                )

                trailing
            }
            .padding(3)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(14)
        .panel()
        // Cheap enough to re-ask while the session is open: a branch changes
        // under the agent's hands, and a stale one is worse than none.
        .task(id: workingDirectory) {
            let directory = workingDirectory
            while !Task.isCancelled {
                let resolved = await Task.detached(priority: .utility) {
                    GitService.currentBranch(repoPath: directory)
                }.value
                if branch != resolved { branch = resolved }
                try? await Task.sleep(nanoseconds: 15 * NSEC_PER_SEC)
            }
        }
    }

    /// Every session sharing this working tree — a tree has one checkout, so a
    /// switch moves all of them, not only the one whose header was clicked.
    private var treeSessions: [SessionRecord] {
        WorkingTree.sessions(
            at: workingDirectory, in: project, from: projectStore.sessions(for: project.id))
    }

    /// Set while anything in this tree is mid-turn, so a checkout asks before
    /// rewriting the files those agents are reasoning about.
    private var busyWarning: String? {
        let busy = treeSessions.filter { sessionStore.status(of: $0.id).isWorking }
        guard !busy.isEmpty else { return nil }
        if busy.count == 1 {
            return String(localized: "\(busy[0].displayTitle) is working in this tree")
        }
        return String(localized: "\(busy.count) sessions are working in this tree")
    }

    /// A checkout changes the files under every agent in the tree, and nothing
    /// else would tell them: an agent's view of the repository is whatever it
    /// read before. The note is typed into each session rather than sent as a
    /// turn, so it lands in the conversation without starting one.
    private func announceSwitch(to branch: String) {
        refreshBranch()
        let note = String(localized: "The working tree moved to branch \(branch).")
        for session in treeSessions where sessionStore.status(of: session.id) != .terminated {
            Task {
                await TerminalRegistry.shared.submitText(
                    note, for: session.id, provider: session.provider)
            }
        }
    }

    private func refreshBranch() {
        let directory = workingDirectory
        Task {
            let resolved = await Task.detached(priority: .utility) {
                GitService.currentBranch(repoPath: directory)
            }.value
            await MainActor.run { branch = resolved }
        }
    }

    private var treeName: String {
        WorktreeNaming.name(forTreeAt: workingDirectory, projectRoot: project.rootPath)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }
}

/// A square icon button in a session's control cluster.
struct ControlButton: View {
    let iconName: String
    let help: String
    let identifier: String
    /// Resting icon colour; nil keeps the neutral dim/hover pair.
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(name: iconName, size: 13, color: tint ?? (hovering ? Theme.text : Theme.textDim))
                .frame(width: 26, height: 24)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(identifier)
        .help(help)
    }
}
