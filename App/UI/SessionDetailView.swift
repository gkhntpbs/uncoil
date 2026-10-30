import SwiftUI

struct SessionDetailView: View {
    let record: SessionRecord
    let project: Project
    @Binding var selection: MainSelection?
    var splitSessionID: Binding<UUID?>?
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
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
        VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    // Tighter than the sides: the bar sits under the title bar,
                    // and the window's own chrome already supplies the air.
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if let approval = sessionStore.codexApprovals[record.id] {
                    ApprovalPanel(
                        title: approval.title,
                        detail: approval.detail,
                        decisions: approval.availableDecisions,
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
                    SessionSurfaceView(record: record, project: project, account: account)
                        .id(sessionStore.restartCounter[record.id] ?? 0)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.container")
        .onDrop(
            of: [.text], isTargeted: nil
        ) { providers in
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
        )
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
        SessionActions(projects: projectStore, sessions: sessionStore).restart(record.id)
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

    var body: some View {
        VStack(spacing: 0) {
            SessionHeaderBar(
                record: record,
                project: project,
                leadingIcon: "xmark",
                leadingHelp: String(localized: "Close the pane"),
                onLeading: onClose,
                onRestart: { restart() }
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)

            SessionSurfaceView(
                record: record,
                project: project,
                account: settings.account(id: record.accountID)
            )
            .id(sessionStore.restartCounter[record.id] ?? 0)
            .padding([.horizontal, .bottom], 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.splitPane")
    }

    private func restart() {
        SessionActions(projects: projectStore, sessions: sessionStore).restart(record.id)
    }
}

/// Shown while something is dragged over a session.
///
