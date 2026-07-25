import SwiftUI

/// The change plan for an agent config, shown before anything is written.
///
/// Uncoil never edits an agent's config without this step: the diff, the file it
/// touches and the backup that makes it reversible are all on screen first.
struct ConfigPlanSheet: View {
    let transaction: ConfigurationTransaction
    let summary: String
    /// Warnings the adapter reported about the config as it stands now.
    let issues: [ConfigurationIssue]
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Config değişiklik planı")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(transaction.agent.displayName) — \(summary)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textDim)
                Text(transaction.configPath)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider().overlay(Theme.border)

            ScrollView([.vertical, .horizontal]) {
                Text(transaction.diff.isEmpty ? "Değişiklik yok." : transaction.diff)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .uncoilScrollers()
            .accessibilityIdentifier("configPlan.diff")

            if !issues.isEmpty {
                Divider().overlay(Theme.border)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(issues.prefix(4)) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            TablerIcon(
                                name: issue.severity == .error ? "alert-triangle" : "info-circle",
                                size: 10,
                                color: issue.severity == .error ? Theme.danger : Theme.warn
                            )
                            Text(issue.message)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                Text("Uygulanmadan önce yedek alınır; tek tıkla geri dönebilirsin.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Vazgeç", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("configPlan.cancel")
                Button("Uygula", action: onApply)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(transaction.diff.isEmpty)
                    .accessibilityIdentifier("configPlan.apply")
            }
            .padding(16)
        }
        .frame(width: 620, height: 470)
        .background(Theme.bg)
        .accessibilityIdentifier("configPlan.sheet")
    }
}
