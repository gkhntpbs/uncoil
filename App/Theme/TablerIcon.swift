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
    /// Ready-made accents, in spectrum order so the row reads as a spectrum
    /// rather than as a bag of colours.
    ///
    /// Eighteen rather than eight: with only one swatch per hue, picking "a
    /// blue project" and "another blue project" was impossible, and the answer
    /// to that is not a colour picker — it is a second blue. The picker beside
    /// this row covers everything else.
    static let colors: [UInt32] = [
        0xD95757, 0xE2572B, 0xE0803A, 0xD9A63F,
        0xBFC248, 0x8CBF4C, 0x4CAF7A, 0x3FB4A0,
        0x53B8B0, 0x46A5C9, 0x4A8FD9, 0x5C74E0,
        0x7A63D6, 0xB56CD6, 0xD96BB4, 0xD4577C,
        0x9A7B62, 0x8A8A93,
    ]

    /// What the icon grid opens on before anyone types.
    ///
    /// The grid used to show three hundred icons in alphabetical order, which
    /// is a list nobody reads to the end of. These are the ones that actually
    /// describe a project or a way of setting one up; everything else is a
    /// search away.
    static let suggestedIcons: [String] = [
        "folder", "folders", "box", "package", "stack-2", "layout-grid",
        "layout-dashboard", "app-window", "browser", "device-mobile",
        "device-desktop", "device-laptop", "server", "database", "cloud",
        "api", "plug", "topology-star", "sitemap", "hierarchy",
        "code", "terminal-2", "brand-github", "git-branch", "git-merge",
        "bug", "test-pipe", "flask", "rocket", "bolt",
        "brush", "palette", "wand", "photo", "movie", "music",
        "book", "notes", "file-text", "clipboard-list", "checklist",
        "shopping-cart", "credit-card", "chart-line", "chart-bar",
        "users", "message", "mail", "calendar", "clock",
        "shield", "lock", "key", "settings", "tool", "puzzle",
        "sparkles", "star", "heart", "flame", "leaf", "world",
    ]
}
