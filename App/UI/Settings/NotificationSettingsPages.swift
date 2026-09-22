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

// MARK: - The page

/// Settings › Notifications — all of it.
///
/// This was four pages: General, Events, Reminders, Quiet Hours. Notifications
/// are one decision — *when should Uncoil interrupt me* — and splitting that
/// decision across four pages meant no page could answer it. It also duplicated
/// settings: an event's "Remind" switch existed both under the event and again
/// as a list on the Reminders page, so the same value had two homes and the
/// second one was the stale-looking copy.
///
/// The events are disclosures rather than seven expanded blocks: a switch per
/// event is what people come for, and the priority and sound behind it are what
/// they come for once.
struct NotificationsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private var prefs: NotificationPrefs { settings.notifications }
    private var reminders: ReminderPrefs { prefs.reminders }
    private var quiet: QuietHours { prefs.quietHours }

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

            defaults
            delivery
            events
            remindersSection
            quietHoursSection

            Section {
                Button("Send a Test Notification") {
                    Task { await NotificationAuthorization.shared.sendTestNotification() }
                }
                .settingsID("notifications.selfTest")
            }
        }
    }

    // MARK: Defaults and delivery

    private var defaults: some View {
        Section {
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
        } header: {
            Text("Defaults")
        } footer: {
            SettingsNote(prefs.priority.detail)
        }
        .disabled(!prefs.enabled)
    }

    private var delivery: some View {
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
    }

    // MARK: Events

    private var events: some View {
        Section {
            ForEach(NotificationEvent.allCases) { event in
                DisclosureGroup {
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

                    // Only for states that last until you act on them. There is
                    // no state behind a finished turn, so there is nothing a
                    // repeat could be about.
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
                                detail: reminders.enabled
                                    ? String(localized: "Repeated every \(reminders.intervalMinutes) minutes.")
                                    : String(localized: "Inactive until reminders are turned on below.")
                            )
                        }
                        .settingsID("notifications.event.remind.\(event.rawValue)")
                    }
                } label: {
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
                }
            }
        } header: {
            Text("Events")
        } footer: {
            SettingsNote(String(localized: "Open an event to give it its own priority, sound and repeat. While “Default” is selected it follows the values above."))
        }
        .disabled(!prefs.enabled)
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            Toggle(isOn: reminderBind(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Repeat while it keeps waiting"),
                    detail: String(localized: "An agent blocked for twenty minutes looks exactly like one blocked five seconds ago. Only states that last until you act on them are repeated.")
                )
            }
            .settingsID("notifications.reminders.enabled")

            Picker(selection: reminderBind(\.intervalMinutes)) {
                ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { minutes in
                    Text(minutes < 60 ? "Every \(minutes) minutes" : "Hourly").tag(minutes)
                }
            } label: {
                SettingsLabel(title: String(localized: "Repeat interval"))
            }
            .settingsID("notifications.reminders.interval")
            .disabled(!reminders.enabled)

            Picker(selection: reminderBind(\.maxCount)) {
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
            .disabled(!reminders.enabled)
        } header: {
            Text("Reminders")
        } footer: {
            // Which events repeat is set on the event itself, above: a second
            // list of the same switches is the same setting with two homes.
            SettingsNote(reminderSummary)
        }
        .disabled(!prefs.enabled)
    }

    private var reminderSummary: String {
        guard reminders.enabled else { return String(localized: "Reminders are off.") }
        let every = String(localized: "Every \(reminders.intervalMinutes) minutes")
        guard reminders.maxCount > 0 else {
            return String(localized: "Repeated every \(every) while the state lasts.")
        }
        let total = reminders.maxCount * reminders.intervalMinutes
        return String(localized: "\(every), up to \(reminders.maxCount) times — for about \(total) minutes.")
    }

    // MARK: Quiet hours

    /// Kept, rather than handed to macOS Focus as planned: Focus silences
    /// everything, and the reason to have a window here is the exception —
    /// letting through the events that stopped the work while suppressing the
    /// ones that merely report it. Three rows behind one switch.
    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: quietBind(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Quiet hours"),
                    detail: String(localized: "An agent working through the night will not wake you.")
                )
            }
            .settingsID("notifications.quietHours.enabled")

            if quiet.enabled {
                minutePicker(String(localized: "Start"), value: quietBind(\.startMinute))
                    .settingsID("notifications.quietHours.start")
                minutePicker(String(localized: "End"), value: quietBind(\.endMinute))
                    .settingsID("notifications.quietHours.end")
                Toggle(isOn: quietBind(\.allowHighPriority)) {
                    SettingsLabel(
                        title: String(localized: "Let high-priority events through"),
                        detail: String(localized: "Events that stop the work, such as permission and login, are announced during quiet hours too.")
                    )
                }
            }
        } footer: {
            SettingsNote(quietSummary)
        }
        .disabled(!prefs.enabled)
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

    private var quietSummary: String {
        guard quiet.enabled else { return String(localized: "Quiet hours off.") }
        let start = QuietHours.label(forMinute: quiet.startMinute)
        let end = QuietHours.label(forMinute: quiet.endMinute)
        let exception = quiet.allowHighPriority
            ? String(localized: " High-priority events are still announced during this window.")
            : String(localized: " No notification is delivered during this window.")
        return String(localized: "Quiet between \(start) and \(end).\(exception)")
    }

    // MARK: Bindings

    private func bind(_ keyPath: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.notifications[keyPath: keyPath] },
            set: { newValue in
                settings.notifications[keyPath: keyPath] = newValue
                settings.save()
            }
        )
    }

    private func reminderBind<Value>(
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

    private func quietBind<Value>(
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

struct ProjectNotificationRows: View {
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
