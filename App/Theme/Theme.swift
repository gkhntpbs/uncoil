import SwiftUI

/// Uncoil design tokens — single dark surface, mono type, warm accent.
enum Theme {
    // Surfaces
    static let bg = Color(hex: 0x0F0F11)
    static let panel = Color(hex: 0x1A1A1E)
    static let panelHover = Color(hex: 0x222227)
    static let panelActive = Color(hex: 0x26262C)
    static let border = Color(hex: 0x2A2A30)

    // Text
    static let text = Color(hex: 0xE9E9EC)
    static let textDim = Color(hex: 0x86868F)
    static let textFaint = Color(hex: 0x55555E)

    // Accents
    static let claude = Color(hex: 0xE2572B)
    static let codex = Color(hex: 0x4A8FD9)
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
