import SwiftUI

/// Settings › Agents › Installed Agents — the home of agent control.
///
/// One row per agent Uncoil knows about, each with its brand mark, whether it
/// is on this machine, how deeply Uncoil talks to it, and the single action
/// that would improve that. The Extensions window's card is a summary of the
/// same service; this page is where the user is sent to act.
///
/// It is also where an agent that Uncoil could not find is dealt with. The
/// eight directories `BinarySearchPath` knows cannot cover every way a CLI gets
/// onto a Mac — nix, pipx, mise, a company image, an install kept on an
/// external disk — so every row can be pointed at a location by hand, whether
/// or not the agent was found. Nothing is imported or copied: the path is
/// remembered and searched, and the install stays exactly where it is.
struct AgentsSettingsPage: View {
    /// Opens one agent's own page. This list is the only way in: an agent is
    /// configured from the row that already says whether it was found.
    let open: (AgentProvider) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var hookup = AgentHookupService.shared
    /// What the last locate or clear did, shown under the list. The Extensions
    /// card has a banner of its own for this; a settings page does not, so it
    /// keeps the sentence itself.
    @State private var locationMessage: String?

    var body: some View {
        SettingsPage(
            title: String(localized: "Installed Agents"),
            subtitle: String(localized: "Every agent CLI Uncoil found on this Mac, and how deeply it is connected.")
        ) {
            Section {
                UncoilAutoSettingsRow(open: { open(.uncoil) })
            } header: {
                Text("Uncoil")
            }

            Section {
                ForEach(hookup.states) { state in
                    AgentControlRow(
                        state: state,
                        version: version(for: state),
                        hasUpdate: state.agent.provider.map { settings.updateAvailable(for: $0) } ?? false,
                        chosenLocation: settings.agentBinaryLocation(
                            forCommand: state.agent.cliBinaryName
                        ),
                        isChosenLocationReachable: BinarySearchPath.userLocationIsReachable(
                            for: state.agent.cliBinaryName
                        ),
                        action: { Task { await hookup.apply(to: state.agent) } },
                        disconnect: state.active == .hooks
                            ? { Task { await hookup.disconnect(state.agent) } }
                            : nil,
                        onLocate: { locate(state.agent) },
                        onClearLocation: { clearLocation(state.agent) },
                        onOpen: state.agent.provider.map { provider in
                            { open(provider) }
                        }
                    )
                }
            } footer: {
                HStack {
                    if let at = hookup.lastScanAt {
                        Text("Scanned \(RelativeClock.short(since: at))")
                            .font(.caption)
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    if !hookup.actionable.isEmpty {
                        Button("Connect all (\(hookup.actionable.count))") {
                            Task { await hookup.connectAll() }
                        }
                        .settingsID("agents.connectAll")
                    }
                    Button {
                        Task { await hookup.scan() }
                    } label: {
                        if hookup.isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Scanning…")
                            }
                        } else {
                            Text("Rescan")
                        }
                    }
                    .disabled(hookup.isScanning)
                    .settingsID("agents.rescan")
                }
            }

            if let locationMessage {
                Section {
                    SettingsStatusLine(level: .neutral, text: locationMessage)
                }
            }

            if let error = hookup.lastError {
                Section {
                    SettingsStatusLine(level: .error, text: error)
                }
            }
        }
        .task { await hookup.scan() }
    }

    /// The panel is `AgentLocationPicker`'s, shared with the Extensions card so
    /// the wording and the refusal are the same wherever it is opened from.
    private func locate(_ agent: ExtensionAgentID) {
        AgentLocationPicker.choose(for: agent, settings: settings) { text, changed in
            locationMessage = text
            if changed { Task { await hookup.scan() } }
        }
    }

    private func clearLocation(_ agent: ExtensionAgentID) {
        locationMessage = AgentLocationPicker.clear(for: agent, settings: settings)
        Task { await hookup.scan() }
    }

    /// Versions come from the CLI-tools store for the agents Uncoil launches;
    /// the others have not been asked, and inventing an answer is worse.
    private func version(for state: AgentIntegrationState) -> String? {
        state.installation?.version
            ?? state.agent.provider.flatMap { settings.cliVersions[$0.rawValue] }
    }
}

