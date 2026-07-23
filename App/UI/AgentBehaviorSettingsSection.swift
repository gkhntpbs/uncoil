import SwiftUI

/// Settings → Agent Ayarları: per-provider terminal behavior toggles. Today the
/// only toggle is Shift+Enter → literal newline (backslash + CR), which Claude
/// Code and the Codex TUI accept for an in-prompt newline. Applies live to open
/// sessions (the terminal reads the setting on each key event).
struct AgentBehaviorSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Klavye davranışı")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Shift+Enter (ve Option+Enter) prompt içinde satır atlar; agent'a "
                 + "gönderim yerine ters bölü + satır başı (\\⏎) yollar. Açık "
                 + "oturumlara anında uygulanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    providerRow(provider)
                    if index != providers.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.agentBehavior.container")
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                Text("Shift+Enter yeni satır")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.shiftEnterNewline(for: provider) },
                set: { settings.setShiftEnterNewline($0, for: provider) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier("settings.agentBehavior.shiftEnter.\(provider.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
