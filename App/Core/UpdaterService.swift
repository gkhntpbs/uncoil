import Foundation
import Sparkle

/// Sparkle, wrapped in the smallest surface the app actually needs.
///
/// Sparkle's own controller is an `NSObject` with AppKit-era ergonomics; the
/// rest of Uncoil is SwiftUI and observes state. So this exposes three things —
/// whether a check can run, whether checks happen on their own, and when the
/// last one was — and forwards everything else to Sparkle unchanged.
///
/// The updater is deliberately *not* started under UI tests. Sparkle schedules a
/// check shortly after launch and would put a modal update dialog over a test
/// that is trying to click something else, which is both a flake and a way to
/// hit the network from a suite that must stay deterministic.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController?

    /// False while an update check is already running, so the button can say so.
    @Published private(set) var canCheckForUpdates = false

    /// When Sparkle last successfully asked the feed. `nil` until it ever has.
    @Published private(set) var lastCheckDate: Date?

    /// Mirrors Sparkle's own preference rather than storing a second copy of it;
    /// two sources of truth for "do you check automatically" is how an app ends
    /// up disagreeing with itself after an update.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    /// Nothing to offer when the updater never started (UI tests).
    var isAvailable: Bool { controller != nil }

    private var observation: NSKeyValueObservation?

    private init() {
        guard !LaunchConfig.shared.isUITesting else {
            controller = nil
            return
        }
        // `startingUpdater: true` schedules the background check; the feed URL
        // and public key come from Info.plist, so there is nothing to configure
        // here that could drift from what was shipped.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        lastCheckDate = controller.updater.lastUpdateCheckDate
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.lastCheckDate = updater.lastUpdateCheckDate
            }
        }
    }

    /// The user asked, so show the result either way — including "you are up to
    /// date", which a background check would have kept to itself.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
