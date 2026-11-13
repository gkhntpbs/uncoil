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
    @Published var style: AttentionStyle = .default

    private init() {}

    var period: Double { style.period(for: emphasis) }

    /// Whether motion should run at all: the user's choice, and the UI-test
    /// switch that freezes every animation for deterministic screenshots.
    var animates: Bool {
        emphasis.animates && !LaunchConfig.shared.disableAnimations
    }
}

/// The finer-grained half of the attention settings: *what* is marked, and how
/// strong and fast the motion is once `AttentionEmphasis` allows any.
///
/// Some people want every waiting agent to shout; others run a dozen agents
/// and treat "waiting for your next message" as the ordinary resting state of
/// a finished turn. One three-way switch could not serve both, so each signal
/// can be turned off on its own.
struct AttentionStyle: Codable, Equatable, Sendable {
    /// Mark rows in the sidebar at all (border and wash). Off leaves only the
    /// status orb to tell a waiting session from a quiet one.
    var highlightRows: Bool = true
    /// Mark a session that is asking for a permission.
    var markPermission: Bool = true
    /// Mark a session that finished its turn and is waiting for a message.
    var markInput: Bool = true
    /// Mark a session whose notification nobody has looked at yet.
    var markUnseen: Bool = true
    /// Draw "waiting for input" with the calm "finished" orb instead of the
    /// waiting one, for people to whom a finished turn is not news.
    var inputLooksReady: Bool = false
    /// Pulse speed multiplier; 1 is the emphasis level's own rate.
    var speed: Double = 1.0
    /// Strength multiplier for the row wash and border.
    var intensity: Double = 1.0
    /// The three orbiting dots of a working agent.
    var animateWorkingOrb: Bool = true
    /// The breathing glow of a waiting orb.
    var pulseWaitingOrb: Bool = true

    static let `default` = AttentionStyle()
    static let speedRange: ClosedRange<Double> = 0.5...2.0
    static let intensityRange: ClosedRange<Double> = 0.4...1.6

    init() {}

    // Decoded field by field so a settings file written by a later build — or
    // one missing a key — never resets the whole group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AttentionStyle.default
        highlightRows = try c.decodeIfPresent(Bool.self, forKey: .highlightRows) ?? d.highlightRows
        markPermission = try c.decodeIfPresent(Bool.self, forKey: .markPermission) ?? d.markPermission
        markInput = try c.decodeIfPresent(Bool.self, forKey: .markInput) ?? d.markInput
        markUnseen = try c.decodeIfPresent(Bool.self, forKey: .markUnseen) ?? d.markUnseen
        inputLooksReady = try c.decodeIfPresent(Bool.self, forKey: .inputLooksReady) ?? d.inputLooksReady
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? d.intensity
        animateWorkingOrb = try c.decodeIfPresent(Bool.self, forKey: .animateWorkingOrb) ?? d.animateWorkingOrb
        pulseWaitingOrb = try c.decodeIfPresent(Bool.self, forKey: .pulseWaitingOrb) ?? d.pulseWaitingOrb
    }

    /// Whether a row in this state should be marked. Pure, so it is testable.
    func marks(status: AgentSessionStatus, unseen: Bool) -> Bool {
        guard highlightRows else { return false }
        switch status {
        case .waitingForPermission:
            return markPermission
        case .waitingForInput:
            if markInput && !inputLooksReady { return true }
            return unseen && markUnseen
        default:
            return unseen && markUnseen
        }
    }

    /// Period after the speed multiplier.
    func period(for emphasis: AttentionEmphasis) -> Double {
        emphasis.period / speed.clamped(to: Self.speedRange)
    }

    func fillOpacity(for emphasis: AttentionEmphasis) -> Double {
        min(1, emphasis.fillOpacity * intensity.clamped(to: Self.intensityRange))
    }

    func borderRange(for emphasis: AttentionEmphasis) -> (low: Double, high: Double) {
        let k = intensity.clamped(to: Self.intensityRange)
        let range = emphasis.borderRange
        return (min(1, range.low * k), min(1, range.high * k))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
