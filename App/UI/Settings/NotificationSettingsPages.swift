import SwiftUI

// MARK: - Shared pickers

/// Priority menu with an optional "follow the level above" entry, so a per-event
/// or per-project row can say "inherit" instead of pinning a value.
struct NotificationPriorityPicker: View {
    let title: String
    @Binding var value: NotificationPrefs.Priority?
    var inheritedLabel: String?

    var body: some View {
        Picker(title, selection: $value) {
            if let inheritedLabel {
                Text("Default (\(inheritedLabel))").tag(NotificationPrefs.Priority?.none)
                Divider()
            }
            ForEach(NotificationPrefs.Priority.allCases) { priority in
                Text(priority.label).tag(NotificationPrefs.Priority?.some(priority))
            }
        }
    }
}

struct NotificationSoundPicker: View {
    let title: String
    @Binding var value: String?
    var inheritedLabel: String?
    /// Plays the picked sound so the choice is audible, not just a word.
    var previews = true

    var body: some View {
        Picker(title, selection: $value) {
            if let inheritedLabel {
                Text("Default (\(inheritedLabel))").tag(String?.none)
                Divider()
            }
            Text("System sound").tag(String?.some("default"))
            Text("Silent").tag(String?.some("none"))
            Divider()
            ForEach(NotificationPrefs.systemSounds, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
        .onChange(of: value) { _, newValue in
            guard previews, let newValue else { return }
            NotificationPrefs.preview(sound: newValue)
        }
    }
}

// MARK: - General

/// Settings → Bildirimler → Genel: the master switch, the defaults every other
/// page inherits from, and the delivery filters.
struct NotificationGeneralPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private var prefs: NotificationPrefs { settings.notifications }

    var body: some View {
        SettingsPage(title: String(localized: "Notifications")) {
            Section {
                NotificationPermissionRow()
            }

            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: String(localized: "Notifications"),
                        detail: String(localized: "While it is off, Uncoil sends no banner at all.")
                    )
                }
                .settingsID("notifications.enabled")
            }

            Section("Defaults") {
                NotificationPriorityPicker(
                    title: String(localized: "Priority"),
                    value: Binding(
                        get: { Optional(prefs.priority) },
                        set: { newValue in
                            settings.notifications.priority = newValue ?? .normal
                            settings.save()
                        }
                    )
                )
                .settingsID("notifications.priority")

                NotificationSoundPicker(
                    title: String(localized: "Sound"),
                    value: Binding(
                        get: { Optional(prefs.sound) },
                        set: { newValue in
                            settings.notifications.sound = newValue ?? "default"
                            settings.save()
                        }
                    )
                )
                .settingsID("notifications.sound")

                SettingsNote(prefs.priority.detail)
            }
            .disabled(!prefs.enabled)

            Section("Delivery") {
                Toggle(isOn: bind(\.onlyWhenBackgrounded)) {
                    SettingsLabel(
                        title: String(localized: "Notify only while in the background"),
                        detail: String(localized: "No banner is sent while Uncoil is in the foreground; the rows are still marked.")
                    )
                }
                Toggle(isOn: bind(\.suppressForVisibleSession)) {
                    SettingsLabel(
                        title: String(localized: "Stay quiet about the session on screen"),
                        detail: String(localized: "No banner is sent about the session already on screen.")
                    )
                }
                Toggle(isOn: bind(\.groupByProject)) {
                    SettingsLabel(
                        title: String(localized: "Group by project"),
                        detail: String(localized: "A project's notifications stack into one group in Notification Center.")
                    )
                }
            }
            .disabled(!prefs.enabled)

            Section {
                Button("Send a Test Notification") {
                    Task { await NotificationAuthorization.shared.sendTestNotification() }
                }
                .settingsID("notifications.selfTest")
            } footer: {
                SettingsNote(String(localized: "Only one notification is sent per state change; repeats are handled by the Reminders page."))
            }
        }
    }

    private func bind(_ keyPath: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.notifications[keyPath: keyPath] },
            set: { newValue in
                settings.notifications[keyPath: keyPath] = newValue
                settings.save()
            }
        )
    }

}

// MARK: - Events

