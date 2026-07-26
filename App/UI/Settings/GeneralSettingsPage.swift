import AppKit
import SwiftUI

/// Settings → Genel: the handful of choices that shape every session, plus the
/// two app-level behaviours (what happens on quit, how the palette opens).
struct GeneralSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(title: String(localized: "General")) {
            Section("Defaults") {
                Picker(selection: Binding(
                    get: { settings.defaultProvider },
                    set: { settings.defaultProvider = $0; settings.save() }
                )) {
                    ForEach([AgentProvider.claude, .codex]) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Default agent"),
                        detail: String(localized: "New sessions open with this provider.")
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
                             : "\(editor.displayName) (not installed)")
                            .tag(editor)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Editor"),
                        detail: String(localized: "“Open in editor” launches this app.")
                    )
                }
                .settingsID("general.editor")
            }

            Section("Language") {
                Picker(selection: Binding(
                    get: { settings.language.interface },
                    set: { settings.language.interface = $0 }
                )) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Interface language"),
                        detail: String(localized: "Applies after Uncoil restarts.")
                    )
                }
                .settingsID("general.interfaceLanguage")

                Picker(selection: Binding(
                    get: { settings.language.agent },
                    set: { settings.language.agent = $0 }
                )) {
                    ForEach(AgentLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Agent language"),
                        detail: String(
                            localized: "The language Uncoil writes in when it hands a task, a repair or a grouping job to an agent. Takes effect on the next prompt."
                        )
                    )
                }
                .settingsID("general.agentLanguage")

                if settings.language.needsRelaunch() {
                    AdaptiveRow {
                        SettingsNote(String(
                            localized: "The interface language changes when Uncoil starts again."
                        ))
                    } control: {
                        Button(String(localized: "Restart Uncoil")) { AppRelaunch.now() }
                            .settingsID("general.language.relaunch")
                    }
                }
            }

            Section("Quitting the app") {
                Picker(selection: Binding(
                    get: { settings.sessionQuitBehavior },
                    set: { settings.setSessionQuitBehavior($0) }
                )) {
                    ForEach(SessionQuitBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Sessions on quit"))
                }
                .pickerStyle(.inline)
                .settingsID("agentBehavior.quit")

                SettingsNote(settings.sessionQuitBehavior.detail)
            }

            Section("Command palette") {
                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Shortcut"),
                        detail: String(localized: "At least one modifier key (⌘⌥⌃⇧) is required. Applies immediately."),
                        symbol: "command"
                    )
                } control: {
                    HStack(spacing: 8) {
                        HotkeyRecorder(
                            binding: settings.commandPaletteHotkey,
                            onCapture: { settings.setCommandPaletteHotkey($0) }
                        )
                        Button("Reset") { settings.resetCommandPaletteHotkey() }
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
            Text(recording ? "Press a key…" : binding.displayString)
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
