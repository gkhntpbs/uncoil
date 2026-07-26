import AppKit
import SwiftUI

/// Settings → Genel: the handful of choices that shape every session, plus the
/// two app-level behaviours (what happens on quit, how the palette opens).
struct GeneralSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(title: "Genel") {
            Section("Varsayılanlar") {
                Picker(selection: Binding(
                    get: { settings.defaultProvider },
                    set: { settings.defaultProvider = $0; settings.save() }
                )) {
                    ForEach([AgentProvider.claude, .codex]) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                } label: {
                    SettingsLabel(
                        title: "Varsayılan agent",
                        detail: "Yeni oturumlar bu sağlayıcıyla açılır."
                    )
                }
                .settingsID("general.defaultProvider")

                Picker(selection: Binding(
                    get: { settings.preferredEditor },
                    set: { settings.preferredEditor = $0; settings.save() }
                )) {
                    ForEach(PreferredEditor.allCases) { editor in
                        Text(editor.isInstalled
                             ? editor.displayName
                             : "\(editor.displayName) (kurulu değil)")
                            .tag(editor)
                    }
                } label: {
                    SettingsLabel(
                        title: "Editör",
                        detail: "“Editörde aç” bu uygulamayı çalıştırır."
                    )
                }
                .settingsID("general.editor")
            }

            Section("Uygulama kapanışı") {
                Picker(selection: Binding(
                    get: { settings.sessionQuitBehavior },
                    set: { settings.setSessionQuitBehavior($0) }
                )) {
                    ForEach(SessionQuitBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                } label: {
                    SettingsLabel(title: "Çıkarken oturumlar")
                }
                .pickerStyle(.inline)
                .settingsID("agentBehavior.quit")

                SettingsNote(settings.sessionQuitBehavior.detail)
            }

            Section("Komut paleti") {
                AdaptiveRow {
                    SettingsLabel(
                        title: "Kısayol",
                        detail: "En az bir değiştirici tuş (⌘⌥⌃⇧) gerekir. Anında uygulanır.",
                        symbol: "command"
                    )
                } control: {
                    HStack(spacing: 8) {
                        HotkeyRecorder(
                            binding: settings.commandPaletteHotkey,
                            onCapture: { settings.setCommandPaletteHotkey($0) }
                        )
                        Button("Sıfırla") { settings.resetCommandPaletteHotkey() }
                            .settingsID("hotkey.palette.reset")
                    }
                }
            }
        }
    }
}

/// A pill button that shows the current shortcut and, when clicked, records the
/// next key+modifier chord via a temporary local key monitor. Rejects bare keys
/// (needs ≥1 modifier) and cancels on Escape.
struct HotkeyRecorder: View {
    let binding: HotkeyBinding
    let onCapture: (HotkeyBinding) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? "Tuşa basın…" : binding.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 64)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Theme.highlight : nil)
        .settingsID("hotkey.palette.recorder")
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
