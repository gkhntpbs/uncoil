import Foundation

/// Where an alert on the Settings gear leads.
///
/// The gear's red badge counts agents with a CLI update waiting. A badge that
/// opens Settings at whatever page was last shown leaves the user to hunt for
/// its cause, so the click follows the badge to its source instead.
enum SettingsAttention {
    /// The pane to open for these pending updates: the agent's own page when
    /// there is exactly one, the agent list (which marks each one) otherwise,
    /// and nil — keep the last page — when nothing is waiting.
    static func pane(for pendingUpdates: [AgentProvider]) -> String? {
        switch pendingUpdates.count {
        case 0: nil
        case 1: SettingsView.Pane.agent(pendingUpdates[0]).id
        default: SettingsView.Pane.agents.id
        }
    }
}