/// Settings → Bildirimler → Olaylar: one row per thing Uncoil can announce,
/// each with its own switch, priority, sound and reminder opt-in.
struct NotificationEventsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var expanded: NotificationEvent?

    private var prefs: NotificationPrefs { settings.notifications }

    var body: some View {
        SettingsPage(
            title: String(localized: "Events"),
            subtitle: String(localized: "Every event carries its own setting. While “Default” is selected, the value on the General page applies.")
        ) {
            ForEach(NotificationEvent.allCases) { event in
                Section {
                    Toggle(isOn: Binding(
                        get: { prefs.isEnabled(event) },
                        set: { newValue in
                            settings.notifications.update(event) { $0.enabled = newValue }
                            settings.save()
                        }
                    )) {
                        SettingsLabel(
                            title: event.title,
                            detail: event.detail,
                            symbol: event.symbolName
                        )
                    }
                    .settingsID("notifications.event.\(event.rawValue)")

                    if prefs.isEnabled(event) {
                        NotificationPriorityPicker(
                            title: String(localized: "Priority"),
                            value: Binding(
                                get: { prefs.prefs(for: event).priority },
                                set: { newValue in
                                    settings.notifications.update(event) { $0.priority = newValue }
                                    settings.save()
                                }
                            ),
                            inheritedLabel: prefs.priority.label
                        )
                        .settingsID("notifications.event.priority.\(event.rawValue)")

                        NotificationSoundPicker(
                            title: String(localized: "Sound"),
                            value: Binding(
                                get: { prefs.prefs(for: event).sound },
                                set: { newValue in
                                    settings.notifications.update(event) { $0.sound = newValue }
                                    settings.save()
                                }
                            ),
                            inheritedLabel: NotificationPrefs.soundLabel(prefs.sound)
                        )

                        if event.supportsReminder {
                            Toggle(isOn: Binding(
                                get: { prefs.prefs(for: event).remind ?? true },
                                set: { newValue in
                                    settings.notifications.update(event) { $0.remind = newValue }
                                    settings.save()
                                }
                            )) {
                                SettingsLabel(
                                    title: String(localized: "Remind"),
                                    detail: prefs.reminders.enabled
                                        ? String(localized: "Repeated every \(prefs.reminders.intervalMinutes) minutes.")
                                        : String(localized: "Inactive until it is turned on from the Reminders page.")
                                )
                            }
                            .settingsID("notifications.event.remind.\(event.rawValue)")
                        }
                    }
                }
            }
        }
        .disabled(!prefs.enabled)
    }
}

// MARK: - Reminders

/// Settings → Bildirimler → Hatırlatmalar.
///
/// The one thing a single banner cannot do: an agent that has been blocked for
/// twenty minutes looks exactly like one that was blocked five seconds ago.
struct NotificationRemindersPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private var reminders: ReminderPrefs { settings.notifications.reminders }

    private var remindableEvents: [NotificationEvent] {
        NotificationEvent.allCases.filter(\.supportsReminder)
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "Reminders"),
            subtitle: String(localized: "As long as an agent keeps waiting for an answer, Uncoil can repeat the notification. Miss the first banner and you hear about it a second and a third time.")
        ) {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: String(localized: "Reminders on"),
                        detail: String(localized: "Only states that last until you act on them are repeated.")
                    )
                }
                .settingsID("notifications.reminders.enabled")
            }

            Section {
                Picker(selection: bind(\.intervalMinutes)) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes < 60 ? "Every \(minutes) minutes" : "Hourly").tag(minutes)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Repeat interval"))
                }
                .settingsID("notifications.reminders.interval")

                Picker(selection: bind(\.maxCount)) {
                    Text("Unlimited").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { count in
                        Text("\(count) times").tag(count)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "At most"),
                        detail: String(localized: "How many times it is repeated after the first notification.")
                    )
                }
                .settingsID("notifications.reminders.maxCount")
            } header: {
                Text("Frequency")
            } footer: {
                SettingsNote(summary)
            }
            .disabled(!reminders.enabled)

            Section {
                ForEach(remindableEvents) { event in
                    Toggle(isOn: Binding(
                        get: { settings.notifications.prefs(for: event).remind ?? true },
                        set: { newValue in
                            settings.notifications.update(event) { $0.remind = newValue }
                            settings.save()
                        }
                    )) {
                        SettingsLabel(
                            title: event.title,
                            detail: event.detail,
                            symbol: event.symbolName
                        )
                    }
                    .settingsID("notifications.reminders.event.\(event.rawValue)")
                }
            } header: {
                Text("Which events")
            } footer: {
                SettingsNote(
                    String(localized: "Momentary events such as a finished turn are not on the list: there is no state behind. A session that stops waiting drops its reminder too.")
                )
            }
            .disabled(!reminders.enabled)
        }
        .disabled(!settings.notifications.enabled)
    }

    private var summary: String {
        guard reminders.enabled else { return "Reminders are off." }
        let every = "Every \(reminders.intervalMinutes) minutes"
        guard reminders.maxCount > 0 else {
            return "Repeated every \(every) while the state lasts."
        }
        let total = reminders.maxCount * reminders.intervalMinutes
        return "\(every), up to \(reminders.maxCount) times — for about \(total) minutes."
    }

    private func bind<Value>(
        _ keyPath: WritableKeyPath<ReminderPrefs, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.notifications.reminders[keyPath: keyPath] },
            set: {
                settings.notifications.reminders[keyPath: keyPath] = $0
                settings.save()
            }
        )
    }
}

