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
