import SwiftUI

/// The detail behind the chip: every window this account has, what is left in
/// each, when each resets, and where the figures came from.
///
/// A popover rather than a floating panel. What it shows belongs to the chip
/// that opened it — this account, in this header — and a HUD that outlived the
/// session it described would go on showing one account's limits beside
/// another's terminal. It closes when you look away, which is the right
/// lifetime for something you opened to check a number.
struct UsageCard: View {
    let provider: AgentProvider
    let account: AccountProfile?
    let entry: UsageEntry
    let now: Date
    /// The user's own "low" threshold, so the bars agree with the chip that
    /// opened them.
    var threshold: Double = UsageDisplay.Severity.criticalPercent
    let onRefresh: () -> Void

    private var snapshot: UsageSnapshot? { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)

            if let snapshot, snapshot.hasQuota {
                windows(of: snapshot)
                if let credits = snapshot.credits {
                    Divider().overlay(Theme.border)
                    creditsRow(credits)
                }
            } else {
                unavailable
            }

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 300)
        .background(Theme.panel)
        .accessibilityIdentifier("session.usageCard")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ProviderMark(provider: provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(account?.name ?? provider.displayName)
                    .font(Theme.mono(.body, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                // The plan, and the email underneath it when the provider gave
                // one. Shown because a limit belongs to an account, and the
                // fastest way to misread a figure is to attribute it to the
                // wrong login.
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)

            if entry.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 26, height: 24)
            } else {
                ControlButton(
                    iconName: "refresh",
                    help: String(localized: "Read usage again now"),
                    identifier: "session.usageRefresh",
                    action: onRefresh
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var subtitle: String? {
        let identity = snapshot?.identity
        let parts = [identity?.plan, identity?.email ?? identity?.organization]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Windows

    private func windows(of snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(snapshot.allWindows) { window in
                UsageWindowRow(
                    window: window, now: now, dimmed: snapshot.stale, threshold: threshold
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func creditsRow(_ credits: UsageCredits) -> some View {
        HStack(spacing: 7) {
            TablerIcon(name: "coin", size: 12, color: Theme.textFaint)
            // Money, kept visibly apart from the bars above it: credits buy
            // usage past a limit, so a balance beside a percentage would read
            // as part of the same allowance.
            Text(creditsText(credits))
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func creditsText(_ credits: UsageCredits) -> String {
        if let balance = credits.balance {
            let amount = String(format: "%.2f", balance)
            let currency = credits.currency ?? ""
            return String(localized: "\(currency) \(amount) in credits, separate from the limits above")
                .trimmingCharacters(in: .whitespaces)
        }
        return credits.summary ?? String(localized: "Credits available")
    }

    // MARK: - Nothing to show

    /// The state the whole layer exists to make possible: no number, and a
    /// reason instead of a zero.
    private var unavailable: some View {
        HStack(alignment: .top, spacing: 9) {
            TablerIcon(name: iconForReason, size: 14, color: Theme.textFaint)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "No usage figures"))
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.textDim)
                Text(explanation)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var reason: UsageUnavailability? {
        snapshot?.unavailable
    }

    private var explanation: String {
        guard let snapshot else {
            return String(localized: "Uncoil has not read usage for this account yet.")
        }
        guard let reason = snapshot.unavailable else {
            return String(localized: "\(provider.displayName) reported no windows for this account.")
        }
        return UsageDisplay.explanation(reason, provider: provider)
    }

    /// A key for a login to fix, a plug for one that is simply not reported.
    private var iconForReason: String {
        switch reason {
        case .noCredentials, .credentialsRejected: "key"
        case .accountTierUnsupported, .authenticationTypeUnsupported, .providerUnsupported: "gauge-off"
        case .planReportsNoQuota: "infinity"
        case .allStrategiesFailed, .none: "cloud-off"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot {
                Text(UsageDisplay.provenance(snapshot, accountName: account?.name, now: now))
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            // Said out loud rather than implied by a dimmed colour: numbers
            // that are being kept because a refresh failed look exactly like
            // numbers that are current.
            if entry.isStale, let error = entry.error {
                HStack(spacing: 5) {
                    TablerIcon(name: "alert-circle", size: 11, color: Theme.warn)
                    Text(String(localized: "Last refresh failed (\(error)); showing the previous reading."))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - One window

/// A window's name, what is left of it, and when it comes back.
struct UsageWindowRow: View {
    let window: UsageWindow
    let now: Date
    var dimmed: Bool = false
    var threshold: Double = UsageDisplay.Severity.criticalPercent

    private var severity: UsageDisplay.Severity {
        .forRemaining(window.remainingPercent, threshold: threshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(Theme.mono(.small, .medium))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int(window.remainingPercent.rounded(.down)))%")
                    .font(Theme.mono(.body, .bold))
                    .foregroundStyle(severity.color.opacity(dimmed ? 0.55 : 1))
                    .monospacedDigit()
                Text(String(localized: "left"))
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }

            // A bar here rather than a ring: with room for a full width, length
            // compares between rows at a glance, which is the question the card
            // answers that the chip cannot — which of these limits binds first.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.border.opacity(0.6))
                    Capsule()
                        .fill(severity.color.opacity(dimmed ? 0.5 : 0.95))
                        .frame(
                            width: max(2, geometry.size.width * min(1, window.remainingPercent / 100))
                        )
                }
            }
            .frame(height: 4)
            .animation(Theme.Motion.standard, value: window.remainingPercent)

            if let reset = UsageDisplay.resetLine(window, now: now) {
                HStack(spacing: 4) {
                    TablerIcon(name: "clock", size: 10, color: Theme.textFaint)
                    Text(reset)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(window.title)
        .accessibilityValue("\(Int(window.remainingPercent.rounded(.down))) percent remaining")
    }
}
