import SwiftUI

/// What a sleeping session shows instead of a terminal.
///
/// A stopped session still has a row, and opening it used to land on a terminal
/// that would never answer. This says what happened, what it costs to come back,
/// and offers the one action that matters.
struct SleepingSessionView: View {
    let record: SessionRecord
    let mode: SessionSleepMode
    let onWake: () -> Void

    private var headline: String {
        switch mode {
        case .suspended: String(localized: "This session is paused")
        case .hibernated: String(localized: "This session is asleep")
        }
    }

    /// Says what actually happened to the process, because the two are not the
    /// same promise: one is still there, the other has to be rebuilt.
    private var detail: String {
        switch mode {
        case .suspended:
            String(localized: "The agent is stopped and using no processor time. Waking it carries on exactly where it stopped.")
        case .hibernated:
            String(localized: "The agent has been closed and is using nothing at all. Waking it starts \(record.provider.displayName) again and resumes the conversation.")
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            TablerIcon(
                name: mode == .suspended ? "player-pause" : "moon",
                size: 26,
                color: Theme.textDim
            )
            VStack(spacing: 6) {
                Text(headline)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let sleptAt = record.sleptAt {
                Text(RelativeClock.short(since: sleptAt))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            Button(action: onWake) {
                Text("Wake")
            }
            .buttonStyle(AccentButtonStyle())
            .accessibilityIdentifier("session.wake")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.sleeping")
    }
}
