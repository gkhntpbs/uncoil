import SwiftUI

/// One line saying what an agent last did, from its transcript.
enum AgentActivitySummary {
    static func line(for item: AgentItem) -> String {
        switch item.kind {
        case .userMessage(let text, _):
            return "› " + firstLine(text)
        case .agentMessage(let text):
            return firstLine(text)
        case .reasoning:
            return String(localized: "Thinking")
        case .command(let command, _, _):
            if command.hasPrefix("/") { return command }
            return "$ " + firstLine(AgentChatTranscript.displayCommand(command))
        case .fileChange(let changes):
            if changes.count == 1, let path = changes.first?.path {
                return String(localized: "Edited \((path as NSString).lastPathComponent)")
            }
            return String(localized: "Edited \(changes.count) files")
        case .toolCall(let call):
            if case .mcp(let server) = call.origin { return "\(server) › \(call.name)" }
            return call.name
        case .plan(let plan):
            let done = plan.steps.filter { $0.status == .completed }.count
            return String(localized: "Plan: \(done) of \(plan.steps.count) done")
        case .other(let type):
            return type
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return MarkdownInline.plain(String(line ?? "").trimmingCharacters(in: .whitespaces))
    }
}

/// What each agent in a project last did, read from its transcript.
///
/// Holds the transcripts open for as long as it lives, and reports the latest
/// item of each at most a few times a second.
@MainActor
final class AgentActivityModel: ObservableObject {
    @Published private(set) var latest: [UUID: String] = [:]

    private let hub: AgentEventHub
    private let observers: NativeSessionObservers
    private var followed: Set<UUID> = []
    private var observations: [UUID: AgentEventObservation] = [:]
    private var scheduled = false

    init(hub: AgentEventHub = .transcripts, observers: NativeSessionObservers = .shared) {
        self.hub = hub
        self.observers = observers
    }

    /// Follows exactly these sessions.
    func follow(_ ids: Set<UUID>, locator: (UUID) -> () -> NativeTranscriptLocation?) {
        for id in followed.subtracting(ids) {
            observations.removeValue(forKey: id)?.cancel()
            observers.release(id)
        }
        for id in ids.subtracting(followed) {
            observers.retain(id, locate: locator(id))
            observations[id] = hub.observe(id) { [weak self] _ in self?.scheduleRefresh() }
        }
        followed = ids
        refresh()
    }

    func stop() {
        follow([], locator: { _ in { nil } })
    }

    private func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        var next: [UUID: String] = [:]
        for id in followed {
            if let item = hub.timeline(for: id)?.items.last(where: AgentChatTranscript.isVisible) {
                next[id] = AgentActivitySummary.line(for: item)
            }
        }
        if next != latest { latest = next }
    }
}

/// The agents of the project, beside Uncoil Auto's conversation: who they
/// are, what state they are in, what they last did, how much of their limit
/// is left. Clicking one opens its own terminal in a window of its own.
struct UncoilAutoAgentsPanel: View {
    let projectID: UUID
    /// Starts an agent through the conversation, so the start is recorded
    /// there like any other command.
    let onStart: (AgentProvider) -> Void
    /// Puts `@handle` into the composer.
    let onMention: (String) -> Void

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var activity = AgentActivityModel()
    @ObservedObject private var theme = ThemeStore.shared

    static let width: CGFloat = 264
    /// Whether the panel is open, remembered like the sidebar's: one answer
    /// for every Uncoil Auto session, kept across launches.
    static let visibilityKey = "agentsPanelVisible"

    private var entries: [UncoilAutoRoster.Entry] {
        UncoilAutoRoster.entries(
            sessions: projectStore.sessions.filter { $0.projectID == projectID },
            installed: settings.installedProviders
        ).filter { $0.sessionID != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents")
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                startMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        if let id = entry.sessionID,
                           let record = projectStore.sessions.first(where: { $0.id == id }) {
                            AgentPanelRow(
                                entry: entry,
                                record: record,
                                activity: activity.latest[id],
                                onOpen: { openWindow(.session, value: id) },
                                onMention: { onMention(entry.handle) },
                                onStop: { TerminalRegistry.shared.interrupt(id) }
                            )
                        }
                    }
                    if entries.isEmpty {
                        Text("No agents in this project yet. Start one with + or /new.")
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .uncoilScrollers()
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarSurface)
        .onAppear(perform: follow)
        .onChange(of: entries.compactMap(\.sessionID)) { _ in follow() }
        .onDisappear { activity.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.agentsPanel")
    }

    private func follow() {
        activity.follow(Set(entries.compactMap(\.sessionID))) { id in
            NativeTranscriptLocation.locator(for: id, projects: projectStore, settings: settings)
        }
    }

    private var startMenu: some View {
        Menu {
            ForEach(AgentProvider.agents.filter { settings.installedProviders.contains($0) }) { provider in
                Button(provider.displayName) { onStart(provider) }
            }
        } label: {
            TablerIcon(name: "plus", size: 13, color: Theme.textDim)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Start an agent in this project"))
        .accessibilityIdentifier("chat.agentsPanel.start")
    }
}

private struct AgentPanelRow: View {
    let entry: UncoilAutoRoster.Entry
    let record: SessionRecord
    let activity: String?
    let onOpen: () -> Void
    let onMention: () -> Void
    let onStop: () -> Void

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false

    private var status: AgentSessionStatus { sessionStore.status(of: record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProviderMark(provider: entry.provider, size: 13)
                Text("@\(entry.handle)")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(entry.provider.color)
                Spacer(minLength: 4)
                StatusOrb(status: status, size: 10)
                if hovering {
                    TablerIcon(name: "external-link", size: 11, color: Theme.textFaint)
                }
            }
            Text(record.displayTitle)
                .font(Theme.ui(.small))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(sessionStore.detail(of: record.id) ?? status.label)
                .font(Theme.mono(.micro))
                .foregroundStyle(status.color)
                .lineLimit(1)
            if let activity {
                Text(activity)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            UsageChip(
                provider: entry.provider,
                account: settings.account(id: record.accountID),
                isWorking: status.isWorking
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.panelHover : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(String(localized: "Open Terminal Window"), action: onOpen)
            Button(String(localized: "Mention @\(entry.handle)"), action: onMention)
            if status.isWorking {
                Button(String(localized: "Stop"), action: onStop)
            }
        }
        .help(String(localized: "Open @\(entry.handle)'s own terminal in a window"))
        .accessibilityIdentifier("chat.agentsPanel.agent")
    }
}
