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
            // Whether macOS will let Uncoil notify, and whether Uncoil should:
            // one card, because the second answer means nothing without the
            // first. The permission row carries the test notification — the
            // only thing that proves delivery — so there is not a second copy
            // of that button at the foot of the page.
            Section {
                NotificationPermissionRow()

                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: String(localized: "Send notifications"),
                        detail: String(localized: "While this is off, Uncoil sends no banner at all; sessions are still marked in the sidebar.")
                    )
                }
                .settingsID("notifications.enabled")
            }

            // Everything below is about banners, so it is all off together
            // rather than each section disabling itself.
            Group {
                defaults
                delivery
                events
                remindersSection
                quietHoursSection
            }
            .disabled(!prefs.enabled)
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
    }

    private var delivery: some View {
        Section {
            Toggle(isOn: bind(\.onlyWhenBackgrounded)) {
                SettingsLabel(
                    title: String(localized: "Only while Uncoil is in the background"),
                    detail: String(localized: "No banner while the app is in front of you; the rows are still marked.")
                )
            }
            .settingsID("notifications.onlyWhenBackgrounded")

            Toggle(isOn: bind(\.suppressForVisibleSession)) {
                SettingsLabel(
                    title: String(localized: "Not about the session on screen"),
                    detail: String(localized: "You are already looking at it.")
                )
            }
            .settingsID("notifications.suppressForVisibleSession")

            Toggle(isOn: bind(\.groupByProject)) {
                SettingsLabel(
                    title: String(localized: "Group by project"),
                    detail: String(localized: "A project's notifications stack into one group in Notification Center.")
                )
            }
            .settingsID("notifications.groupByProject")
        } header: {
            Text("Delivery")
        }
    }

    // MARK: Events

    /// One row per thing Uncoil can announce. A switch is what people come for;
    /// the priority, sound and repeat behind it are what they come for once, so
    /// the row opens rather than showing all four at all times — seven events
    /// expanded was most of the page.
    private var events: some View {
        Section {
            ForEach(NotificationEvent.allCases) { event in
                EventRow(event: event)
            }
        } header: {
            Text("Events")
        } footer: {
            SettingsNote(String(localized: "Open an event to give it its own priority, sound and repeat. While “Default” is chosen it follows the values above."))
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            Toggle(isOn: reminderBind(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Repeat while it keeps waiting"),
                    detail: String(localized: "An agent blocked for twenty minutes looks exactly like one blocked five seconds ago.")
                )
            }
            .settingsID("notifications.reminders.enabled")

            if reminders.enabled {
                Picker(selection: reminderBind(\.intervalMinutes)) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes < 60 ? "Every \(minutes) minutes" : "Hourly").tag(minutes)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "How often"))
                }
                .settingsID("notifications.reminders.interval")

                Picker(selection: reminderBind(\.maxCount)) {
                    Text("Until I act").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { count in
                        Text("\(count) times").tag(count)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "How many times"))
                }
                .settingsID("notifications.reminders.maxCount")
            }
        } header: {
            Text("Repeats")
        } footer: {
            // Which events repeat is set on the event itself, above: a second
            // list of the same switches would be one setting with two homes.
            SettingsNote(reminderSummary)
        }
    }

    private var reminderSummary: String {
        guard prefs.enabled else { return String(localized: "Notifications are off.") }
        guard reminders.enabled else {
            return String(localized: "One notification per state change, never repeated. Only states that last until you act on them can repeat — a finished turn has no state behind it.")
        }
        let every = String(localized: "every \(reminders.intervalMinutes) minutes")
        guard reminders.maxCount > 0 else {
            return String(localized: "Repeated \(every) for as long as the state lasts.")
        }
        let total = reminders.maxCount * reminders.intervalMinutes
        return String(localized: "Repeated \(every), up to \(reminders.maxCount) times — about \(total) minutes in all.")
    }

    // MARK: Quiet hours

    /// Kept, rather than handed to macOS Focus as the plan had it: Focus
    /// silences everything, and the reason to have a window here is the
    /// exception — letting through what stopped the work while suppressing what
    /// merely reports it.
    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: quietBind(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Silence notifications overnight"),
                    detail: String(localized: "An agent working through the night will not wake you.")
                )
            }
            .settingsID("notifications.quietHours.enabled")

            if quiet.enabled {
                minutePicker(String(localized: "From"), value: quietBind(\.startMinute))
                    .settingsID("notifications.quietHours.start")

                minutePicker(String(localized: "Until"), value: quietBind(\.endMinute))
                    .settingsID("notifications.quietHours.end")

                Toggle(isOn: quietBind(\.allowHighPriority)) {
                    SettingsLabel(
                        title: String(localized: "Except what stops the work"),
                        detail: String(localized: "A permission request or a dropped login is announced even during these hours.")
                    )
                }
                .settingsID("notifications.quietHours.allowHighPriority")
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            SettingsNote(quietSummary)
        }
    }

    private func minutePicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(selection: value) {
            // Half-hour resolution: enough for a sleep window, short enough to
            // stay a single menu instead of a date picker.
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minute in
                Text(QuietHours.label(forMinute: minute)).tag(minute)
            }
        } label: {
            SettingsLabel(title: title)
        }
    }

    private var quietSummary: String {
        guard quiet.enabled else { return String(localized: "Notifications arrive at any hour.") }
        let start = QuietHours.label(forMinute: quiet.startMinute)
        let end = QuietHours.label(forMinute: quiet.endMinute)
        return quiet.allowHighPriority
            ? String(localized: "Quiet between \(start) and \(end), apart from what stops the work.")
            : String(localized: "Nothing at all between \(start) and \(end).")
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

/// One event: a switch, and behind the disclosure the three settings that only
/// matter once you want this event to behave differently from the rest.
private struct EventRow: View {
    let event: NotificationEvent

    @EnvironmentObject private var settings: SettingsStore
    @State private var isExpanded = false

    private var prefs: NotificationPrefs { settings.notifications }
    private var isOn: Bool { prefs.isEnabled(event) }

    /// Where the title starts: chevron, gap, icon, gap. The details line up
    /// under it rather than under the chevron, so an open row reads as one
    /// block instead of a second list starting at the card's edge.
    private static let titleInset: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                details
                    .padding(.leading, Self.titleInset)
                    .padding(.top, 10)
            }
        }
        .padding(.vertical, 2)
    }

    /// `DisclosureGroup` put its triangle hard against the card's edge and
    /// aligned it to the first baseline, which left it floating between the
    /// title and the detail line of every two-line row. This is the same
    /// disclosure, centred on the row and inset like everything else.
    private var header: some View {
        AdaptiveRow {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)

                Image(systemName: event.symbolName)
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The whole row opens it, not the triangle alone. The switch is a
            // control, so it is hit-tested first and keeps its own click.
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
            }
        } control: {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    settings.notifications.update(event) { $0.enabled = newValue }
                    settings.save()
                }
            ))
            .labelsHidden()
            .settingsID("notifications.event.\(event.rawValue)")
        }
    }

    /// An event that is off keeps its row and its details reachable, but
    /// nothing behind it can be set: those values would describe a banner that
    /// is never sent. The switch itself stays live, up in the header, which is
    /// how the row comes back.
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            // Only for states that last until you act on them: a finished turn
            // has no state behind it, so there is nothing a repeat is about.
            if event.supportsReminder {
                Toggle(isOn: Binding(
                    get: { prefs.prefs(for: event).remind ?? true },
                    set: { newValue in
                        settings.notifications.update(event) { $0.remind = newValue }
                        settings.save()
                    }
                )) {
                    SettingsLabel(
                        title: String(localized: "Repeat this one"),
                        detail: prefs.reminders.enabled
                            ? String(localized: "Follows the interval set under Repeats.")
                            : String(localized: "Nothing repeats until Repeats is switched on.")
                    )
                }
                .settingsID("notifications.event.remind.\(event.rawValue)")
            }
        }
        .disabled(!isOn)
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
