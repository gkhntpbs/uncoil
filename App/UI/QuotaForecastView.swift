import SwiftUI

struct QuotaForecastView: View {
    let snapshot: UsageSnapshot
    let now: Date
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var monitor = QuotaMonitor.shared

    var body: some View {
        if settings.quotaOptimization.mode != .ignore,
           let forecast = monitor.forecast(for: snapshot, now: now),
           forecast.isOpportunity(settings.quotaOptimization, now: now) || forecast.burnRatePerHour != nil {
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 5) {
                Label(String(localized: "Weekly quota outlook"), systemImage: "clock.arrow.circlepath")
                    .font(Theme.ui(.small, .semibold))
                    .foregroundStyle(Theme.text)
                Text(forecast.detail(now: now))
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let burn = forecast.burnRatePerHour {
                    let rate = burn.formatted(.number.precision(.fractionLength(1)))
                    Text("Recent use: \(rate) percentage points/hour")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not enough history to estimate unused quota yet.")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .accessibilityIdentifier("session.quotaForecast")
        }
    }
}
