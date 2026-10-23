import SwiftUI

/// A session as a conversation — today, Uncoil Auto's.
///
/// Drawn entirely from the session's `AgentTimeline`, kept current by the
/// event hub, and acting on the session only through `AgentSessionControl`.
/// It knows nothing about who is behind the session, which is what lets the
/// same transcript show whatever the agents Uncoil directs report back.
struct AgentChatView: View {
    let record: SessionRecord
    let project: Project
    let account: AccountProfile?
    let onRestart: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var theme = ThemeStore.shared
    @StateObject private var model: AgentChatModel
    @StateObject private var follower = ChatScrollFollower()
    @StateObject private var autoState: UncoilAutoConversationState
    @AppStorage(UncoilAutoAgentsPanel.visibilityKey) private var agentsPanelVisible = true

    /// Wide enough for a diff, narrow enough that a paragraph reads as one.
    static let columnWidth: CGFloat = 780

    init(record: SessionRecord, project: Project, account: AccountProfile?, onRestart: @escaping () -> Void) {
        self.record = record
        self.project = project
        self.account = account
        self.onRestart = onRestart
        _model = StateObject(wrappedValue: AgentChatModel(sessionID: record.id, provider: record.provider))
        _autoState = StateObject(wrappedValue: UncoilAutoConversationState.for(record.id))
    }

    private var isUncoilAuto: Bool { record.provider == .uncoil }

    /// Every agent of the project, by handle, and the ones this conversation
    /// may reach.
    private var autoRoster: [UncoilAutoRoster.Entry] {
        UncoilAutoRoster.entries(
            sessions: projectStore.sessions.filter { $0.projectID == record.projectID },
            installed: settings.installedProviders)
    }

    private var openRoster: [UncoilAutoRoster.Entry] {
        autoRoster.filter { autoState.allows($0.provider, settings: settings.uncoilAuto) }
    }

    /// Where a message naming nobody goes now.
    private var autoTarget: UncoilAutoRoster.Entry? {
        UncoilAutoRouting.target(chosen: autoState.target, roster: openRoster, allows: { _ in true })
    }

    /// Whether any agent this conversation has spoken with is working.
    private var agentsWorking: Bool {
        model.participantIDs.contains { sessionStore.status(of: $0).isWorking }
    }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            if isUncoilAuto, agentsPanelVisible {
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    UncoilAutoAgentsPanel(
                        projectID: record.projectID,
                        conversation: autoState,
                        onStart: { model.submitLine("/new \($0.rawValue)") },
                        onMention: { model.receiveDraft("@\($0) ") }
                    )
                }
                .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        // The toggle is in the session header, and in the View menu: animating
        // on the value slides the panel whichever of them asked.
        .animation(Theme.Motion.expressive, value: agentsPanelVisible)
        .onAppear {
            // Looking at a session starts it, as the terminal does.
            TerminalRegistry.shared.ensureSession(
                for: record, project: project, account: account,
                settings: settings, sessionStore: sessionStore, projectStore: projectStore
            )
            AgentChatDrafts.shared.register(model)
            if isUncoilAuto {
                model.suggestionProvider = { [projectStore, settings, autoState, projectID = record.projectID] token in
                    UncoilAutoCompletions.suggestions(
                        for: token,
                        roster: UncoilAutoRoster.entries(
                            sessions: projectStore.sessions.filter { $0.projectID == projectID },
                            installed: settings.installedProviders)
                        .filter { autoState.allows($0.provider, settings: settings.uncoilAuto) })
                }
            }
            model.flush()
        }
        .onDisappear { AgentChatDrafts.shared.unregister(model) }
        .onChange(of: model.followRequest) { _ in follower.scrollToEnd() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.container")
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                transcript
                if model.rows.isEmpty {
                    emptyState
                }
                if !follower.isAtEnd {
                    latestButton
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(Theme.Motion.quick, value: follower.isAtEnd)

            if isUncoilAuto {
                ChatWaitingAgents(participantIDs: model.participantIDs, projectID: record.projectID)
                    .frame(maxWidth: Self.columnWidth + 24)
                    .padding(.horizontal, 16)
                AutoRunStrip(conversation: autoState, projectID: record.projectID)
                    .frame(maxWidth: Self.columnWidth + 24)
                    .padding(.horizontal, 16)
            }
            ChatComposer(
                model: model,
                placeholder: isUncoilAuto
                    ? (autoTarget.map { target in
                        settings.uncoilAuto.harness.enabled && settings.uncoilAuto.harness.mode == .everyMessage
                            ? String(localized: "Give @\(target.handle) a task for an Auto run — @ to message an agent directly")
                            : String(localized: "Message @\(target.handle) — /auto for an Auto run, @ for another agent") }
                        ?? String(localized: "Message your agents — @ to choose one, / for commands"))
                    : String(localized: "Message \(record.provider.displayName)…"),
                isBusy: agentsWorking,
                onStop: isUncoilAuto ? { model.interrupt() } : nil,
                leading: isUncoilAuto
                    ? AnyView(UncoilAutoTargetPicker(conversation: autoState, roster: openRoster, resolved: autoTarget))
                    : nil
            )
            .frame(maxWidth: Self.columnWidth + 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
    }

    private var transcript: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    AgentChatRowView(row: row, model: model, provider: record.provider)
                }
            }
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(ChatScrollProbeView(follower: follower))
        }
        .uncoilScrollers()
        .accessibilityIdentifier("chat.transcript")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ProviderMark(provider: record.provider, size: 22)
            Text(isUncoilAuto
                ? String(localized: "Direct this project's agents from here")
                : String(localized: "What should \(record.provider.displayName) work on?"))
                .font(Theme.ui(.large, .medium))
                .foregroundStyle(Theme.text)
            Text(record.workingDirectory(in: project))
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var latestButton: some View {
        Button {
            follower.scrollToEnd()
        } label: {
            HStack(spacing: 5) {
                TablerIcon(name: "arrow-down", size: 11, color: Theme.text)
                Text("Latest")
                    .font(Theme.mono(.small, .medium))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.panelActive, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .elevated(.floating)
        }
        .buttonStyle(.pressable)
        .help(String(localized: "Jump to the latest message"))
        .accessibilityIdentifier("chat.latest")
    }
}

