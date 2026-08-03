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

    /// Names already reported, so one bad icon in a list does not fire once per
    /// row per redraw.
    nonisolated(unsafe) private static var reported: Set<String> = []
    private static let reportLock = NSLock()

    /// Complains about an icon name the bundled font does not carry. Debug
    /// builds and the test suite fail loudly; a release build draws the dot and
    /// says nothing, because a missing icon is not worth a crash in front of a
    /// user. Returns the name so it can be used from a view builder.
    @discardableResult
    static func reportUnknown(_ name: String) -> String {
        #if DEBUG
        reportLock.lock()
        let isNew = reported.insert(name).inserted
        reportLock.unlock()
        // Under XCTest the trap would abort the whole suite from inside some
        // unrelated view's body; the icon-name tests assert on `glyph` instead.
        if isNew, NSClassFromString("XCTest") == nil {
            assertionFailure("Unknown Tabler icon '\(name)'. Names are kebab-case and the bundled outline font has no filled variants.")
        }
        #endif
        return name
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
            // A typo used to ship as a dot and go unnoticed for months — the
            // Run page's action row and the sidebar's pin marker both did. The
            // names are kebab-case and the outline font has no `-filled`
            // variants; trip a debug build the first time one is drawn.
            let _ = TablerIcons.reportUnknown(name)
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
