import SwiftUI

/// Start a session here.
///
/// The app's primary action used to be a strip of agent marks that appeared on
/// hover: a new user could look at the whole window and find no way to start
/// an agent, and on a trackpad the strip arrived over the row they were
/// reaching across. So the common answer — the agent you always use, in the
/// project you are pointing at — is now one visible click, and the rarer ones
/// (a different agent, a second login) are a right-click away rather than
/// hidden behind a hover the user has to discover first.
///
/// The menu is on the same button rather than beside it: two adjacent targets
/// where one says "start" and the other "start, but ask me first" is a choice
/// nobody wants to make at that size.
struct NewSessionButton: View {
    let project: Project
    var worktreePath: String?
    @Binding var selection: MainSelection?
    /// Drawn plainly until hovered, for rows that are dense with marks.
    var isProminent = false

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false

    private var launcher: SessionLauncher {
        SessionLauncher(projects: projectStore, settings: settings)
    }

    private var providers: [AgentProvider] { settings.launcherProviders }

    var body: some View {
        Button {
            if let provider = launcher.defaultProvider { start(provider) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering || isProminent ? Theme.text : Theme.textDim)
                .frame(width: 20, height: 20)
                .background(
                    hovering ? Theme.panelActive : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .disabled(launcher.defaultProvider == nil)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityIdentifier("project.newSession.\(project.name)")
        .contextMenu { menu }
    }

    private var helpText: String {
        guard let provider = launcher.defaultProvider else {
            return String(localized: "No agent is installed yet")
        }
        return String(localized: "Start \(provider.displayName) here — right-click for another agent")
    }

    @ViewBuilder
    private var menu: some View {
        ForEach(providers) { provider in
            let logins = settings.accounts(for: provider)
            // One login is not a choice: offering a submenu with a single item
            // in it would be two clicks to reach what the button already does.
            if provider.isAgent, logins.count > 1 {
                Menu(provider.displayName) {
                    ForEach(logins) { login in
                        Button(login.name) { start(provider, account: login) }
                    }
                }
            } else {
                Button(provider.displayName) { start(provider) }
            }
        }
    }

    private func start(_ provider: AgentProvider, account: AccountProfile? = nil) {
        let record = launcher.launch(
            provider, in: project, account: account, worktreePath: worktreePath
        )
        selection = .session(record.id)
    }
}
