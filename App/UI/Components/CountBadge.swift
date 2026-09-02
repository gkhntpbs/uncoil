import SwiftUI

/// What a badge means, rather than what colour it is.
///
/// The fill and the digit on top of it are chosen together, because they
/// cannot be chosen apart: the meaning colours flip between the light and dark
/// presets, so a caller passing a `Color` would have to know which side of the
/// theme it is on to pick text that stays readable. Naming the meaning is the
/// whole decision, and it also keeps badges across the app consistent — red is
/// "you have work waiting", amber is "look at this when you can".
@MainActor
enum BadgeTint {
    case danger
    case warn
    case info
    case accent

    var fill: Color {
        switch self {
        case .danger: Theme.danger
        case .warn: Theme.warn
        case .info: Theme.info
        case .accent: Theme.highlight
        }
    }

    var foreground: Color {
        switch self {
        case .danger: Theme.textOnDanger
        case .warn: Theme.textOnWarn
        case .info: Theme.textOnInfo
        case .accent: Theme.textOnHighlight
        }
    }
}

/// The number in a circle that sits on the corner of something else.
///
/// Distinct from `CountChip`, which is a tally you read *in* a row. A badge is
/// an interruption: it is drawn over another control to say that control now
/// has something waiting behind it, and it has to stay legible at nine points
/// on top of an icon. That is why it carries its own rules — a ring in the
/// surrounding surface so the digit never merges into whatever it covers, a
/// cap so a busy morning cannot widen the sidebar, and a shape that grows into
/// a capsule for two digits instead of squashing them.
///
/// It says nothing when there is nothing to say: a count of zero draws no
/// badge at all, which is what lets a caller attach one unconditionally and
/// let the number decide.
struct CountBadge: View {
    let count: Int
    var tint: BadgeTint = .danger
    /// Beyond this the exact number stops being useful and starts being wide.
    var cap = 99
    /// The colour the badge is drawn *on*, which is what its ring is made of.
    /// nil takes the sidebar's surface, where these mostly live.
    var surround: Color?

    private var text: String { count > cap ? "\(cap)+" : "\(count)" }

    var body: some View {
        if count > 0 {
            Text(text)
                .font(Theme.mono(9, .bold))
                .monospacedDigit()
                .foregroundStyle(tint.foreground)
                .padding(.horizontal, count > 9 ? 3.5 : 0)
                .frame(minWidth: 14, minHeight: 14)
                .background(tint.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(surround ?? Theme.sidebarSurface, lineWidth: 1.5))
                .fixedSize()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Puts a count on this view's top-right corner.
    ///
    /// Laid out in an overlay so it takes no space and overhangs the corner: a
    /// rail of icons must not shift sideways the moment one of them has news.
    /// Give `label` a reading of what the number means — the badge itself is
    /// hidden from accessibility, because a bare "3" announced beside a button
    /// is not information.
    func countBadge(
        _ count: Int,
        tint: BadgeTint = .danger,
        surround: Color? = nil,
        label: String? = nil
    ) -> some View {
        overlay(alignment: .topTrailing) {
            CountBadge(count: count, tint: tint, surround: surround)
                .offset(x: 5, y: -4)
                .animation(Theme.Motion.quick, value: count)
                .allowsHitTesting(false)
        }
        .accessibilityValue(count > 0 ? (label ?? "\(count)") : "")
    }
}
