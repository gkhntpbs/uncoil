import SwiftUI

/// Uncoil design tokens — single surface, mono type, warm accent.
/// All colors read the live user palette (Settings > Appearance).
@MainActor
enum Theme {
    private static var p: ThemePalette { ThemeStore.shared.palette }

    // Surfaces
    static var bg: Color { Color(hex: p.bg) }
    static var panel: Color { Color(hex: p.panel) }
    static var panelHover: Color { Color(hex: p.panelHover) }
    static var panelActive: Color { Color(hex: p.panelActive) }
    static var border: Color { Color(hex: p.border) }

    /// The sidebar's own surface.
    ///
    /// It used to be `bg`, the same fill as the detail column, so the two halves
    /// of the window were one flat field parted by a hairline. A navigator sits
    /// behind the thing it navigates; a third of the way toward `panel` is
    /// enough to say so without introducing a colour nobody chose.
    static var sidebarSurface: Color { Color(hex: ThemePalette.mix(p.bg, p.panel, 0.35)) }

    // Text
    static var text: Color { Color(hex: p.text) }
    static var textDim: Color { Color(hex: p.textDim) }
    static var textFaint: Color { Color(hex: p.textFaint) }

    // Brand — the product's own mark, the one colour that does not change with
    // the theme.
    static var brand: Color { Color(hex: p.brand) }

    // Highlight: the interactive accent, in the states a control moves through.
    static var highlight: Color { Color(hex: p.highlight) }
    static var highlightHover: Color { Color(hex: p.highlightHover) }
    static var highlightActive: Color { Color(hex: p.highlightActive) }
    /// Filled surface drawn from the highlight — a selected row, a chip.
    static var highlightMuted: Color { Color(hex: p.highlightMuted) }
    static var highlightBorder: Color { Color(hex: p.highlightBorder) }
    /// Text that sits on top of a highlight fill.
    static var textOnHighlight: Color { Color(hex: p.textOnHighlight) }

    // Agent marks
    static var claude: Color { Color(hex: p.claude) }
    static var codex: Color { Color(hex: p.codex) }
    /// The blue the mark itself is built on. Optional in the palette so a
    /// theme customised before Gemini existed still decodes; the fallback is
    /// the brand colour rather than an invented one.
    ///
    /// It sits close to Codex's default blue, which is a real cost in the few
    /// places a provider is named in colour rather than drawn. The marks
    /// themselves stay unmistakable — Gemini's is the only one in four colours
    /// — and taking the brand's own colour away to buy contrast in a caption
    /// seemed the worse trade. Both are palette fields if it turns out wrong.
    static var gemini: Color { Color(hex: p.gemini ?? 0x3186FF) }
    static let terminal = Color(hex: 0x8A8A93)

    // Meanings. Read from the palette rather than fixed: the green that reads on
    // black is unreadable on white.
    static var ok: Color { Color(hex: p.ok) }
    static var warn: Color { Color(hex: p.warn) }
    static var danger: Color { Color(hex: p.danger) }
    static var info: Color { Color(hex: p.info) }

    // Status surfaces — the same four meanings as fills rather than as text.
    //
    // A status told only by tinted text disappears against a busy panel, and a
    // full-strength fill shouts. These are the accent at low opacity, so a badge
    // reads as a surface while the text on it stays the accent itself.
    static var statusSurface: Color { textDim.opacity(0.12) }
    static var infoSurface: Color { info.opacity(0.14) }
    static var successSurface: Color { ok.opacity(0.14) }
    static var warnSurface: Color { warn.opacity(0.16) }
    static var dangerSurface: Color { danger.opacity(0.16) }

    /// Surface for a severity, so a caller does not pick opacities by hand.
    static func surface(for tint: Color) -> Color {
        tint.opacity(0.15)
    }

    // Type — mono carries the product's voice.

    /// The type sizes the interface is allowed to use.
    ///
    /// `mono` used to take any `CGFloat`, and the app drifted to thirteen
    /// different sizes — 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 16, 18,
    /// 20 — where half the pairs were the same role typed differently in two
    /// files. Six steps is enough for a dense mono UI, and a name makes the
    /// choice a decision rather than a number someone happened to write.
    enum TypeScale: CGFloat {
        /// Counters and badges.
        case micro = 9.5
        /// Secondary labels, metadata, captions.
        case small = 10.5
        /// Ordinary interface text.
        case body = 11.5
        /// Section and row titles.
        case large = 13
        /// Screen titles.
        case title = 16
        /// Empty states, the one-off big number.
        case display = 20
    }

