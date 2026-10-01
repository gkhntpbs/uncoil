import SwiftUI

/// What a session's MCP link is actually doing, for the one place that shows it.
///
/// "Is the control plane up" and "has this agent reached it" are different
/// questions, and only the second one distinguishes a working link from a
/// config that was written and never used. A helper that is killed at exec —
/// the failure that reads as `Failed to reconnect to uncoil` in the agent —
/// leaves the server running and the session silent, so the indicator has to
/// tell those two apart.
@MainActor
final class McpStatusStore: ObservableObject {
    static let shared = McpStatusStore()

    /// True while the control-plane socket server is accepting connections.
    @Published private(set) var isServing = false
    /// Last time each session's MCP helper reached the control plane.
    @Published private(set) var lastContact: [UUID: Date] = [:]

    private init() {}

    func setServing(_ serving: Bool) {
        guard isServing != serving else { return }
        isServing = serving
    }

    /// Called for every control-plane request, from whichever session made it.
    func recordContact(sessionID: UUID, at date: Date = .now) {
        lastContact[sessionID] = date
    }

    func forget(sessionID: UUID) {
        lastContact.removeValue(forKey: sessionID)
    }

    func state(for sessionID: UUID, now: Date = .now) -> McpLinkState {
        guard isServing else { return .off }
        guard let seen = lastContact[sessionID] else { return .waiting }
        // A link that has spoken once stays "connected": MCP is request-driven,
        // so a long quiet stretch means the agent had nothing to ask, not that
        // the link died.
        return .connected(since: seen)
    }
}

enum McpLinkState: Equatable {
    /// The control plane is not running, so no session has an MCP link.
    case off
    /// Serving, but this session's agent has not called in yet.
    case waiting
    /// This session's agent has reached the control plane.
    case connected(since: Date)

    var label: String {
        switch self {
        case .off: "MCP off"
        case .waiting: "MCP waiting"
        case .connected: "MCP connected"
        }
    }

    var help: String {
        switch self {
        case .off:
            "The Uncoil control plane is not running; this session has no uncoil MCP tools."
        case .waiting:
            "The control plane is up; the agent has not called the uncoil MCP yet."
        case .connected(let since):
            "Last uncoil MCP call: \(RelativeClock.short(since: since)) ago"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .off: Theme.textFaint
        case .waiting: Theme.warn
        case .connected: Theme.ok
        }
    }
}

/// The session header's MCP light.
struct McpStatusBadge: View {
    let sessionID: UUID
    /// A dot and a short word, for a row with little room.
    var compact = false
    @ObservedObject private var status = McpStatusStore.shared

    var body: some View {
        let state = status.state(for: sessionID)
        if compact {
            HStack(spacing: 4) {
                Circle().fill(state.color).frame(width: 6, height: 6)
                Text("MCP")
                    .font(Theme.mono(.micro, .medium))
                    .foregroundStyle(state.color)
            }
            .fixedSize()
            .help(state.help)
            .accessibilityIdentifier("session.mcpStatus.compact")
            .accessibilityValue(state.label)
        } else {
            badge(state)
        }
    }

    private func badge(_ state: McpLinkState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
            Text(state.label)
                .font(Theme.mono(.small, .medium))
                .foregroundStyle(state.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(state.color.opacity(0.10), in: Capsule())
        .fixedSize()
        .help(state.help)
        .accessibilityIdentifier("session.mcpStatus")
        .accessibilityValue(state.label)
    }
}

/// Whether the control plane is up: the one MCP fact that belongs to Uncoil
/// Auto itself rather than to one of its agents.
struct McpControlPlaneBadge: View {
    @ObservedObject private var status = McpStatusStore.shared

    var body: some View {
        let serving = status.isServing
        let color = serving ? Theme.ok : Theme.textFaint
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(serving ? String(localized: "Control plane up") : String(localized: "Control plane off"))
                .font(Theme.mono(.small, .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
        .help(serving
              ? String(localized: "The Uncoil control plane is serving; each agent's own MCP link shows in the agents panel.")
              : String(localized: "The Uncoil control plane is not running; agents have no uncoil MCP tools."))
        .accessibilityIdentifier("session.controlPlaneStatus")
    }
}
