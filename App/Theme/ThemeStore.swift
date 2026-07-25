import SwiftUI

/// User-customizable palette. Every color the UI uses funnels through this;
/// `Theme`'s static accessors read the live palette.
struct ThemePalette: Codable, Equatable, Hashable {
    var isLight = false
    var bg: UInt32 = 0x0F0F11
    var panel: UInt32 = 0x1A1A1E
    var panelHover: UInt32 = 0x222227
    var panelActive: UInt32 = 0x26262C
    var border: UInt32 = 0x2A2A30
    var text: UInt32 = 0xE9E9EC
    var textDim: UInt32 = 0x86868F
    /// Raised from 0x55555E: against `bg` and `panelActive` the old value sat at
    /// 2.6:1, under the 3:1 Uncoil holds secondary text to. `ThemeContrastTests`
    /// enforces it now.
    var textFaint: UInt32 = 0x707079
    var claude: UInt32 = 0xE2572B
    var codex: UInt32 = 0x4A8FD9
    var terminalBg: UInt32 = 0x0F0F11
    var terminalFg: UInt32 = 0xE9E9EC

    static let dark = ThemePalette()

    static let light = ThemePalette(
        isLight: true,
        bg: 0xF5F4F1,
        panel: 0xFFFFFF,
        panelHover: 0xECEAE6,
        panelActive: 0xE3E1DC,
        border: 0xD9D6D0,
        text: 0x1C1C1E,
        textDim: 0x5F5F66,
        // Darkened from 0x9A9AA1 for the same reason as the dark palette's:
        // 2.54:1 against the window background was not readable.
        textFaint: 0x7E7E85,
        claude: 0xD24A20,
        codex: 0x2F6FBE,
        terminalBg: 0xFFFFFF,
        terminalFg: 0x1C1C1E
    )
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var palette: ThemePalette {
        didSet { save() }
    }

    private var fileURL: URL {
        ProjectStore.defaultDirectory().appendingPathComponent("theme.json")
    }

    private init() {
        palette = ThemePalette.dark
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ThemePalette.self, from: data) {
            palette = decoded
        }
    }

    func apply(preset: ThemePalette) {
        palette = preset
    }

    private func save() {
        if let data = try? JSONEncoder().encode(palette) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// SwiftUI Color binding for a palette slot (used by settings pickers).
    func binding(_ keyPath: WritableKeyPath<ThemePalette, UInt32>) -> Binding<Color> {
        Binding(
            get: { Color(hex: self.palette[keyPath: keyPath]) },
            set: { self.palette[keyPath: keyPath] = $0.hexValue }
        )
    }
}

extension Color {
    /// Approximate 0xRRGGBB of a SwiftUI color (for persisting picker output).
    var hexValue: UInt32 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = UInt32((ns.redComponent * 255).rounded())
        let g = UInt32((ns.greenComponent * 255).rounded())
        let b = UInt32((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

/// Contrast arithmetic for a palette.
///
/// A light theme's tuning fails in a measurable way — text that is technically
/// visible and practically unreadable — so the rule is a number rather than an
/// opinion. Ratios are WCAG 2.1 relative luminance.
extension ThemePalette {
    /// Text sizes Uncoil actually uses are small (9–13pt mono), so the normal-text
    /// threshold applies throughout; there is no "large text" exemption to lean on.
    static let minimumTextContrast = 4.5
    /// Dim and faint text is secondary by design, but it still has to be readable.
    static let minimumSecondaryTextContrast = 3.0
    /// A border only has to be perceptible against its surroundings.
    static let minimumBorderContrast = 1.2

    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.039_28
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = channel((hex >> 16) & 0xFF)
        let green = channel((hex >> 8) & 0xFF)
        let blue = channel(hex & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// One pair that has to hold, with the threshold it is judged against.
    struct ContrastRequirement: Equatable {
        var label: String
        var foreground: UInt32
        var background: UInt32
        var minimum: Double

        func ratio() -> Double { ThemePalette.contrast(foreground, background) }
        func holds() -> Bool { ratio() >= minimum }
    }

    /// Every pair the app actually puts on screen. Kept explicit so a new surface
    /// has to be added here to be considered checked.
    var contrastRequirements: [ContrastRequirement] {
        var pairs: [ContrastRequirement] = []
        for (name, surface) in [
            ("bg", bg), ("panel", panel), ("panelHover", panelHover), ("panelActive", panelActive),
        ] {
            pairs.append(.init(
                label: "text on \(name)", foreground: text, background: surface,
                minimum: Self.minimumTextContrast
            ))
            pairs.append(.init(
                label: "textDim on \(name)", foreground: textDim, background: surface,
                minimum: Self.minimumSecondaryTextContrast
            ))
            pairs.append(.init(
                label: "textFaint on \(name)", foreground: textFaint, background: surface,
                minimum: Self.minimumSecondaryTextContrast
            ))
            pairs.append(.init(
                label: "claude on \(name)", foreground: claude, background: surface,
                minimum: Self.minimumSecondaryTextContrast
            ))
            pairs.append(.init(
                label: "codex on \(name)", foreground: codex, background: surface,
                minimum: Self.minimumSecondaryTextContrast
            ))
        }
        pairs.append(.init(
            label: "terminal foreground on terminal background",
            foreground: terminalFg, background: terminalBg,
            minimum: Self.minimumTextContrast
        ))
        pairs.append(.init(
            label: "border on bg", foreground: border, background: bg,
            minimum: Self.minimumBorderContrast
        ))
        pairs.append(.init(
            label: "border on panel", foreground: border, background: panel,
            minimum: Self.minimumBorderContrast
        ))
        return pairs
    }

    /// The pairs that do not hold, for a test to name.
    var contrastFailures: [ContrastRequirement] {
        contrastRequirements.filter { !$0.holds() }
    }
}
