import SwiftUI

/// What every status dot means, shown when the pointer rests on one.
///
/// The dots carry a lot — seven colours and four kinds of motion — and nothing
/// in the app ever said which was which. This card lists every state in the
/// order a session moves through them, draws each with the real `StatusOrb`
/// (so the legend can never disagree with the dot), and marks the one the
/// session is in now.
struct StatusLegendCard: View {
    let current: AgentSessionStatus
    var detail: String?

    private struct Group: Identifiable {
        let id: String
        let title: String
        let states: [AgentSessionStatus]
    }

    private var groups: [Group] {
        [
            Group(id: "working", title: String(localized: "Working"),
                  states: [.thinking, .running, .waitingForSubagents, .waitingForBackground]),
            Group(id: "needsYou", title: String(localized: "Needs you"),
                  states: [.waitingForPermission, .waitingForInput]),
            Group(id: "quiet", title: String(localized: "Finished or quiet"),
                  states: [.completed, .idle]),
            Group(id: "stopped", title: String(localized: "Stopped"),
                  states: [.suspended, .hibernated, .terminated, .unknown]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: where this session is now.
            HStack(spacing: 10) {
                StatusOrb(status: current, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.label)
                        .font(Theme.mono(.body, .semibold))
                        .foregroundStyle(current.color)
                    if let detail, !detail.isEmpty, detail != current.label {
                        Text(detail)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(current.color.opacity(0.08))

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title)
                            .font(Theme.mono(.micro, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .padding(.horizontal, 6)
                        ForEach(group.states, id: \.self) { status in
                            row(status)
                        }
                    }
                }
            }
            .padding(10)

            Divider().overlay(Theme.border)

            HStack(spacing: 6) {
                TablerIcon(name: "adjustments", size: 11, color: Theme.textFaint)
                Text("Sidebar highlight and motion: Settings › Appearance")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusLegend")
    }

    private func row(_ status: AgentSessionStatus) -> some View {
        let isCurrent = status == current
        return HStack(alignment: .top, spacing: 9) {
            StatusOrb(status: status, size: 12)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(Theme.mono(.small, .semibold))
                        .foregroundStyle(status.color)
                    if isCurrent {
                        Text("now")
                            .font(Theme.mono(.micro, .bold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(status.color, in: Capsule())
                    }
                }
                Text(Self.meaning(of: status))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isCurrent ? status.color.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
        )
    }

    /// One plain sentence per state.
    static func meaning(of status: AgentSessionStatus) -> String {
        switch status {
        case .thinking: String(localized: "Reading and planning before it acts.")
        case .running: String(localized: "Running a tool, a command or editing files.")
        case .waitingForSubagents: String(localized: "Its own turn is over; sub-agents it started are still working.")
        case .waitingForBackground: String(localized: "Turn ended, but a command it started is still running. It continues when that finishes.")
        case .waitingForPermission: String(localized: "Asking to use a tool. Nothing happens until you answer.")
        case .waitingForInput: String(localized: "Finished its turn and waiting for your next message.")
        case .completed: String(localized: "The turn finished.")
        case .idle: String(localized: "Ready for a message.")
        case .suspended: String(localized: "Paused on purpose; resumes exactly where it was.")
        case .hibernated: String(localized: "Process stopped to save resources; the conversation comes back on wake.")
        case .terminated: String(localized: "Ended. The session stays in the history.")
        case .unknown: String(localized: "Uncoil is still asking the runtime about it.")
        }
    }
}

/// Shows `StatusLegendCard` after the pointer rests on the view — the same
/// rules as hover help: a short delay, one bubble at a time, never over a
/// menu, a sheet or the palette.
private struct StatusLegendHover: ViewModifier {
    let status: AgentSessionStatus
    let detail: String?
    @State private var hovering = false
    @State private var showing = false
    @State private var popupHovered = false
    @State private var id = UUID()
    @ObservedObject private var popups = TransientPopups.shared

    func body(content: Content) -> some View {
        content
            .accessibilityHint(StatusLegendCard.meaning(of: status))
            .onHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering else {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled, !popupHovered { showing = false }
                    return
                }
                try? await Task.sleep(for: .milliseconds(550))
                if !Task.isCancelled, hovering, NSEvent.pressedMouseButtons == 0,
                   popups.claimHelp(id) {
                    showing = true
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                StatusLegendCard(current: status, detail: detail)
                    .onHover {
                        popupHovered = $0
                        if !$0, !hovering { showing = false }
                    }
            }
            .onChange(of: popups.activeHelp) { _, active in
                if active != id, showing { showing = false }
            }
            .onChange(of: showing) { _, now in if !now { popups.releaseHelp(id) } }
            .dismissWithTransientPopups($showing)
            .onDisappear { showing = false; popups.releaseHelp(id) }
    }
}

extension View {
    /// Hovering shows what every status colour and motion means.
    func statusLegend(_ status: AgentSessionStatus, detail: String? = nil) -> some View {
        modifier(StatusLegendHover(status: status, detail: detail))
    }
}