    static func mono(_ size: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight, design: .monospaced)
    }

    /// Prose: titles, explanations, empty states — anything a person reads as a
    /// sentence rather than scans as data.
    ///
    /// Mono is the product's voice and stays on everything that *is* data: ids,
    /// paths, branch names, log output, counters, session titles. It is the
    /// wrong face for a paragraph. Setting a screen's explanatory copy in a
    /// terminal face is what made a careful interface read as a developer
    /// utility; the same words in the system face read as a product, and the
    /// contrast between the two makes the mono mean something again.
    ///
    /// Same scale as ``mono(_:_:)`` — one type ramp, two faces on it.
    static func ui(_ size: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
    }

    /// Escape hatch for sizes that are computed rather than chosen — a terminal
    /// font tied to a user setting, a glyph measured against its container.
    /// Fixed interface text belongs on ``TypeScale``.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Geometry

    /// The corner radii the interface is allowed to use.
    ///
    /// The app had drifted to nine — 3, 4, 5, 6, 7, 8, 9, 10, 12 — where most
    /// neighbouring pairs were the same role rounded differently in two files.
    /// A window full of almost-matching corners reads as unconsidered even when
    /// no single corner looks wrong. Three steps, tied to what a surface *is*
    /// rather than how big it happens to be.
    enum Radius {
        /// Chips, badges, hover fills behind a single row.
        static let chip: CGFloat = 6
        /// Panels, cards, list containers — the app's basic surface.
        static let panel: CGFloat = 10
        /// Surfaces that float above the window: sheets, the palette, popovers.
        static let sheet: CGFloat = 14
    }

    /// The spacing steps layouts are built from. A 4pt grid, named by role so
    /// padding is a decision rather than a number someone happened to type.
    enum Space {
        /// Between a glyph and its label.
        static let hair: CGFloat = 4
        /// Inside a chip, between tight siblings.
        static let tight: CGFloat = 8
        /// Standard padding inside a panel.
        static let snug: CGFloat = 12
        /// Between panels, around a screen's content.
        static let roomy: CGFloat = 16
        /// Between major sections.
        static let section: CGFloat = 24
    }

    // MARK: - Motion

    /// How the interface moves.
    ///
    /// Everything used to be `easeOut` between 0.12s and 0.2s: correct, and
    /// completely inert. Springs cost nothing extra and carry the weight that
    /// makes a surface feel like an object rather than a redraw. Durations stay
    /// in the same range — this is about the curve, not about slowing the app
    /// down. Damping stays high; nothing here should visibly wobble.
    enum Motion {
        /// Hover and other pointer-tracking feedback. Must not lag the cursor.
        static var quick: Animation? { uncoilAnimation(.spring(response: 0.22, dampingFraction: 0.9)) }
        /// The default: selection, disclosure, a row appearing.
        static var standard: Animation? { uncoilAnimation(.spring(response: 0.32, dampingFraction: 0.86)) }
        /// Surfaces that arrive from somewhere — sheets, the palette, the
        /// sidebar sliding in. Given a little more travel to read as movement.
        static var expressive: Animation? { uncoilAnimation(.spring(response: 0.44, dampingFraction: 0.82)) }
    }

    // MARK: - Elevation

    /// What separates a floating surface from the window behind it.
    ///
    /// A flat app has exactly one plane, and a sheet drawn on it is just a
    /// lighter rectangle. These are deliberately soft and near-black: on the
    /// dark palette a shadow is the only cue, and on the light one it is what
    /// keeps white-on-white surfaces apart.
    enum Elevation {
        /// A row or chip lifted off its container on hover.
        case low
        /// Popovers, menus, the command palette.
        case floating
        /// Modal sheets — the only thing allowed to cast this far.
        case modal

        var radius: CGFloat {
            switch self {
            case .low: 6
            case .floating: 26
            case .modal: 40
            }
        }

        var y: CGFloat {
            switch self {
            case .low: 1
            case .floating: 8
            case .modal: 18
            }
        }

        @MainActor
        var opacity: Double {
            // A light window needs a denser shadow to read at all; on the dark
            // palette the same value would look like soot.
            let light = ThemeStore.shared.palette.isLight
            switch self {
            case .low: return light ? 0.10 : 0.24
            case .floating: return light ? 0.16 : 0.40
            case .modal: return light ? 0.22 : 0.55
            }
        }
    }
}

extension View {
    /// The two things every control owes the pointer: it notices the cursor,
    /// and it gives under the click.
    ///
    /// The give is deliberately small — 2% — and springs back. Anything larger
    /// on a dense mono interface reads as a toy, and anything with no give at
    /// all leaves the user unsure the click landed at all.
    func buttonFeedback(isPressed: Bool, hovering: Binding<Bool>) -> some View {
        scaleEffect(isPressed ? 0.98 : 1)
            .animation(Theme.Motion.quick, value: isPressed)
            .animation(Theme.Motion.quick, value: hovering.wrappedValue)
            .onHover { hovering.wrappedValue = $0 }
    }

