import SwiftUI

/// Settings → Görünüm. The one page that edits the app's own palette, so it is
/// also the one page whose controls are bound live to `ThemeStore`.
struct AppearanceSettingsPage: View {
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        SettingsPage(title: "Tema ve Renkler") {
            Section("Hazır temalar") {
                Picker(selection: Binding(
                    get: { theme.palette.isLight },
                    set: { theme.apply(preset: $0 ? .light : .dark) }
                )) {
                    Text("Koyu").tag(false)
                    Text("Açık").tag(true)
                } label: {
                    SettingsLabel(title: "Görünüm")
                }
                .pickerStyle(.segmented)
                .settingsID("theme.preset")
            }

            Section("Arayüz") {
                colorRow("Arka plan", \.bg)
                colorRow("Panel", \.panel)
                colorRow("Kenarlık", \.border)
                colorRow("Metin", \.text)
                colorRow("Soluk metin", \.textDim)
            }

            Section("Sağlayıcılar") {
                colorRow("Claude rengi", \.claude)
                colorRow("Codex rengi", \.codex)
            }

            Section {
                colorRow("Terminal arka planı", \.terminalBg)
                colorRow("Terminal metni", \.terminalFg)
            } header: {
                Text("Terminal")
            } footer: {
                SettingsNote("Terminal renkleri yeni açılan oturumlarda geçerli olur.")
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
