import SwiftUI
import CoreText

/// Tabler Icons (MIT) rendered from the bundled outline webfont.
enum TablerIcons {
    /// Font family inside the ttf (differs from the file name).
    static let fontName = "tabler-icons"
    static let resourceName = "tabler-icons-outline"

    /// name → unicode codepoint, loaded once from the bundled JSON.
    static let map: [String: UInt32] = {
        guard
            let url = Bundle.main.url(forResource: "tabler-icons", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: UInt32].self, from: data)
        else { return [:] }
        return decoded
    }()

    static let sortedNames: [String] = map.keys.sorted()

    static func register() {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func glyph(_ name: String) -> String? {
        guard let code = map[name], let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }
}

/// One Tabler icon glyph; falls back to a dot when the name is unknown.
struct TablerIcon: View {
    let name: String
    var size: CGFloat = 12
    var color: Color = Theme.textDim

    var body: some View {
        if let glyph = TablerIcons.glyph(name) {
            Text(glyph)
                .font(.custom(TablerIcons.fontName, size: size))
                .foregroundStyle(color)
        } else {
            Circle()
                .fill(color)
                .frame(width: size * 0.4, height: size * 0.4)
                .frame(width: size, height: size)
        }
    }
}

/// Palette offered in the project customize sheet.
enum ProjectPalette {
    static let colors: [UInt32] = [
        0xE2572B, 0x4A8FD9, 0x4CAF7A, 0xD9A63F,
        0xB56CD6, 0xD95757, 0x53B8B0, 0x8A8A93,
    ]
}
