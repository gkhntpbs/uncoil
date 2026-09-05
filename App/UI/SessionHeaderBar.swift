import SwiftUI

/// The bar above a session: who it is, where it runs, how it is doing, and the
/// controls that act on it.
///
/// Shared rather than duplicated, because the pane a session is dragged into is
/// the same session — it was only missing its header, which made the split half
/// look like a lesser thing than the one it was dragged from. The two draw the
/// same controls; only the leading button differs, which is what closes a pane
/// in one and goes back to the project in the other.
struct SessionHeaderBar: View {
    let record: SessionRecord
    let project: Project
    let leadingIcon: String
    let leadingHelp: String
    let onLeading: () -> Void
    let onRestart: () -> Void
    /// Navigates to the project screen. Distinct from `onLeading`, which in a
    /// split pane closes the pane rather than going anywhere — routing the
    /// logs shortcut through it would close the pane instead.
    var onOpenProject: (() -> Void)?

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var usage: UsageStore
    @State private var branch: String?
    /// Only for `defaultModelDetail` — what "default" resolves to when the user
    /// picked nothing. Detected rather than assumed: Codex writes its model
    /// into its own config, and a Claude build without `--model` has no answer.
    @State private var capabilities: AgentLaunchCapabilities?
    /// What the last account change did, shown until it is dismissed.
    @State private var accountNote: String?
    /// Non-nil while the handoff sheet is up. Held here rather than in the chip
    /// because the chip's card is a popover, and a sheet raised from a view that
    /// is closing never appears.
    @State private var handoff: UsageAlert.Evaluation?

    private var status: AgentSessionStatus { sessionStore.status(of: record.id) }
    private var account: AccountProfile? { settings.account(id: record.accountID) }
    private var workingDirectory: String { record.workingDirectory(in: project) }

    /// The model and effort chip. Deliberately quiet — it is reference, not
    /// status — and absent rather than guessed when nothing is known.
    private var accountChoices: [AccountProfile] {
        settings.accounts(for: record.provider)
    }

    /// Records the choice, and says what it did. A running agent keeps the
    /// account it started with — the environment that selects it is set once,
    /// at launch — so the alternative to saying so is letting the user believe
    /// they switched while the agent goes on as the other account.
    private func chooseAccount(_ id: UUID) {
        let change = SessionAccountChange.classify(
            current: record.accountID,
            chosen: id,
            isRunning: sessionStore.status(of: record.id).isKnownLive
        )
        guard change != .unchanged else { return }
        projectStore.updateSession(record.id) { $0.accountID = id }
        accountNote = change.note
    }

    /// How this session's account is doing, when it is worth acting on.
    private var usageAlert: UsageAlert.Evaluation? {
        guard record.provider.isAgent else { return nil }
        let evaluation = UsageAlert.evaluate(
            usage.snapshot(for: UsageKey(provider: record.provider, accountID: record.accountID)),
            threshold: settings.usageWarningThreshold
        )
        return evaluation.state.isAlerting ? evaluation : nil
    }

