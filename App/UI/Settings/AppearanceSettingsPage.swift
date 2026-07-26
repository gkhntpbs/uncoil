import SwiftUI

/// Settings → Görünüm. The one page that edits the app's own palette, so it is
/// also the one page whose controls are bound live to `ThemeStore`.
struct AppearanceSettingsPage: View {
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        SettingsPage(title: "Theme and Colours") {
            Section("Built-in themes") {
                Picker(selection: Binding(
                    get: { theme.palette.isLight },
                    set: { theme.apply(preset: $0 ? .light : .dark) }
                )) {
                    Text("Dark").tag(false)
                    Text("On").tag(true)
                } label: {
                    SettingsLabel(title: "Appearance")
                }
                .pickerStyle(.segmented)
                .settingsID("theme.preset")
            }

            Section("Interface") {
                colorRow("Arka plan", \.bg)
                colorRow("Panel", \.panel)
                colorRow("Border", \.border)
                colorRow("Text", \.text)
                colorRow("Dim text", \.textDim)
            }

            Section("Providers") {
                colorRow("Claude rengi", \.claude)
                colorRow("Codex rengi", \.codex)
            }

            Section {
                colorRow("Terminal background", \.terminalBg)
                colorRow("Terminal metni", \.terminalFg)
            } header: {
                Text("Terminal")
            } footer: {
                SettingsNote("Terminal colours apply to newly opened sessions.")
            }
        }
    }

    private func colorRow(
        _ title: String,
        _ keyPath: WritableKeyPath<ThemePalette, UInt32>
    ) -> some View {
        ColorPicker(selection: theme.binding(keyPath), supportsOpacity: false) {
            Text(title)
        }
    }
}
