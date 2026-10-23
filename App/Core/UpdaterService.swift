import Foundation
import Sparkle

@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared: UpdaterService = {
        let config = LaunchConfig.shared
        let defaults: UserDefaults
        if config.isUITesting {
            let suite = "com.gokhantopbas.uncoil.update-ui-tests"
            defaults = UserDefaults(suiteName: suite)!
            if config.resetState { defaults.removePersistentDomain(forName: suite) }
        } else {
            defaults = .standard
        }
        return UpdaterService(defaults: defaults, startUpdater: !config.isUITesting)
    }()

    private var controller: SPUStandardUpdaterController?
    private let preference: UpdateChannelPreference
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var channel: UpdateChannel

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var isAvailable: Bool { controller != nil }

    init(defaults: UserDefaults, startUpdater: Bool) {
        preference = UpdateChannelPreference(defaults: defaults)
        channel = preference.channel
        super.init()
        guard startUpdater else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            }
        ]
        refreshState()
    }

    func selectChannel(_ channel: UpdateChannel) {
        guard preference.select(channel, sessionInProgress: controller?.updater.sessionInProgress ?? false) else { return }
        self.channel = preference.channel
        lastCheckDate = nil
        controller?.updater.resetUpdateCycleAfterShortDelay()
        controller?.updater.checkForUpdates()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel.feedURL.absoluteString
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    private func refreshState() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        sessionInProgress = updater.sessionInProgress
        lastCheckDate = updater.lastUpdateCheckDate
    }
}
