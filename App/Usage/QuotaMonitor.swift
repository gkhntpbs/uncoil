import AppKit
import UserNotifications

@MainActor
final class QuotaMonitor: ObservableObject {
    static let shared = QuotaMonitor()

    private struct Sample: Codable {
        var date: Date
        var usedPercent: Double
    }

    private struct History: Codable {
        var key: UsageKey
        var windowID: String
        var resetsAt: Date
        var samples: [Sample]
        var notified = false
    }

    @Published private var histories: [History] = []
    private weak var settings: SettingsStore?
    private var monitorTask: Task<Void, Never>?
    private var notifying = false
    private let fileURL: URL

    private init() {
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uncoil/quota-history.json")
        if !LaunchConfig.shared.isUITesting, !AttentionNotifier.isRunningTests,
           let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([History].self, from: data) {
            histories = saved.filter { $0.resetsAt > Date() }
        }
    }

    func start(usage: UsageStore, settings: SettingsStore) {
        guard !LaunchConfig.shared.isUITesting, !AttentionNotifier.isRunningTests, monitorTask == nil else { return }
        self.settings = settings
        monitorTask = Task { [weak self, weak usage, weak settings] in
            while !Task.isCancelled {
                guard let self, let usage, let settings else { return }
                if settings.quotaOptimization.mode != .ignore {
                    for provider in AgentProvider.agents where usage.isSupported(provider) && settings.installedProviders.contains(provider) {
                        let profiles = settings.accounts(for: provider)
                        var contexts = profiles.map {
                            UsageAccountContext(accountID: $0.id, label: $0.displayName,
                                                configDirectory: $0.configDirectory(profilesRoot: settings.profilesRootURL))
                        }
                        if !profiles.contains(where: { $0.directoryName == nil }) { contexts.insert(.providerDefault, at: 0) }
                        for context in contexts {
                            guard settings.quotaOptimization.mode != .ignore, !Task.isCancelled else { break }
                            let key = UsageKey(provider: provider, accountID: context.accountID)
                            await usage.refreshIfDue(key: key, account: context, activity: .idle)
                        }
                    }
                    await self.notifyIfNeeded(usage: usage, settings: settings)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func observe(_ snapshot: UsageSnapshot, for key: UsageKey) {
        let key = canonicalKey(key)
        if snapshots[key].map({ $0.updatedAt <= snapshot.updatedAt }) ?? true {
            snapshots[key] = snapshot
        }
        guard let settings, settings.quotaOptimization.mode != .ignore,
              let window = Self.weeklyWindow(snapshot), let reset = window.resetsAt else { return }
        let now = Date()
        guard Self.isFresh(snapshot, now: now), reset > now else { return }
        histories.removeAll { $0.resetsAt <= now }
        let index: Int
        if let existing = histories.firstIndex(where: { $0.key == key && $0.windowID == window.id && $0.resetsAt == reset }) {
            index = existing
        } else {
            histories.removeAll { $0.key == key }
            histories.append(History(key: key, windowID: window.id, resetsAt: reset, samples: []))
            index = histories.count - 1
        }
        if let last = histories[index].samples.last {
            guard snapshot.updatedAt > last.date else { return }
            if window.usedPercent < last.usedPercent { histories[index].samples.removeAll() }
        }
        histories[index].samples.removeAll { snapshot.updatedAt.timeIntervalSince($0.date) > 24 * 3_600 }
        histories[index].samples.append(Sample(date: snapshot.updatedAt, usedPercent: window.usedPercent))
        histories[index].samples = Array(histories[index].samples.suffix(300))
        save()
    }

    func forecast(for snapshot: UsageSnapshot?, now: Date) -> QuotaForecast? {
        guard let snapshot, Self.isFresh(snapshot, now: now),
              let window = Self.weeklyWindow(snapshot), let reset = window.resetsAt, reset > now else { return nil }
        let key = canonicalKey(UsageKey(provider: snapshot.provider, accountID: snapshot.accountID))
        var burn: Double?
        var projected: Double?
        if let history = histories.first(where: { $0.key == key && $0.windowID == window.id && $0.resetsAt == reset }),
           let first = history.samples.first,
           snapshot.updatedAt.timeIntervalSince(first.date) >= 30 * 60,
           window.usedPercent >= first.usedPercent {
            let hours = snapshot.updatedAt.timeIntervalSince(first.date) / 3_600
            let rate = (window.usedPercent - first.usedPercent) / hours
            burn = rate
            projected = max(0, window.remainingPercent - rate * reset.timeIntervalSince(snapshot.updatedAt) / 3_600)
        }
        return QuotaForecast(key: key, window: window, updatedAt: snapshot.updatedAt,
                             burnRatePerHour: burn, projectedUnusedPercent: projected)
    }

    func routingScore(for entry: UncoilAutoRoster.Entry, records: [SessionRecord], settings: SettingsStore, now: Date = .now) -> Double {
        guard settings.quotaOptimization.mode == .preferUnusedQuota else { return 0 }
        let accountID = entry.sessionID.flatMap { id in records.first { $0.id == id }?.accountID }
            ?? (entry.sessionID == nil ? settings.defaultAccount(for: entry.provider)?.id : nil)
        let key = canonicalKey(UsageKey(provider: entry.provider, accountID: accountID))
        guard let snapshot = snapshots[key],
              !UsageAlert.evaluate(snapshot, threshold: settings.usageWarningThreshold).state.isAlerting,
              !snapshot.allWindows.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }),
              let forecast = forecast(for: snapshot, now: now),
              forecast.isOpportunity(settings.quotaOptimization, now: now), let reset = forecast.window.resetsAt else { return 0 }
        return forecast.unusedPercent / max(1, reset.timeIntervalSince(now) / 3_600)
    }

    @Published private var snapshots: [UsageKey: UsageSnapshot] = [:]

    private func notifyIfNeeded(usage: UsageStore, settings: SettingsStore) async {
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        for (key, entry) in usage.entries {
            if let snapshot = entry.snapshot { observe(snapshot, for: key) }
        }
        for (key, snapshot) in snapshots {
            let now = Date()
            guard let forecast = forecast(for: snapshot, now: now),
                  forecast.isOpportunity(settings.quotaOptimization, now: now),
                  let reset = forecast.window.resetsAt,
                  histories.contains(where: { $0.key == key && $0.resetsAt == reset && !$0.notified }) else { continue }
            let center = UNUserNotificationCenter.current()
            let authorization = await center.notificationSettings().authorizationStatus
            guard authorization == .authorized || authorization == .provisional,
                  forecast.isOpportunity(settings.quotaOptimization, now: Date()) else { continue }
            let decision = NotificationPolicy.decide(
                event: .unusedQuota, projectID: nil, sessionID: nil, prefs: settings.notifications,
                attempt: NotificationAttempt(), context: .init(now: Date(), appIsActive: NSApp.isActive))
            guard case .send(let dispatch) = decision else { continue }
            let content = UNMutableNotificationContent()
            let account = settings.account(id: key.accountID)?.displayName
            content.title = [key.provider.displayName, account, String(localized: "Weekly quota resets soon")]
                .compactMap { $0 }.joined(separator: " · ")
            content.body = forecast.detail(now: now) + " " + String(localized: "You can use it for your remaining work.")
            content.threadIdentifier = "quota-\(key.provider.rawValue)-\(key.accountID?.uuidString ?? "default")"
            content.interruptionLevel = dispatch.priority.interruptionLevel
            switch dispatch.sound {
            case "none": break
            case "default": content.sound = .default
            case let name: content.sound = UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
            }
            do {
                try await center.add(UNNotificationRequest(identifier: "\(content.threadIdentifier)-\(Int(reset.timeIntervalSince1970))",
                                                           content: content, trigger: nil))
                if let index = histories.firstIndex(where: { $0.key == key && $0.resetsAt == reset }) {
                    histories[index].notified = true
                    save()
                }
            } catch {
                NSLog("Uncoil quota notification could not be delivered: %@", error.localizedDescription)
            }
        }
    }

    private static func isFresh(_ snapshot: UsageSnapshot, now: Date) -> Bool {
        !snapshot.stale && snapshot.source != .cache && snapshot.unavailable == nil && !snapshot.limitReached
            && now.timeIntervalSince(snapshot.updatedAt) >= 0 && now.timeIntervalSince(snapshot.updatedAt) <= 90 * 60
    }

    private static func weeklyWindow(_ snapshot: UsageSnapshot) -> UsageWindow? {
        snapshot.allWindows.first {
            $0.modelID == nil && ($0.windowMinutes == 10_080 || $0.id == "claude.seven_day" || $0.id == "claude.cli.week")
        }
    }

    private func canonicalKey(_ key: UsageKey) -> UsageKey {
        guard key.accountID == nil,
              let account = settings?.accounts(for: key.provider).first(where: { $0.directoryName == nil }) else { return key }
        return UsageKey(provider: key.provider, accountID: account.id)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(histories) else { return }
        if AtomicFile.write(data, to: fileURL) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
