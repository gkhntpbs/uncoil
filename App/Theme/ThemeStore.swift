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
    var textFaint: UInt32 = 0x55555E
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
        textFaint: 0x9A9AA1,
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
