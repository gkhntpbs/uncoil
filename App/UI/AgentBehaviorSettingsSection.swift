import SwiftUI
import AppKit

/// Settings → Agent Ayarları: per-provider terminal behavior toggles and the
/// command-palette hotkey. The Shift+Enter toggle sends a literal newline
/// (backslash + CR), which Claude Code and the Codex TUI accept for an in-prompt
/// newline. Applies live to open sessions (the terminal reads the setting on
/// each key event).
struct AgentBehaviorSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            quitBehavior
            workingModes
            keyboardBehavior
            hotkeySection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.agentBehavior.container")
    }

    private var quitBehavior: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uygulama kapanışı")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Uncoil’den çıkıldığında çalışan oturumlara ne olacağını seç.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(SessionQuitBehavior.allCases.enumerated()), id: \.element) {
                    index,
                    behavior in
                    Button {
                        settings.setSessionQuitBehavior(behavior)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: settings.sessionQuitBehavior == behavior
                                ? "largecircle.fill.circle"
                                : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(
                                    settings.sessionQuitBehavior == behavior
                                        ? Theme.claude : Theme.textFaint
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(behavior.title)
                                    .font(Theme.mono(12, .medium))
                                    .foregroundStyle(Theme.text)
                                Text(behavior.detail)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textFaint)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "settings.agentBehavior.quit.\(behavior.rawValue)"
                    )
                    .accessibilityValue(
                        settings.sessionQuitBehavior == behavior ? "selected" : "not selected"
                    )
                    if index != SessionQuitBehavior.allCases.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var workingModes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Varsayılan agent modu")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Her agent kendi desteklediği modlarla gösterilir. Yeni oturumlar seçilen modda başlar.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    workingModeRow(provider)
                    if index != providers.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var keyboardBehavior: some View {
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
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Klavye kısayolları")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Komut paletini açan kısayol. En az bir değiştirici tuş (⌘⌥⌃⇧) "
                 + "gerekir. Değişiklik anında uygulanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            HStack(spacing: 10) {
                TablerIcon(name: "command", size: 12, color: Theme.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Komut paleti")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text)
                    Text("Paleti aç / kapat")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                HotkeyRecorder(
                    binding: settings.commandPaletteHotkey,
                    onCapture: { settings.setCommandPaletteHotkey($0) }
                )
                Button {
                    settings.resetCommandPaletteHotkey()
                } label: {
                    Text("Sıfırla")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.hotkey.palette.reset")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .panel()
        }
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

    private func workingModeRow(_ provider: AgentProvider) -> some View {
        let selected = settings.workingMode(for: provider)
        return HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                Text(selected.detail(for: provider))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { settings.workingMode(for: provider) },
                set: { settings.setWorkingMode($0, for: provider) }
            )) {
                ForEach(AgentWorkingMode.options(for: provider)) { mode in
                    Text(mode.label(for: provider)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
            .accessibilityIdentifier("settings.agentBehavior.workingMode.\(provider.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// A pill button that shows the current shortcut and, when clicked, records the
/// next key+modifier chord via a temporary local key monitor. Rejects bare keys
/// (needs ≥1 modifier) and cancels on Escape.
private struct HotkeyRecorder: View {
    let binding: HotkeyBinding
    let onCapture: (HotkeyBinding) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? "Tuşa basın…" : binding.displayString)
                .font(Theme.mono(12, .medium))
                .foregroundStyle(recording ? Theme.text : Theme.textDim)
                .frame(minWidth: 52)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(recording ? Theme.panelActive : Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(recording ? Theme.claude : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hotkey.palette.recorder")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording without changing the binding.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let mods = HotkeyBinding.canonicalizeModifiers(event.modifierFlags.rawValue)
            // Require at least one real modifier; ignore bare keys so the user
            // keeps pressing until they add one.
            guard mods != 0 else { return nil }
            onCapture(HotkeyBinding(keyCode: event.keyCode, modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
