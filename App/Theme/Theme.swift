import SwiftUI

/// Uncoil design tokens — single surface, mono type, warm accent.
/// All colors read the live user palette (Ayarlar > Tema).
@MainActor
enum Theme {
    private static var p: ThemePalette { ThemeStore.shared.palette }

    // Surfaces
    static var bg: Color { Color(hex: p.bg) }
    static var panel: Color { Color(hex: p.panel) }
    static var panelHover: Color { Color(hex: p.panelHover) }
    static var panelActive: Color { Color(hex: p.panelActive) }
    static var border: Color { Color(hex: p.border) }

    // Text
    static var text: Color { Color(hex: p.text) }
    static var textDim: Color { Color(hex: p.textDim) }
    static var textFaint: Color { Color(hex: p.textFaint) }

    // Accents
    static var claude: Color { Color(hex: p.claude) }
    static var codex: Color { Color(hex: p.codex) }
    static let terminal = Color(hex: 0x8A8A93)
    static let ok = Color(hex: 0x4CAF7A)
    static let warn = Color(hex: 0xD9A63F)
    static let danger = Color(hex: 0xD95757)

    // Status surfaces — the same four meanings as fills rather than as text.
    //
    // A status told only by tinted text disappears against a busy panel, and a
    // full-strength fill shouts. These are the accent at low opacity, so a badge
    // reads as a surface while the text on it stays the accent itself.
    static var statusSurface: Color { textDim.opacity(0.12) }
    static var successSurface: Color { ok.opacity(0.14) }
    static var warnSurface: Color { warn.opacity(0.16) }
    static var dangerSurface: Color { danger.opacity(0.16) }

    /// Surface for a severity, so a caller does not pick opacities by hand.
    static func surface(for tint: Color) -> Color {
        tint.opacity(0.15)
    }

    // Type — mono carries the product's voice.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
struct PanelStyle: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func panel(radius: CGFloat = 10) -> some View {
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

/// Relative timestamps the way the sidebar shows them: 2dk · 5sa · 3g
enum RelativeClock {
    static func short(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "şimdi"
        case ..<3600: return "\(Int(seconds / 60))dk"
        case ..<86_400: return "\(Int(seconds / 3600))sa"
        default: return "\(Int(seconds / 86_400))g"
        }
    }
}

/// A short status word on its own surface.
///
/// One place decides how a status looks, so "test başarısız" in the Tasks screen
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
                .font(Theme.mono(9, .semibold))
                .foregroundStyle(level.foreground)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(level.surface, in: Capsule())
    }
}
