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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: summary.symbolName)
            if !summary.label.isEmpty {
                Text(summary.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
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

        Divider()

        if !attention.items.isEmpty {
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
            Menu("Kes") {
                ForEach(interruptible) { record in
                    Button(label(for: record)) {
                        TerminalRegistry.shared.interrupt(record.id)
                    }
                }
                Divider()
                Button("Tümünü Kes") {
                    for record in interruptible {
                        TerminalRegistry.shared.interrupt(record.id)
                    }
                }
            }
        }

        if !projectStore.projects.isEmpty {
            Menu("Yeni Oturum") {
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

        Button("Uncoil’i Aç") {
            activateMainWindow()
        }
        .keyboardShortcut("o")
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
            title: provider == .terminal ? "terminal" : "\(provider.rawValue): yeni oturum"
        )
        MainRoute.shared.request(.session(record.id))
        activateMainWindow()
    }

    private func activateMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