// MARK: - Quiet hours

struct NotificationQuietHoursPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private var quiet: QuietHours { settings.notifications.quietHours }

    var body: some View {
        SettingsPage(
            title: String(localized: "Quiet Hours"),
            subtitle: String(localized: "Notifications are silenced during the window you set. An agent working through the night will not wake you.")
        ) {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(title: String(localized: "Quiet hours on"))
                }
                .settingsID("notifications.quietHours.enabled")
            }

            Section {
                minutePicker("Start", value: bind(\.startMinute))
                .settingsID("notifications.quietHours.start")

                minutePicker("End", value: bind(\.endMinute))
                .settingsID("notifications.quietHours.end")

                Toggle(isOn: bind(\.allowHighPriority)) {
                    SettingsLabel(
                        title: String(localized: "Let high-priority events through"),
                        detail: String(localized: "Events that stop the work, such as permission and login, are announced during quiet hours too.")
                    )
                }
            } footer: {
                SettingsNote(summary)
            }
            .disabled(!quiet.enabled)
        }
        .disabled(!settings.notifications.enabled)
    }

    private func minutePicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            // Half-hour resolution: enough for a sleep window, short enough to
            // stay a single menu instead of a date picker.
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minute in
                Text(QuietHours.label(forMinute: minute)).tag(minute)
            }
        }
    }

    private var summary: String {
        guard quiet.enabled else { return "Quiet hours off." }
        let start = QuietHours.label(forMinute: quiet.startMinute)
        let end = QuietHours.label(forMinute: quiet.endMinute)
        let exception = quiet.allowHighPriority
            ? " High-priority events are still announced during this window."
            : " No notification is delivered during this window."
        return "Quiet between \(start) and \(end).\(exception)"
    }

    private func bind<Value>(
        _ keyPath: WritableKeyPath<QuietHours, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.notifications.quietHours[keyPath: keyPath] },
            set: {
                settings.notifications.quietHours[keyPath: keyPath] = $0
                settings.save()
            }
        )
    }
}

// MARK: - Per project

struct ProjectNotificationsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore

    var body: some View {
        SettingsPage(
            title: String(localized: "Per Project"),
            subtitle: String(localized: "You can silence a project completely, or change only its priority and sound.")
        ) {
            if projectStore.projects.isEmpty {
                Section {
                    Text("No projects yet.")
                        .foregroundStyle(Theme.textDim)
                }
            }

            ForEach(projectStore.projects) { project in
                Section(project.name) {
                    ProjectNotificationRows(project: project)
                }
            }
        }
        .disabled(!settings.notifications.enabled)
    }
}

private struct ProjectNotificationRows: View {
    let project: Project
    @EnvironmentObject private var settings: SettingsStore

    private var override: NotificationPrefs.ProjectOverride {
        settings.notifications.perProject[project.id] ?? .init()
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { override.enabled ?? true },
            set: { newValue in mutate { $0.enabled = newValue } }
        )) {
            SettingsLabel(title: String(localized: "Notifications on"))
        }
        .settingsID("notifications.project.\(project.id.uuidString)")

        NotificationPriorityPicker(
            title: String(localized: "Priority"),
            value: Binding(
                get: { override.priority },
                set: { newValue in mutate { $0.priority = newValue } }
            ),
            inheritedLabel: settings.notifications.priority.label
        )

        NotificationSoundPicker(
            title: String(localized: "Sound"),
            value: Binding(
                get: { override.sound },
                set: { newValue in mutate { $0.sound = newValue } }
            ),
            inheritedLabel: NotificationPrefs.soundLabel(settings.notifications.sound)
        )
    }

    private func mutate(_ change: (inout NotificationPrefs.ProjectOverride) -> Void) {
        var value = override
        change(&value)
        settings.notifications.perProject[project.id] = value
        settings.save()
    }
}
