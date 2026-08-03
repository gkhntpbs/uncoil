import Foundation
import SwiftUI

/// How loudly the sidebar is allowed to move when a session wants something.
///
/// The row used to breathe at one fixed, fairly strong amplitude, and with a
/// handful of agents working at once the whole sidebar flickered. Motion is the
/// tunable part here, not the signal: every level still marks an attention row
/// in the status's own colour, so turning the animation off costs nothing but
/// the movement.
enum AttentionEmphasis: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Colour only. Nothing animates, anywhere in the list.
    case off
    /// A slow, shallow breath. The default.
    case subtle
    /// The original amplitude and speed.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Colour only")
        case .subtle: String(localized: "Subtle")
        case .full: String(localized: "Full")
        }
    }

    var detail: String {
        switch self {
        case .off:
            String(localized: "A session that needs you is marked in its colour and never moves.")
        case .subtle:
            String(localized: "A slow, shallow pulse. Visible when you look, quiet when you do not.")
        case .full:
            String(localized: "A faster, stronger pulse that is hard to miss and hard to ignore.")
        }
    }

    /// False for `.off`: the row, and the status orb, hold still.
    var animates: Bool { self != .off }

    /// Seconds for one breath in and out.
    var period: Double {
        switch self {
        case .off: 0
        case .subtle: 1.8
        case .full: 0.9
        }
    }

    /// Peak opacity of the row's colour wash. Zero leaves the row's own
    /// background alone and lets the border carry the signal.
    var fillOpacity: Double {
        switch self {
        case .off: 0
        case .subtle: 0.10
        case .full: 0.24
        }
    }

    /// Border opacity at the bottom and the top of the breath. `.off` sits at
    /// one value, which is why both ends are the same.
    var borderRange: (low: Double, high: Double) {
        switch self {
        case .off: (0.55, 0.55)
        case .subtle: (0.32, 0.58)
        case .full: (0.25, 0.85)
        }
    }
}

/// The current emphasis, readable from views that have no `SettingsStore`.
///
/// `StatusOrb` is drawn in the palette, the header bar, the dashboard and the
/// pop-out window; threading a settings object into all of them to answer one
/// question is worse than mirroring the answer, which is what the app already
/// does for the quit behaviour and the theme. `SettingsStore` owns the value
/// and writes it here.
@MainActor
final class AttentionMotion: ObservableObject {
    static let shared = AttentionMotion()

    @Published var emphasis: AttentionEmphasis = .subtle

    private init() {}

    /// Whether motion should run at all: the user's choice, and the UI-test
    /// switch that freezes every animation for deterministic screenshots.
    var animates: Bool {
        emphasis.animates && !LaunchConfig.shared.disableAnimations
    }
}