    /// Lifts a surface off the plane behind it. See ``Theme/Elevation``.
    ///
    /// `nil` casts nothing, so a surface that is only raised while the pointer
    /// is over it can say so inline instead of branching its whole body.
    func elevated(_ level: Theme.Elevation?) -> some View {
        modifier(ElevationStyle(level: level))
    }
}

/// A list row that fills under the pointer.
///
/// Rows are the one control that must not scale — a line of a list shrinking
/// under the cursor pushes its neighbours around — so they get a fill instead,
/// and they own the state themselves rather than making every list that holds
/// them declare an `@State` it does not otherwise need.
struct HoverRowStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.chip

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                hovering ? Theme.panelHover : .clear,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .animation(Theme.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// See ``HoverRowStyle``. Apply to the row, outside its button style.
    func hoverRow(radius: CGFloat = Theme.Radius.chip) -> some View {
        modifier(HoverRowStyle(radius: radius))
    }
}

/// `.plain`, plus the give a click deserves.
///
/// `.buttonStyle(.plain)` renders a control that never acknowledges being
/// pressed — on an icon button with no fill of its own, the only feedback is
/// whatever the action happens to change on screen, which may be nothing and is
/// never immediate. The scale is larger than a labelled button's because the
/// target is smaller: the same 2% on a 20pt glyph is invisible.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// `Theme.Elevation.opacity` reads the live palette, which SwiftUI cannot track
/// on its own — same reason ``PanelStyle`` observes the store.
private struct ElevationStyle: ViewModifier {
    let level: Theme.Elevation?

    @ObservedObject private var theme = ThemeStore.shared

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(level?.opacity ?? 0),
            radius: level?.radius ?? 0,
            y: level?.y ?? 0
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Rounded panel with hairline border — the app's basic building block.
///
/// `Theme`'s colours are static reads of a global, which SwiftUI cannot track as
/// a dependency: without observing the store, a panel keeps the surface it was
/// first drawn with and a theme switch leaves it stranded in the old palette.
struct PanelStyle: ViewModifier {
    var radius: CGFloat = Theme.Radius.panel

    @ObservedObject private var theme = ThemeStore.shared

    /// A hairline of light along the top edge, the way a raised surface catches
    /// the room. One pixel of it is the difference between a panel that sits on
    /// the window and a rectangle painted onto it — and it is the cheapest
    /// depth cue there is, since it costs no shadow and no blur.
    private var topLight: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(theme.palette.isLight ? 0.9 : 0.07),
                .clear,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(
                // Masked to the top third so the light falls off rather than
                // outlining the whole panel a second time.
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(topLight, lineWidth: 1)
                    .mask(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func panel(radius: CGFloat = Theme.Radius.panel) -> some View {
        modifier(PanelStyle(radius: radius))
    }
}

/// Dot-matrix agent glyph — Uncoil's signature mark. A 3×2 grid of dots
/// in the provider's color, echoing terminal pixel art.
struct DotGlyph: View {
    let color: Color
    var dotSize: CGFloat = 2.6
    var litPattern: [Bool] = [true, false, true, true, true, false]

    var body: some View {
        Grid(horizontalSpacing: dotSize * 0.9, verticalSpacing: dotSize * 0.9) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        Circle()
                            .fill(litPattern[row * 3 + column] ? color : color.opacity(0.22))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// Relative timestamps the way the sidebar shows them: 2m · 5h · 3d
enum RelativeClock {
    static func short(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        // The unit letters are part of the translation: Turkish abbreviates
        // minute/hour/day as dk/sa/g, which no English reader would guess.
        case ..<3600: return String(localized: "\(Int(seconds / 60))m")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600))h")
        default: return String(localized: "\(Int(seconds / 86_400))d")
        }
    }
}

/// A short status word on its own surface.
///
/// One place decides how a status looks, so "tests failing" in the Tasks screen
/// and in the Extensions screen cannot drift apart.
struct StatusBadge: View {
    enum Level {
        case neutral
        case success
        case warning
        case danger
        case accent(Color)

        @MainActor
        var foreground: Color {
            switch self {
            case .neutral: Theme.textDim
            case .success: Theme.ok
            case .warning: Theme.warn
            case .danger: Theme.danger
            case .accent(let color): color
            }
        }

        @MainActor
        var surface: Color {
            switch self {
            case .neutral: Theme.statusSurface
            case .success: Theme.successSurface
            case .warning: Theme.warnSurface
            case .danger: Theme.dangerSurface
            case .accent(let color): Theme.surface(for: color)
            }
        }
    }

    let text: String
    var level: Level = .neutral
    var iconName: String?

    var body: some View {
        HStack(spacing: 4) {
            if let iconName {
                TablerIcon(name: iconName, size: 9, color: level.foreground)
            }
            Text(text)
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(level.foreground)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(level.surface, in: Capsule())
    }
}
