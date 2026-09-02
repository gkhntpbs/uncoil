import AppKit
import SwiftUI

/// The Agents screen's opening card: every agent Uncoil knows about, whether it
/// is on this machine, how deeply Uncoil can work with it, and the one thing
/// that would improve that.
///
/// Deliberately lists agents that are *not* installed too. "Cursor: not found"
/// is information — it tells the user Uncoil looked — and it is the only way a
/// row can appear the moment they install one.
///
/// Settings › Agents is where agents are managed; this card mirrors it rather
/// than competing with it, which is why "Locate…" opens the same
/// `AgentLocationPicker` and writes to the same setting. Acting here and acting
/// there are the same act.
struct AgentHookupCard: View {
    @ObservedObject var hookup: AgentHookupService
    @Binding var message: String?
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SectionCard(
            title: String(localized: "Connected agents"),
            detail: summary
        ) {
            ForEach(Array(hookup.states.enumerated()), id: \.element.id) { index, state in
                if index > 0 { Divider().overlay(Theme.border) }
                AgentHookupRow(
                    state: state,
                    chosenLocation: settings.agentBinaryLocation(
                        forCommand: state.agent.cliBinaryName
                    ),
                    isChosenLocationReachable: BinarySearchPath.userLocationIsReachable(
                        for: state.agent.cliBinaryName
                    ),
                    action: {
                        Task {
                            await hookup.apply(to: state.agent)
                            message = hookup.lastError ?? completionMessage(for: state)
                        }
                    },
                    onLocate: { locate(state.agent) },
                    onClearLocation: { clearLocation(state.agent) }
                )
            }

            Divider().overlay(Theme.border)
            FlowRow(spacing: 9) {
                Button(hookup.isScanning ? "Scanning…" : "Rescan") {
                    Task { await hookup.scan() }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(hookup.isScanning)
                .accessibilityIdentifier("extensions.hookup.rescan")

                if !hookup.actionable.isEmpty {
                    Button("Connect all (\(hookup.actionable.count))") {
                        Task {
                            await hookup.connectAll()
                            message = hookup.lastError
                                ?? String(localized: "Every agent Uncoil could connect is connected.")
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.hookup.connectAll")
                }
            }

            if let error = hookup.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
        }
        .task { await hookup.scan() }
    }

    // MARK: - Pointing Uncoil at a location

    /// The panel itself lives in `AgentLocationPicker`, shared with Settings ›
    /// Agents so the two surfaces cannot drift apart.
    private func locate(_ agent: ExtensionAgentID) {
        AgentLocationPicker.choose(for: agent, settings: settings) { text, changed in
            message = text
            if changed { Task { await hookup.scan() } }
        }
    }

    private func clearLocation(_ agent: ExtensionAgentID) {
        message = AgentLocationPicker.clear(for: agent, settings: settings)
        Task { await hookup.scan() }
    }

    private var summary: String {
        guard !hookup.installed.isEmpty else {
            return String(localized: "No agent CLI found on this machine.")
        }
        // Count only agents Uncoil can connect *by itself*. A detection-only
        // agent is neither connected nor connectable, and one whose ceiling
        // needs the user to approve a config change (Amp) would sit in the
        // denominator forever, reporting a shortfall nothing here can close.
        let connectable = hookup.installed.filter {
            $0.support.ceiling > .none && $0.support.isAutomatic
        }
        guard !connectable.isEmpty else {
            return String(localized: "Agents were found, but none of them can be connected yet.")
        }
        return String(
            format: String(localized: "%1$lld of %2$lld connectable agents are fully connected."),
            connectable.filter(\.isFullyWired).count,
            connectable.count
        )
    }

    private func completionMessage(for state: AgentIntegrationState) -> String {
        String(
            format: String(localized: "%@ is connected."),
            state.agent.displayName
        )
    }
}

/// One agent's line: name, where it is, what level it is at, and its actions.
private struct AgentHookupRow: View {
    let state: AgentIntegrationState
    /// The location the user pointed Uncoil at, if they have.
    let chosenLocation: String?
    /// False when that location has gone away — an ejected disk, a reinstall
    /// that moved. Worth saying, because the agent may still be found by the
    /// ordinary search and the row would otherwise look untroubled.
    let isChosenLocationReachable: Bool
    let action: () -> Void
    let onLocate: () -> Void
    let onClearLocation: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AgentMark(agent: state.agent, size: 13)
                        .opacity(state.isInstalled ? 1 : 0.4)
                    Text(state.agent.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(levelLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                }
                Text(state.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                if let chosenLocation {
                    Text(AgentLocationPicker.detail(
                        for: chosenLocation, isReachable: isChosenLocationReachable
                    ))
                        .font(.system(size: 10))
                        .foregroundStyle(isChosenLocationReachable ? Theme.textFaint : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "extensions.hookup.location.\(state.agent.rawValue)"
                        )
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let pending = state.pendingAction {
                    Button(pending.label, action: action)
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier(
                            "extensions.hookup.action.\(state.agent.rawValue)"
                        )
                }
                Button(chosenLocation == nil ? "Locate…" : "Change…", action: onLocate)
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.hookup.locate.\(state.agent.rawValue)")
                if chosenLocation != nil {
                    Button("Clear", action: onClearLocation)
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier(
                            "extensions.hookup.clearLocation.\(state.agent.rawValue)"
                        )
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("extensions.hookup.row.\(state.agent.rawValue)")
    }

    private var levelLabel: String {
        state.isInstalled ? state.active.label : String(localized: "Not found")
    }

    /// Green only when the agent is at its own ceiling — not at Claude Code's.
    /// Holding every agent to the best level *any* agent reaches would paint
    /// Codex amber forever for a limitation the user cannot do anything about.
    /// `isFullyWired` already refuses a `.none` ceiling, so "detected only"
    /// stays grey without a special case here.
    private var dotColor: Color {
        guard state.isInstalled else { return Theme.textFaint }
        if state.pendingAction != nil { return Theme.warn }
        return state.isFullyWired ? Theme.ok : Theme.textDim
    }
}
