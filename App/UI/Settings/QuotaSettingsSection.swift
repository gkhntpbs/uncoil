import SwiftUI

struct QuotaSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Section("Unused Weekly Quota") {
            Picker(selection: binding(\.mode)) {
                ForEach(QuotaOptimizationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsLabel(title: String(localized: "Before quota resets"))
            }
            .settingsID("usage.quota.mode")

            if settings.quotaOptimization.mode != .ignore {
                Picker(selection: binding(\.resetWithinHours)) {
                    ForEach([6, 12, 24, 48, 72], id: \.self) { hours in
                        Text("\(hours) hours").tag(hours)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Notify within"),
                                  detail: String(localized: "How soon before the weekly reset to look for unused quota."))
                }
                .settingsID("usage.quota.resetHours")

                Picker(selection: binding(\.minimumUnusedPercent)) {
                    ForEach([5, 10, 20, 30, 50, 75, 90], id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Minimum unused quota"))
                }
                .settingsID("usage.quota.minimumUnused")

                SettingsNote(String(localized: "One notification per account and weekly reset. Follows notification settings and quiet hours. Estimates use at least 30 minutes of recent observations; without enough history, only the available quota is reported. Uncoil must be running."))

                if settings.quotaOptimization.mode == .preferUnusedQuota {
                    SettingsNote(String(localized: "When Auto has no selected target, it prefers eligible agents whose quota may expire unused. Selected targets, @mentions and specialist roles stay as configured. No work is started just to spend quota."))
                }
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<QuotaOptimizationPrefs, Value>) -> Binding<Value> {
        Binding(get: { settings.quotaOptimization[keyPath: path] }, set: { value in
            var prefs = settings.quotaOptimization
            prefs[keyPath: path] = value
            settings.setQuotaOptimization(prefs)
        })
    }
}
