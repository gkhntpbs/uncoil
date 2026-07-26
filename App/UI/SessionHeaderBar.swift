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
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
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
                        HStack(spacing: 3) {
                            TablerIcon(name: "git-branch", size: 10, color: Theme.textFaint)
                            Text(branch)
                                .font(Theme.mono(.body, .medium))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .fixedSize()
                        .help("Active branch: \(branch)")
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

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
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(14)
        .panel(radius: 12)
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
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(identifier)
        .help(help)
    }
}
