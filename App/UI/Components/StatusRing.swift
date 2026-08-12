import SwiftUI

/// The app's status mark: an outlined ring, in the colour of what it says.
///
/// A ring rather than a filled dot, and drawn at a size you can read across the
/// window. The distinction it has to carry is the one a tick cannot: *not run*
/// is not *passed with nothing in it*, and *running* is neither. So the ring is
/// dashed while something is in flight, hollow and neutral before it has ever
/// happened, and solid in its own colour once there is an answer.
///
/// Shared on purpose. Every surface that reports on a long-lived thing — a test
/// suite, a run, a task, a session — should mark it the same way.
struct StatusRing: View {
    enum State: Equatable {
        /// Never run. Neutral, and deliberately not a grey tick.
        case idle
        /// Deliberately not run — a skipped test, a disabled step.
        case skipped
        /// In flight.
        case running
        case passed
        case failed
        case warned

        /// The mark drawn inside the ring, when the ring is asked to carry one.
        /// Nil while running and before anything has happened: neither is a
        /// verdict, and a glyph would make it look like one.
        var glyph: String? {
            switch self {
            case .idle, .running: nil
            case .skipped: "minus"
            case .passed: "check"
            case .failed: "x"
            case .warned: "alert-triangle"
            }
        }

        @MainActor var color: Color {
            switch self {
            case .idle: Theme.textFaint
            case .skipped: Theme.textDim
            case .running: Theme.textDim
            case .passed: Theme.ok
            case .failed: Theme.danger
            case .warned: Theme.warn
            }
        }
    }

    let state: State
    var size: CGFloat = 24
    /// Draws the verdict inside the ring. Worth it in a list, where a row of
    /// rings of slightly different colours is not a distinction anyone reads;
    /// unnecessary on a card, where the ring is large and alone.
    var showsGlyph = false
    /// Scales with the ring so a small one does not read as a thick blob.
    var lineWidth: CGFloat { max(1.5, size / 14) }

    /// One turn every two seconds. Slow on purpose: this is a sign that work is
    /// happening, not a thing to watch.
    @SwiftUI.State private var spinning = false

    var body: some View {
        Group {
            if state == .running {
                Circle()
                    .strokeBorder(
                        state.color,
                        style: StrokeStyle(
                            lineWidth: lineWidth, lineCap: .round, dash: [2.5, 3.5]
                        )
                    )
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        uncoilAnimation(.linear(duration: 2).repeatForever(autoreverses: false)),
                        value: spinning
                    )
                    .onAppear { spinning = true }
            } else {
                Circle()
                    .strokeBorder(state.color, lineWidth: lineWidth)
                    .overlay {
                        if showsGlyph, let glyph = state.glyph {
                            TablerIcon(name: glyph, size: size * 0.58, color: state.color)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        // A suite going from running to green is a change worth seeing happen.
        .animation(Theme.Motion.standard, value: state)
        .accessibilityHidden(true)
    }
}

/// A bare glyph that does something — the app's primary action mark when the
/// surface is already a card and a bordered button would be a box inside a box.
///
/// It grows a hover fill rather than a border, so at rest the glyph is the only
/// thing on the surface and the target is still the whole square.
struct GlyphActionButton: View {
    let iconName: String
    let help: String
    let identifier: String
    var tint: Color = Theme.text
    var size: CGFloat = 20
    let action: () -> Void

    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(name: iconName, size: size, color: tint)
                .frame(width: size + 16, height: size + 16)
                .background(
                    hovering ? tint.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                )
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}

/// A small filled square that acts on the row it sits in.
///
/// Distinct from ``GlyphActionButton``: that one is the card's own action and
/// is bare, this one belongs to a row in a list and has to be findable among
/// text, so it carries its colour.
struct MiniActionButton: View {
    let iconName: String
    let help: String
    let identifier: String
    var tint: Color = Theme.highlight
    let action: () -> Void

    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(name: iconName, size: 12, color: Theme.textOnHighlight)
                .frame(width: 24, height: 24)
                .background(
                    hovering ? tint : tint.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                )
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}
