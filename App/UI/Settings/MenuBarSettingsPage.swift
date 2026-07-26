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
        SettingsPage(title: "Menu Bar") {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: "Menu-bar monitor",
                        detail: "Keeps watching the agents while Uncoil's window is closed."
                    )
                }
                .settingsID("menuBar.enabled")
            }

            Section {
                LabeledContent("Now") {
                    MenuBarMonitorLabel(summary: liveSummary, prefs: prefs)
                }
                LabeledContent("When busy") {
                    MenuBarMonitorLabel(summary: sampleSummary, prefs: prefs)
                }
            } header: {
                Text("Preview")
            } footer: {
                SettingsNote(liveSummary.headline)
            }
            .disabled(!prefs.enabled)

            Section("Icon") {
                Picker(selection: bind(\.iconStyle)) {
                    ForEach(MenuBarPrefs.IconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                } label: {
                    SettingsLabel(
                        title: "Icon style",
                        detail: prefs.iconStyle.detail
                    )
                }
                .settingsID("menuBar.iconStyle")

                if prefs.iconStyle == .logo {
                    Toggle(isOn: bind(\.monochrome)) {
                        SettingsLabel(
                            title: "Single colour",
                            detail: "Turns off the status colour; the icon takes the menu bar's own."
                        )
                    }
                    .settingsID("menuBar.monochrome")
                }

                Toggle(isOn: bind(\.hideWhenIdle)) {
                    SettingsLabel(
                        title: "Hide while idle",
                        detail: "The icon leaves the menu bar when nothing is running or waiting."
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
                                ? "Shown as a number next to the icon."
                                : "Shown next to the icon, marked “\(counter.marker)”."
                        )
                    }
                    .settingsID("menuBar.counter.\(counter.rawValue)")
                }
            } header: {
                Text("Counters")
            } footer: {
                SettingsNote(
                    prefs.label(for: sampleSummary).isEmpty
                        ? "None selected — only the icon shows in the menu bar."
                        : "Busy, it looks like this: \(prefs.label(for: sampleSummary))"
                )
            }
            .disabled(!prefs.enabled)

            Section("Menu contents") {
                Toggle(isOn: bind(\.showTasksSection)) {
                    SettingsLabel(title: "Task shortcuts", detail: "Board, task session, orchestrator.")
                }
                Toggle(isOn: bind(\.showSessionsSection)) {
                    SettingsLabel(title: "Dikkat isteyen oturumlar")
                }
                Toggle(isOn: bind(\.showQuickLaunch)) {
                    SettingsLabel(title: "New-session menu")
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
