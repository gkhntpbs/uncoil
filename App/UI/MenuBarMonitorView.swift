import SwiftUI

/// Cross-window routing for the menu bar: the main window watches this and
/// selects whatever the monitor asked for.
@MainActor
final class MainRoute: ObservableObject {
    static let shared = MainRoute()
    /// Bumped alongside a request so repeat requests for the same target
    /// still reach the window.
    @Published var requestedSelection: MainSelection?
    @Published var requestCounter = 0
    /// What the main window currently shows. Read by the notification policy so
    /// "stay quiet about the session I am looking at" has something to compare.
    @Published var lastSelection: MainSelection?

    func request(_ selection: MainSelection) {
        requestedSelection = selection
        requestCounter += 1
    }
}

/// Menu-bar monitor: running agents, pending permissions, finished sessions
/// and problems, with quick launch, quick interrupt, and a way back into the
/// main window.
struct MenuBarMonitorLabel: View {
    let summary: MenuBarSummary
    var prefs = MenuBarPrefs()

    var body: some View {
        // By default the state lives in the logo itself — color while agents
        // work, yellow while something waits on the user, plain when idle — so
        // nothing crowds the menu bar. Counters are opt-in from Settings.
        HStack(spacing: 4) {
            switch prefs.icon(for: summary) {
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFit()
                    // The menu bar scales this label to its own height, so the
                    // frame is not what sets the icon's size: the inset baked
                    // into the artwork is (the `menu-bar-inset` group in the
                    // assets), which is what keeps the glyph lighter than the
                    // system symbols around it.
                    .frame(height: 18)
            case .symbol(let name):
                Image(systemName: name)
            case .none:
                EmptyView()
            }

            let label = prefs.label(for: summary)
            if !label.isEmpty {
                Text(label).font(.system(size: 11, weight: .medium))
            }
        }
        .accessibilityIdentifier("menuBar.label")
        .accessibilityValue(summary.headline)
    }
}

struct MenuBarMonitorMenu: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var attention = AttentionStore.shared
    let summary: MenuBarSummary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(summary.headline)
        if let tasks = summary.taskHeadline {
            Text(tasks)
        }

        Divider()

        if settings.menuBar.showTasksSection {
            taskSection
        }

        if settings.menuBar.showSessionsSection, !attention.items.isEmpty {
            ForEach(attention.items.prefix(6)) { item in
                Button("\(item.kind.label): \(item.title)") {
                    open(item)
                }
            }
            Divider()
        }

        let interruptible = MenuBarMonitorEngine.interruptible(
            projectStore.sessions, statuses: sessionStore.statuses
        )
        if !interruptible.isEmpty {
            Menu("Interrupt") {
                ForEach(interruptible) { record in
                    Button(label(for: record)) {
                        TerminalRegistry.shared.interrupt(record.id)
                    }
                }
                Divider()
                Button("Interrupt All") {
                    for record in interruptible {
                        TerminalRegistry.shared.interrupt(record.id)
                    }
                }
            }
        }

        if settings.menuBar.showQuickLaunch, !projectStore.projects.isEmpty {
            Menu("New Session") {
                ForEach(projectStore.projects) { project in
                    Menu(project.name) {
                        ForEach([AgentProvider.claude, .codex, .terminal]) { provider in
                            Button(provider.displayName) {
                                launch(project: project, provider: provider)
                            }
                        }
                    }
                }
            }
            Divider()
        }

        Button("Open Uncoil") {
            activateMainWindow()
        }
        .keyboardShortcut("o")
    }

    /// Task shortcuts: open a project's board, stop its orchestrator, and jump
    /// straight to the session working a task.
    @ViewBuilder
    private var taskSection: some View {
        let taskRows = attention.items.filter { $0.kind.isTaskRow && $0.sessionID != nil }
        if !projectStore.projects.isEmpty {
            Menu("Task Board") {
                ForEach(projectStore.projects) { project in
                    Button(project.name) {
                        MainRoute.shared.request(.project(project.id))
                        activateMainWindow()
                    }
                }
            }
        }
        if !taskRows.isEmpty {
            Menu("Task Session") {
                ForEach(taskRows.prefix(8)) { row in
                    Button("\(row.kind.label): \(row.title)") { open(row) }
                }
            }
        }
        if !projectStore.projects.isEmpty {
            Menu("Stop the Orchestrator") {
                ForEach(projectStore.projects) { project in
                    Button(project.name) { stopOrchestrator(project) }
                }
            }
        }
        Divider()
    }

    /// Drops the pending plan. Running agents are left alone on purpose —
    /// killing an agent mid-edit is the user's call, and "Interrupt" does that.
    private func stopOrchestrator(_ project: Project) {
        let store = OrchestratorStore(projectID: project.id)
        store.stopDispatching()
    }

    private func label(for record: SessionRecord) -> String {
        let project = projectStore.projects.first { $0.id == record.projectID }?.name
        return [project, record.displayTitle].compactMap { $0 }.joined(separator: " › ")
    }

    private func open(_ item: AttentionItem) {
        AttentionStore.shared.markRead(item.id)
        if let sessionID = item.sessionID {
            MainRoute.shared.request(.session(sessionID))
        } else if let projectID = item.projectID {
            MainRoute.shared.request(.project(projectID))
        }
        activateMainWindow()
    }

    private func launch(project: Project, provider: AgentProvider) {
        let account = settings.defaultAccount(for: provider)
        let record = projectStore.createSession(
            projectID: project.id,
            provider: provider,
            accountID: provider == .terminal ? nil : account?.id,
            title: provider == .terminal ? "terminal" : String(localized: "\(provider.rawValue): new session")
        )
        MainRoute.shared.request(.session(record.id))
        activateMainWindow()
    }

    private func activateMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
