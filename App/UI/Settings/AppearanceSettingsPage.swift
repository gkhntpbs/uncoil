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

                if settings.attentionEmphasis.animates {
                    LabeledContent {
                        Slider(value: styleBinding(\.speed), in: AttentionStyle.speedRange, step: 0.1)
                            .frame(width: 180)
                    } label: {
                        SettingsLabel(
                            title: String(localized: "Pulse speed"),
                            detail: String(localized: "\(settings.attentionStyle.speed.formatted(.number.precision(.fractionLength(1))))× the level's own rate.")
                        )
                    }
                    .settingsID("appearance.attentionSpeed")
                }

                LabeledContent {
                    Slider(value: styleBinding(\.intensity), in: AttentionStyle.intensityRange, step: 0.1)
                        .frame(width: 180)
                } label: {
                    SettingsLabel(
                        title: String(localized: "Highlight strength"),
                        detail: String(localized: "How strongly the row's border and wash are drawn.")
                    )
                }
                .disabled(!settings.attentionStyle.highlightRows)
                .settingsID("appearance.attentionIntensity")
            }

            Section {
                Toggle(isOn: styleBinding(\.highlightRows)) {
                    SettingsLabel(
                        title: String(localized: "Highlight sessions in the sidebar"),
                        detail: String(localized: "Off: rows never get a border or wash. The status dot still shows the state.")
                    )
                }
                .settingsID("appearance.attentionRows")
                Toggle(String(localized: "Permission requests"), isOn: styleBinding(\.markPermission))
                    .disabled(!settings.attentionStyle.highlightRows)
                    .padding(.leading, 16)
                Toggle(String(localized: "Waiting for your next message"), isOn: styleBinding(\.markInput))
                    .disabled(!settings.attentionStyle.highlightRows)
                    .padding(.leading, 16)
                Toggle(String(localized: "Unread notifications"), isOn: styleBinding(\.markUnseen))
                    .disabled(!settings.attentionStyle.highlightRows)
                    .padding(.leading, 16)
                Toggle(isOn: styleBinding(\.inputLooksReady)) {
                    SettingsLabel(
                        title: String(localized: "Show a finished turn as ready, not waiting"),
                        detail: String(localized: "An agent that finished and waits for your next message gets the calm \"finished\" dot instead of the waiting one.")
                    )
                }
                .settingsID("appearance.inputLooksReady")
                Toggle(String(localized: "Animate the working dot"), isOn: styleBinding(\.animateWorkingOrb))
                    .disabled(!settings.attentionEmphasis.animates)
                Toggle(String(localized: "Pulse the waiting dot"), isOn: styleBinding(\.pulseWaitingOrb))
                    .disabled(!settings.attentionEmphasis.animates)
                if settings.attentionStyle != .default {
                    Button(String(localized: "Restore Defaults")) {
                        settings.setAttentionStyle(.default)
                    }
                    .settingsID("appearance.attentionReset")
                }
            } header: {
                Text("What Is Marked")
            } footer: {
                SettingsNote(String(localized: "Notifications are set separately, under Notifications."))
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

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<AttentionStyle, Value>) -> Binding<Value> {
        Binding(
            get: { settings.attentionStyle[keyPath: keyPath] },
            set: { value in
                var style = settings.attentionStyle
                style[keyPath: keyPath] = value
                settings.setAttentionStyle(style)
            }
        )
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