    private var runtimeInfo: SessionRuntimeInfo {
        SessionRuntimeInfo.resolve(
            reportedModel: sessionStore.reportedModel[record.id],
            selection: record.launchSelection,
            defaultModelDetail: capabilities?.defaultModelDetail
        )
    }

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
                    // Model and effort: reference, not status. Parenthesised,
                    // small and faint so it reads as an aside to the name
                    // rather than competing with the state capsule opposite.
                    if let runtime = runtimeInfo.summary {
                        Text("(\(runtime))")
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .fixedSize()
                            .help(runtimeInfo.help ?? runtime)
                            .accessibilityIdentifier("session.runtimeInfo")
                            .accessibilityValue(runtime)
                    }
                }
                HStack(spacing: 6) {
                    // The account was printed here and nothing else: multiple
                    // logins could be entered but never chosen between. It is
                    // a menu now, and what it can and cannot do mid-session is
                    // said out loud rather than left to be discovered.
                    if record.provider.isAgent, !accountChoices.isEmpty {
                        Menu {
                            ForEach(accountChoices) { choice in
                                Button {
                                    chooseAccount(choice.id)
                                } label: {
                                    if choice.id == record.accountID {
                                        Label(choice.name, systemImage: "checkmark")
                                    } else {
                                        Text(choice.name)
                                    }
                                }
                            }
                        } label: {
                            Text(account?.name ?? String(localized: "No account"))
                                .font(Theme.mono(.body))
                                .foregroundStyle(record.provider.color.opacity(0.9))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(String(
                            localized: "Which login this session runs under. The config directory is handed to the agent when it starts, so switching applies from the next start."
                        ))
                        .accessibilityIdentifier("session.accountMenu")
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                    } else if let account {
                        Text(account.name)
                            .font(Theme.mono(.body))
                            .foregroundStyle(record.provider.color.opacity(0.9))
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                    }
                    // Beside the account and not anywhere else: a limit belongs
                    // to the login, not to the session, and two sessions on two
                    // accounts have two different answers.
                    //
                    // Shown whether or not a profile exists. Most people never
                    // make one — they log into Claude the ordinary way and use
                    // the provider's own default — and hanging the chip off the
                    // profile list meant the usual case was the one that never
                    // saw it. `nil` is that account, and the layer already
                    // models it as such.
                    if record.provider.isAgent {
                        UsageChip(
                            provider: record.provider,
                            account: account,
                            isWorking: status.isWorking,
                            session: record,
                            onRequestHandoff: { handoff = $0 }
                        )
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
                // Kept as controls rather than folded into the menu: the run
                // button is a *state* — the colour says whether this project's
                // dev server is up — and a menu that has to be opened to be
                // read is not a status. The handoff button is the other
                // exception, and for the opposite reason: it appears only when
                // a login is about to stop the user's work, which is the worst
                // moment to put an action one level further away.
                RunDefaultControl(project: project, onOpenLogs: onOpenProject)

                if let usageAlert, usageAlert.state.isAlerting {
                    ControlButton(
                        iconName: "arrow-move-right",
                        help: usageAlert.state == .reached
                            ? String(localized: "This account is out — hand the work to another agent")
                            : String(localized: "Hand the work to another agent before this account runs out"),
                        identifier: "session.handoffButton",
                        tint: usageAlert.state == .reached ? Theme.danger : Theme.warn
                    ) {
                        handoff = usageAlert
                    }
                }

                Rectangle().fill(Theme.border).frame(width: 1, height: 16)

                // Everything else the session can be told to do. The same list
                // is the menu bar's Session menu, so each verb has one name and
                // one shortcut wherever it is reached from.
                SessionMenuButton(
                    record: record,
                    project: project,
                    onRestart: onRestart,
                    onHandoff: usageAlert.map { alert in { handoff = alert } }
                )
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
        .sheet(item: Binding(
            get: { handoff.map { HandoffRequest(evaluation: $0) } },
            set: { if $0 == nil { handoff = nil } }
        )) { request in
            HandoffSheet(
                session: record,
                accountName: account?.name,
                evaluation: request.evaluation,
                projectStore: projectStore,
                sessionStore: sessionStore,
                settings: settings,
                onOpenSession: { Router.shared.go(to: .session($0)) }
            )
            .environmentObject(projectStore)
            .environmentObject(sessionStore)
            .environmentObject(settings)
            .environmentObject(usage)
        }
        .onReceive(Router.shared.$handoffCounter) { _ in
            guard Router.shared.takeHandoff(for: record.id) else { return }
            handoff = UsageAlert.evaluate(
                usage.snapshot(for: UsageKey(provider: record.provider, accountID: record.accountID)),
                threshold: settings.usageWarningThreshold
            )
        }
        .alert(
            String(localized: "Account changed"),
            isPresented: Binding(
                get: { accountNote != nil },
                set: { if !$0 { accountNote = nil } }
            )
        ) {
            // Restarting is the only thing that actually applies it, so it is
            // offered here rather than described and left to the user to find.
            if accountNote == SessionAccountChange.needsRestart.note {
                Button(String(localized: "Restart now")) {
                    accountNote = nil
                    onRestart()
                }
                Button(String(localized: "Later"), role: .cancel) { accountNote = nil }
            } else {
                Button(String(localized: "OK"), role: .cancel) { accountNote = nil }
            }
        } message: {
            Text(accountNote ?? "")
        }
        // Cheap enough to re-ask while the session is open: a branch changes
        // under the agent's hands, and a stale one is worse than none.
        .task(id: record.provider) {
            guard record.provider.isAgent else { return }
            capabilities = await AgentLaunchCatalog.detect(
                provider: record.provider,
                binaryPath: settings.binaryPath(for: record.provider)
            )
        }
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
        for session in treeSessions where sessionStore.status(of: session.id).isKnownLive {
            Task {
                await TerminalRegistry.shared.submitText(
                    note, for: session.id, provider: session.provider,
                    namesTheSession: false)
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


/// `sheet(item:)` needs something identifiable; the evaluation itself is a
/// value with no identity of its own.
private struct HandoffRequest: Identifiable {
    let id = UUID()
    let evaluation: UsageAlert.Evaluation
}
