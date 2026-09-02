import SwiftUI

/// Settings → Görünüm. The one page that edits the app's own palette, so it is
/// also the one page whose controls are bound live to `ThemeStore`.
struct AppearanceSettingsPage: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(title: String(localized: "Theme and Colours")) {
            Section {
                Picker(selection: Binding(
                    get: { theme.appearance },
                    set: { theme.setAppearance($0) }
                )) {
                    ForEach(ThemeAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Appearance"))
                }
                .pickerStyle(.segmented)
                .settingsID("theme.preset")
            } header: {
                Text("Built-in Themes")
            } footer: {
                SettingsNote(
                    theme.appearance == .system
                        ? String(localized: "Uncoil follows this Mac's appearance, and switches with it. Changing appearance restores that theme's own colours, so any colours you have set below are replaced.")
                        : String(localized: "Changing appearance restores that theme's own colours, so any colours you have set below are replaced.")
                )
            }

            Section("Attention") {
                Picker(selection: Binding(
                    get: { settings.attentionEmphasis },
                    set: { settings.setAttentionEmphasis($0) }
                )) {
                    ForEach(AttentionEmphasis.allCases) { emphasis in
                        Text(emphasis.title).tag(emphasis)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Sidebar pulse"),
                        detail: String(
                            localized: "How a session that is waiting for you moves in the sidebar. Applies immediately."
                        )
                    )
                }
                .pickerStyle(.inline)
                .settingsID("appearance.attentionEmphasis")

                SettingsNote(settings.attentionEmphasis.detail)
            }

            Section("Interface") {
                colorRow(String(localized: "Background"), \.bg)
                colorRow(String(localized: "Panel"), \.panel)
                colorRow(String(localized: "Border"), \.border)
                colorRow(String(localized: "Text"), \.text)
                colorRow(String(localized: "Dim text"), \.textDim)
            }

            Section("Providers") {
                colorRow(String(localized: "Claude colour"), \.claude)
                colorRow(String(localized: "Codex colour"), \.codex)
            }

            Section {
                colorRow(String(localized: "Terminal background"), \.terminalBg)
                colorRow(String(localized: "Terminal text"), \.terminalFg)
            } header: {
                Text("Terminal")
            } footer: {
                SettingsNote(String(localized: "Terminal colours apply to newly opened sessions."))
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
