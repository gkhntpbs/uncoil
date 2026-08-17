import SwiftUI

/// Settings › Agents › Installed Agents — the home of agent control.
///
/// One row per agent Uncoil knows about, each with its brand mark, whether it
/// is on this machine, how deeply Uncoil talks to it, and the single action
/// that would improve that. The Extensions window's card is a summary of the
/// same service; this page is where the user is sent to act.
struct AgentsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var hookup = AgentHookupService.shared

    var body: some View {
        SettingsPage(
            title: String(localized: "Installed Agents"),
            subtitle: String(localized: "Every agent CLI Uncoil found on this Mac, and how deeply it is connected.")
        ) {
            Section {
                ForEach(hookup.states) { state in
                    AgentControlRow(
                        state: state,
                        version: version(for: state),
                        action: { Task { await hookup.apply(to: state.agent) } },
                        disconnect: state.active == .hooks
                            ? { Task { await hookup.disconnect(state.agent) } }
                            : nil
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

            if let error = hookup.lastError {
                Section {
                    SettingsStatusLine(level: .error, text: error)
                }
            }
        }
        .task { await hookup.scan() }
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
    let action: () -> Void
    /// Present only while the agent reports live events; removing hooks from
    /// an agent that has none would be a button with nothing behind it.
    let disconnect: (() -> Void)?

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
                    }
                    Text(state.statusDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } control: {
            if !state.isInstalled {
                Text("not installed")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            } else if let pending = state.pendingAction {
                HStack(spacing: 8) {
                    SettingsStatusLine(level: .warning, text: state.active.label)
                    Button(pending.label, action: action)
                        .settingsID("agents.action.\(state.agent.rawValue)")
                }
            } else {
                HStack(spacing: 8) {
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
            }
        }
        .accessibilityIdentifier("settings.agents.row.\(state.agent.rawValue)")
    }
}
