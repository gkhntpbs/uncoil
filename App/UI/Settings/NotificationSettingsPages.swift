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
                Text("Varsayılan (\(inheritedLabel))").tag(NotificationPrefs.Priority?.none)
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
                Text("Varsayılan (\(inheritedLabel))").tag(String?.none)
                Divider()
            }
            Text("Sistem sesi").tag(String?.some("default"))
            Text("Sessiz").tag(String?.some("none"))
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
        SettingsPage(title: "Bildirimler") {
            Section {
                NotificationPermissionRow()
            }

            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: "Bildirimler",
                        detail: "Kapalıyken Uncoil hiçbir banner göndermez."
                    )
                }
                .settingsID("notifications.enabled")
            }

            Section("Varsayılanlar") {
                NotificationPriorityPicker(
                    title: "Öncelik",
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
                    title: "Ses",
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

            Section("Teslimat") {
                Toggle(isOn: bind(\.onlyWhenBackgrounded)) {
                    SettingsLabel(
                        title: "Yalnızca arka plandayken bildir",
                        detail: "Uncoil ön plandayken banner gönderilmez; satırlar yine işaretlenir."
                    )
                }
                Toggle(isOn: bind(\.suppressForVisibleSession)) {
                    SettingsLabel(
                        title: "Açık oturum için bildirme",
                        detail: "Ekranda duran oturum hakkında banner gönderilmez."
                    )
                }
                Toggle(isOn: bind(\.groupByProject)) {
                    SettingsLabel(
                        title: "Projeye göre grupla",
                        detail: "Aynı projenin bildirimleri bildirim merkezinde tek yığın olur."
                    )
                }
            }
            .disabled(!prefs.enabled)

            Section {
                Button("Test Bildirimi Gönder") {
                    Task { await NotificationAuthorization.shared.sendTestNotification() }
                }
                .settingsID("notifications.selfTest")
            } footer: {
                SettingsNote("Her durum değişimi için yalnızca bir bildirim gönderilir; tekrarını Hatırlatmalar sayfası yönetir.")
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
            title: "Olaylar",
            subtitle: "Her olay kendi ayarını taşır. “Varsayılan” seçili olduğu sürece Genel sayfasındaki değer geçerlidir."
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
                            title: "Öncelik",
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
                            title: "Ses",
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
                                    title: "Hatırlat",
                                    detail: prefs.reminders.enabled
                                        ? "\(prefs.reminders.intervalMinutes) dakikada bir tekrarlanır."
                                        : "Hatırlatmalar sayfasından açılana kadar etkisiz."
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
            title: "Hatırlatmalar",
            subtitle: "Bir agent yanıt beklemeye devam ettiği sürece Uncoil bildirimi tekrarlayabilir. İlk banner’ı kaçırdığında ikinci, üçüncü kez haber alırsın."
        ) {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(
                        title: "Hatırlatmalar açık",
                        detail: "Yalnızca kullanıcı işlem yapana kadar süren durumlar tekrarlanır."
                    )
                }
                .settingsID("notifications.reminders.enabled")
            }

            Section {
                Picker(selection: bind(\.intervalMinutes)) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) dakikada bir" : "Saatte bir").tag(minutes)
                    }
                } label: {
                    SettingsLabel(title: "Tekrar aralığı")
                }
                .settingsID("notifications.reminders.interval")

                Picker(selection: bind(\.maxCount)) {
                    Text("Sınırsız").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { count in
                        Text("\(count) kez").tag(count)
                    }
                } label: {
                    SettingsLabel(
                        title: "En fazla",
                        detail: "İlk bildirimden sonra kaç kez hatırlatılacağı."
                    )
                }
                .settingsID("notifications.reminders.maxCount")
            } header: {
                Text("Sıklık")
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
                Text("Hangi olaylar")
            } footer: {
                SettingsNote(
                    "Tur tamamlandı gibi anlık olaylar listede yok: tekrarlanacak bir durum "
                    + "bırakmazlar. Bir oturum beklemekten çıktığında hatırlatması da düşer."
                )
            }
            .disabled(!reminders.enabled)
        }
        .disabled(!settings.notifications.enabled)
    }

    private var summary: String {
        guard reminders.enabled else { return "Hatırlatmalar kapalı." }
        let every = "\(reminders.intervalMinutes) dakikada bir"
        guard reminders.maxCount > 0 else {
            return "Durum sürdüğü sürece \(every) hatırlatılır."
        }
        let total = reminders.maxCount * reminders.intervalMinutes
        return "\(every), en fazla \(reminders.maxCount) kez — yaklaşık \(total) dakika boyunca."
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
            title: "Sessiz Saatler",
            subtitle: "Belirlediğin aralıkta bildirimler susturulur. Gece boyunca çalışan bir agent seni uyandırmaz."
        ) {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    SettingsLabel(title: "Sessiz saatler açık")
                }
                .settingsID("notifications.quietHours.enabled")
            }

            Section {
                minutePicker("Başlangıç", value: bind(\.startMinute))
                .settingsID("notifications.quietHours.start")

                minutePicker("Bitiş", value: bind(\.endMinute))
                .settingsID("notifications.quietHours.end")

                Toggle(isOn: bind(\.allowHighPriority)) {
                    SettingsLabel(
                        title: "Yüksek öncelikliler geçsin",
                        detail: "İzin ve giriş gibi işi durduran olaylar sessiz saatlerde de bildirilir."
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
        guard quiet.enabled else { return "Sessiz saatler kapalı." }
        let start = QuietHours.label(forMinute: quiet.startMinute)
        let end = QuietHours.label(forMinute: quiet.endMinute)
        let exception = quiet.allowHighPriority
            ? " Yüksek öncelikli olaylar bu aralıkta da bildirilir."
            : " Bu aralıkta hiçbir bildirim gönderilmez."
        return "\(start) – \(end) arası sessiz.\(exception)"
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
            title: "Proje Bazında",
            subtitle: "Bir projeyi tamamen susturabilir ya da yalnızca onun için öncelik ve ses değiştirebilirsin."
        ) {
            if projectStore.projects.isEmpty {
                Section {
                    Text("Henüz proje yok.")
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
            SettingsLabel(title: "Bildirimler açık")
        }
        .settingsID("notifications.project.\(project.id.uuidString)")

        NotificationPriorityPicker(
            title: "Öncelik",
            value: Binding(
                get: { override.priority },
                set: { newValue in mutate { $0.priority = newValue } }
            ),
            inheritedLabel: settings.notifications.priority.label
        )

        NotificationSoundPicker(
            title: "Ses",
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
