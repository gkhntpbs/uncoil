import SwiftUI

/// Settings → Menü Çubuğu.
///
/// The monitor used to be a single hidden switch inside the notifications pane.
/// It is the part of Uncoil a user sees most often while the app's window is
/// closed, so it gets its own page — icon, counters, and what the drop-down
/// carries — with a live preview, because "3 2!" means nothing written down.
struct MenuBarSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var attention = AttentionStore.shared

    private var prefs: MenuBarPrefs { settings.menuBar }

    /// What the menu bar shows right now, so the preview is the real thing.
    private var liveSummary: MenuBarSummary {
        MenuBarMonitorEngine.summary(
            statuses: sessionStore.statuses,
            attention: attention.items
        )
    }

    /// A busy state, so the preview still says something when nothing is running.
    private var sampleSummary: MenuBarSummary {
        var summary = MenuBarSummary()
        summary.running = 3
        summary.waitingPermission = 2
        summary.problems = 1
        summary.tasks.setQueued(4)
        return summary
    }

    var body: some View {
        SettingsPage(title: "Menü Çubuğu") {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: "Menü çubuğu monitörü",
                        detail: "Uncoil’in penceresi kapalıyken agent’ları izlemeyi sürdürür."
                    )
                }
                .settingsID("menuBar.enabled")
            }

            Section {
                LabeledContent("Şu an") {
                    MenuBarMonitorLabel(summary: liveSummary, prefs: prefs)
                }
                LabeledContent("Yoğunken") {
                    MenuBarMonitorLabel(summary: sampleSummary, prefs: prefs)
                }
            } header: {
                Text("Önizleme")
            } footer: {
                SettingsNote(liveSummary.headline)
            }
            .disabled(!prefs.enabled)

            Section("Simge") {
                Picker(selection: bind(\.iconStyle)) {
                    ForEach(MenuBarPrefs.IconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                } label: {
                    SettingsLabel(
                        title: "Simge biçimi",
                        detail: prefs.iconStyle.detail
                    )
                }
                .settingsID("menuBar.iconStyle")

                if prefs.iconStyle == .logo {
                    Toggle(isOn: bind(\.monochrome)) {
                        SettingsLabel(
                            title: "Tek renk",
                            detail: "Durum rengini kapatır; simge menü çubuğunun kendi rengini alır."
                        )
                    }
                    .settingsID("menuBar.monochrome")
                }

                Toggle(isOn: bind(\.hideWhenIdle)) {
                    SettingsLabel(
                        title: "Boştayken gizle",
                        detail: "Çalışan ya da bekleyen bir şey yokken simge menü çubuğundan çıkar."
                    )
                }
                .settingsID("menuBar.hideWhenIdle")
            }
            .disabled(!prefs.enabled)

            Section {
                ForEach(MenuBarPrefs.Counter.allCases) { counter in
                    Toggle(isOn: Binding(
                        get: { prefs.shows(counter) },
                        set: { newValue in
                            settings.menuBar.set(counter, enabled: newValue)
                            settings.save()
                        }
                    )) {
                        SettingsLabel(
                            title: counter.title,
                            detail: counter.marker.isEmpty
                                ? "Simgenin yanında sayı olarak görünür."
                                : "Simgenin yanında “\(counter.marker)” işaretiyle görünür."
                        )
                    }
                    .settingsID("menuBar.counter.\(counter.rawValue)")
                }
            } header: {
                Text("Sayaçlar")
            } footer: {
                SettingsNote(
                    prefs.label(for: sampleSummary).isEmpty
                        ? "Hiçbiri seçili değil — menü çubuğunda yalnızca simge görünür."
                        : "Yoğunken şöyle görünür: \(prefs.label(for: sampleSummary))"
                )
            }
            .disabled(!prefs.enabled)

            Section("Menü içeriği") {
                Toggle(isOn: bind(\.showTasksSection)) {
                    SettingsLabel(title: "Görev kısayolları", detail: "Board, görev oturumu, orchestrator.")
                }
                Toggle(isOn: bind(\.showSessionsSection)) {
                    SettingsLabel(title: "Dikkat isteyen oturumlar")
                }
                Toggle(isOn: bind(\.showQuickLaunch)) {
                    SettingsLabel(title: "Yeni oturum menüsü")
                }
            }
            .disabled(!prefs.enabled)
        }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<MenuBarPrefs, Value>) -> Binding<Value> {
        Binding(
            get: { settings.menuBar[keyPath: keyPath] },
            set: {
                settings.menuBar[keyPath: keyPath] = $0
                settings.save()
            }
        )
    }
}
