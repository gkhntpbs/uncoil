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
        case .off: "MCP kapalı"
        case .waiting: "MCP bekliyor"
        case .connected: "MCP bağlı"
        }
    }

    var help: String {
        switch self {
        case .off:
            "Uncoil kontrol düzlemi çalışmıyor; bu oturumun uncoil MCP araçları yok."
        case .waiting:
            "Kontrol düzlemi açık, ajan henüz uncoil MCP'sini çağırmadı."
        case .connected(let since):
            "Son uncoil MCP çağrısı: \(RelativeClock.short(since: since)) önce"
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
    @ObservedObject private var status = McpStatusStore.shared

    var body: some View {
        let state = status.state(for: sessionID)
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
            Text(state.label)
                .font(Theme.mono(10, .medium))
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