private struct AgentControlRow: View {
    let state: AgentIntegrationState
    let version: String?
    /// A newer CLI is waiting — the cause of the Settings gear's red badge.
    let hasUpdate: Bool
    /// The location the user pointed Uncoil at, if they have.
    let chosenLocation: String?
    /// False when that location has gone away — an ejected disk, a reinstall
    /// that moved. `BinarySearchPath` falls back to the ordinary search so the
    /// agent does not vanish, which is exactly why the row has to say it.
    let isChosenLocationReachable: Bool
    let action: () -> Void
    /// Present only while the agent reports live events; removing hooks from
    /// an agent that has none would be a button with nothing behind it.
    let disconnect: (() -> Void)?
    let onLocate: () -> Void
    let onClearLocation: () -> Void
    /// Absent for an agent Uncoil only knows as an extension host: there is no
    /// provider behind it to launch, so there is nothing on a page for it.
    let onOpen: (() -> Void)?

    var body: some View {
        AdaptiveRow {
            HStack(spacing: 10) {
                AgentMark(agent: state.agent, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state.agent.displayName)
                        if let version {
                            Text(version)
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                        }
                        if hasUpdate {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.danger).frame(width: 7, height: 7)
                                Text("update available")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.danger)
                            }
                            .accessibilityIdentifier("settings.agents.update.\(state.agent.rawValue)")
                        }
                    }
                    Text(state.statusDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    if let chosenLocation {
                        Text(AgentLocationPicker.detail(
                            for: chosenLocation, isReachable: isChosenLocationReachable
                        ))
                        .font(.caption2)
                        .foregroundStyle(isChosenLocationReachable ? Theme.textFaint : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "settings.agents.location.\(state.agent.rawValue)"
                        )
                    }
                }
            }
        } control: {
            HStack(spacing: 8) {
                if !state.isInstalled {
                    Text("not installed")
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                } else if let pending = state.pendingAction {
                    SettingsStatusLine(level: .warning, text: state.active.label)
                    Button(pending.label, action: action)
                        .settingsID("agents.action.\(state.agent.rawValue)")
                } else {
                    // At its own ceiling. A "detected only" ceiling earns no
                    // green: nothing is connected, there is just nothing to do.
                    SettingsStatusLine(
                        level: state.isFullyWired ? .ok : .neutral,
                        text: state.active.label
                    )
                    if let disconnect {
                        Button("Disconnect", action: disconnect)
                            .settingsID("agents.disconnect.\(state.agent.rawValue)")
                    }
                }
                // Offered whether or not the agent was found: the row that says
                // "not installed" is the one a user is looking at when they know
                // perfectly well where they put it, and an agent Uncoil *did*
                // find may still be the wrong copy of two.
                Button(chosenLocation == nil ? "Locate…" : "Change…", action: onLocate)
                    .settingsID("agents.locate.\(state.agent.rawValue)")
                if chosenLocation != nil {
                    Button("Clear", action: onClearLocation)
                        .settingsID("agents.clearLocation.\(state.agent.rawValue)")
                }
                if let onOpen {
                    Button(action: onOpen) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Logins, working mode and run parameters"))
                    .settingsID("agents.configure.\(state.agent.rawValue)")
                }
            }
        }
        // The whole row opens the agent, not just the chevron. The buttons
        // inside it keep working because a control is hit-tested before its
        // container: only a click that lands on none of them reaches this
        // gesture, which is the same boundary the sidebar's hosted rows rely
        // on. The chevron stays as the thing that says the row is a door.
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityIdentifier("settings.agents.row.\(state.agent.rawValue)")
    }
}


/// Uncoil's own entry above the agent CLIs: it is configured like one, but
/// has no binary to find and nothing to connect.
private struct UncoilAutoSettingsRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ProviderMark(provider: .uncoil, size: 18)
                SettingsLabel(
                    title: String(localized: "Uncoil Auto"),
                    detail: String(localized: "Which agents it can reach, and how Auto runs are staffed and decided."))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsID("agents.uncoilAuto")
    }
}