/// How a session is drawn: as a conversation or as a terminal.
enum SessionSurface: Equatable {
    case chat
    case terminal
}

/// What sits under a session's header: the chat for Uncoil Auto, the
/// terminal for everything else. An agent CLI is never replaced by the chat;
/// it keeps its own interface, structured or not.
struct SessionSurfaceView: View {
    let record: SessionRecord
    let project: Project
    let account: AccountProfile?

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore

    var body: some View {
        if TerminalRegistry.surface(for: record.provider) == .chat {
            AgentChatView(record: record, project: project, account: account) {
                SessionActions(projects: projectStore, sessions: sessionStore).restart(record.id)
            }
        } else {
            TerminalHostView(record: record, project: project, account: account)
        }
    }
}

/// Agents in the conversation that are waiting on the user in their own
/// terminal — a permission prompt the conversation cannot answer. One line
/// each, with the terminal a click away, above the field where the user is
/// already looking.
private struct ChatWaitingAgents: View {
    let participantIDs: Set<UUID>
    let projectID: UUID

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    private var waiting: [UncoilAutoRoster.Entry] {
        UncoilAutoRoster.entries(
            sessions: projectStore.sessions.filter { $0.projectID == projectID },
            installed: []
        ).filter { entry in
            guard let id = entry.sessionID, participantIDs.contains(id) else { return false }
            return sessionStore.status(of: id) == .waitingForPermission
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(waiting) { entry in
                HStack(spacing: 10) {
                    ProviderMark(provider: entry.provider, size: 13)
                    Text("@\(entry.handle) is waiting for you in its terminal")
                        .font(Theme.ui(.body, .medium))
                        .foregroundStyle(Theme.text)
                    if let id = entry.sessionID, let detail = sessionStore.detail(of: id) {
                        Text(detail)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Open Terminal") {
                        if let id = entry.sessionID { openWindow(.session, value: id) }
                    }
                    .buttonStyle(AccentButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1)
                )
            }
        }
        .padding(.bottom, waiting.isEmpty ? 0 : 6)
        .animation(Theme.Motion.standard, value: waiting.map(\.handle))
        .accessibilityIdentifier("chat.waitingAgents")
    }
}
