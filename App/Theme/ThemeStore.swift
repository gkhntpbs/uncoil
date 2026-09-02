import AppKit
import SwiftUI

/// User-customizable palette. Every color the UI uses funnels through this;
/// `Theme`'s static accessors read the live palette.
struct ThemePalette: Codable, Equatable, Hashable {
    /// Bumped when the shipped palettes change. A stored palette from an older
    /// version is replaced by the current preset rather than kept: the tokens
    /// below are a set, and half of an old one mixed with half of a new one is
    /// not a theme anyone chose. 
    /// 3: the agent brand colours became each product's own (Claude 0xD97757,
    /// Codex 0x3B82F6). Without the bump a palette saved before the change
    /// keeps the old marks, and changing the shipped default does nothing at
    /// all for anyone who has already run the app.
    static let currentVersion = 3

    var version: Int = currentVersion
    var isLight = false

    // Surfaces
    var bg: UInt32 = 0x0F0F11
    var panel: UInt32 = 0x1A1A1E
    var panelHover: UInt32 = 0x222227
    var panelActive: UInt32 = 0x26262C
    var border: UInt32 = 0x2A2A30

    // Text
    var text: UInt32 = 0xE9E9EC
    var textDim: UInt32 = 0x86868F
    /// Raised from 0x55555E: against `bg` and `panelActive` the old value sat at
    /// 2.6:1, under the 3:1 Uncoil holds secondary text to. `ThemeContrastTests`
    /// enforces it now.
    var textFaint: UInt32 = 0x707079

    /// The product's own mark. Constant across themes — a logo does not change
    /// colour when the lights go out.
    var brand: UInt32 = 0x8B5CF6

    // Highlight: the interactive accent, in its four states plus the surface and
    // border drawn from it, and the text that sits on top of it.
    var highlight: UInt32 = 0xA78BFA
    var highlightHover: UInt32 = 0xB79FFF
    var highlightActive: UInt32 = 0x8B5CF6
    var highlightMuted: UInt32 = 0x2A203B
    var highlightBorder: UInt32 = 0x6D4BB4
    var textOnHighlight: UInt32 = 0x17121F

    // Meanings. Per-theme rather than fixed: the same green that reads on black
    // is unreadable on white.
    var ok: UInt32 = 0x4ADE80
    var warn: UInt32 = 0xFBBF24
    var danger: UInt32 = 0xFB7185
    var info: UInt32 = 0x60A5FA

    // Agent brand marks, in each product's own colour.
    var claude: UInt32 = 0xD97757
    var codex: UInt32 = 0x3B82F6
    /// Optional so a palette written before Gemini existed still decodes.
    var gemini: UInt32? = nil
    /// Optional for the same reason. These four brands are monochrome or
    /// near-monochrome, so their marks are the colours most at risk on a light
    /// background: white-on-white is not a low-contrast mark, it is no mark.
    var opencode: UInt32? = nil
    var grok: UInt32? = nil
    var cursor: UInt32? = nil
    var amp: UInt32? = nil

    /// What a palette that predates a mark falls back to — the dark preset's
    /// value, which is also each brand's own. Named once so `Theme` and the
    /// contrast requirements cannot disagree about them.
    static let defaultGemini: UInt32 = 0x3186FF
    static let defaultOpenCode: UInt32 = 0xE0DED4
    static let defaultGrok: UInt32 = 0xFFFFFF
    static let defaultCursor: UInt32 = 0xC9C9CF
    static let defaultAmp: UInt32 = 0x81AE7A

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
        brand: 0x8B5CF6,
        highlight: 0x7C3AED,
        highlightHover: 0x6D28D9,
        highlightActive: 0x5B21B6,
        highlightMuted: 0xF0EAFF,
        highlightBorder: 0xC4B5FD,
        textOnHighlight: 0xFFFFFF,
        ok: 0x15803D,
        warn: 0xB45309,
        danger: 0xBE123C,
        info: 0x2563EB,
        // The brand colours darkened for a light background: the shipped
        // 0xD97757 measures 2.39:1 on the pressed panel and 0x3B82F6 2.81:1,
        // both under the 3:1 floor `ThemeContrastTests` holds them to.
        claude: 0xB85A38,
        codex: 0x2563EB,
        // Gemini's blue was never given a light value, and nothing checked it
        // until the marks were added to `contrastRequirements`: the shipped
        // 0x3186FF measures 2.92:1 on the hovered panel, under the same 3:1
        // floor the other two were darkened for.
        gemini: 0x1A73E8,
        // Monochrome brands, inverted for a light background rather than
        // dimmed: on white, Grok's own white measures 1.00:1 — the mark is
        // simply absent — and the other three sit between 1.03 and 2.54 on the
        // pressed panel. xAI ships a black variant of its mark for exactly
        // this case; the rest follow it.
        opencode: 0x3A382F,
        grok: 0x1C1C1E,
        cursor: 0x2C2C2E,
        amp: 0x3E5A38,
        terminalBg: 0xFFFFFF,
        terminalFg: 0x1C1C1E
    )

    /// The shipped preset matching this palette's mode, for migration and for
    /// the "reset" button.
    var preset: ThemePalette { isLight ? .light : .dark }

    /// Blends two palette colours in sRGB, `amount` of the way from `a` to `b`.
    ///
    /// Lets a derived surface stay a function of the user's palette instead of
    /// a fourth hard-coded grey that a custom theme would leave stranded.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(1, max(0, amount))
        var out: UInt32 = 0
        for shift in stride(from: 16, through: 0, by: -8) {
            let channelA = Double((a >> UInt32(shift)) & 0xFF)
            let channelB = Double((b >> UInt32(shift)) & 0xFF)
            let blended = UInt32((channelA + (channelB - channelA) * t).rounded())
            out |= blended << UInt32(shift)
        }
        return out
    }
}

/// Which of the two presets the app wears, or that it follows the Mac.
enum ThemeAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var palette: ThemePalette {
        didSet {
            guard palette != oldValue else { return }
            save()
            // Live terminals hold their colours in AppKit, outside SwiftUI's
            // reach, so they have to be told.
            TerminalRegistry.shared.applyThemeToLiveTerminals()
        }
    }

    /// Dark, light, or whatever the Mac is doing. Separate from `palette`
    /// because "follow the system" is not a colour — a palette can only ever
    /// record which one it currently *is*, not that it was asked to keep up.
    @Published private(set) var appearance: ThemeAppearance = .system {
        didSet {
            guard appearance != oldValue else { return }
            save()
        }
    }

    private var fileURL: URL { Self.fileURL }

    private static var fileURL: URL {
        ProjectStore.defaultDirectory().appendingPathComponent("theme.json")
    }

    /// theme.json used to be a bare `ThemePalette`. It is now a wrapper so the
    /// appearance can live beside it, and the bare form is still decoded — a
    /// file written by an older build holds the palette somebody chose, and
    /// throwing it away on upgrade is not a migration, it is a reset.
    struct Stored: Codable {
        var palette: ThemePalette
        var appearance: ThemeAppearance?
    }

    private var systemObservation: NSKeyValueObservation?
    private var systemNotification: (any NSObjectProtocol)?

    private init() {
        let restored = Self.restore(from: try? Data(contentsOf: Self.fileURL))
        palette = restored.palette
        appearance = restored.appearance
        observeSystemAppearance()
        if appearance == .system { syncWithSystem(animated: false) }
    }

    /// Pure, so the one piece of logic that could silently reset every user's
    /// theme on upgrade is unit-tested rather than trusted.
    static func restore(from data: Data?) -> (palette: ThemePalette, appearance: ThemeAppearance) {
        guard let data else { return (.dark, .system) }
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Stored.self, from: data) {
            let palette = migrated(wrapped.palette)
            // A file with no appearance in it was written before the choice
            // existed. Whatever palette it holds is what that user picked by
            // hand, so it becomes an explicit light or dark rather than
            // silently starting to follow the Mac and changing under them.
            return (palette, wrapped.appearance ?? (palette.isLight ? .light : .dark))
        }
        if let bare = try? decoder.decode(ThemePalette.self, from: data) {
            let palette = migrated(bare)
            return (palette, palette.isLight ? .light : .dark)
        }
        // Unreadable: the shipped default, and `system` because a fresh install
        // has expressed no preference.
        return (.dark, .system)
    }

    /// A palette saved before the tokens changed is migrated to the current
    /// preset of its own mode. Keeping it would leave the app half in one
    /// palette and half in another, with the new tokens at their defaults.
    static func migrated(_ palette: ThemePalette) -> ThemePalette {
        palette.version < ThemePalette.currentVersion ? palette.preset : palette
    }

    // MARK: - Choosing

    /// The user picking Dark, Light or System.
    ///
    /// Cross-fades, because every colour in every window changes at once and an
    /// instantaneous swap of the whole interface reads as a glitch rather than
    /// as a setting taking effect.
    func setAppearance(_ next: ThemeAppearance) {
        guard next != appearance else { return }
        ThemeTransition.fade {
            self.appearance = next
            switch next {
            case .system: self.syncWithSystem(animated: false)
            case .light: self.palette = .light
            case .dark: self.palette = .dark
            }
        }
    }


    // MARK: - Following the Mac

    var systemIsLight: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }

    private func observeSystemAppearance() {
        // KVO on the application's own effective appearance is the accurate
        // source: the `AppleInterfaceThemeChanged` distributed notification
        // fires *before* `effectiveAppearance` has caught up, so reading it
        // from there gives the value that is on its way out.
        systemObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.systemAppearanceChanged() }
        }
        // Belt and braces. The notification is unreliable about *when*, not
        // about *whether*, and `syncWithSystem` reads the appearance itself and
        // does nothing when it already matches — so a second, later trigger
        // costs nothing and covers the case where KVO does not fire at all.
        systemNotification = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemAppearanceChanged() }
        }
    }

    private func systemAppearanceChanged() {
        guard appearance == .system else { return }
        syncWithSystem(animated: true)
    }

    private func syncWithSystem(animated: Bool) {
        let wanted: ThemePalette = systemIsLight ? .light : .dark
        guard palette.isLight != wanted.isLight else { return }
        if animated {
            ThemeTransition.fade { self.palette = wanted }
        } else {
            palette = wanted
        }
    }

    private func save() {
        let stored = Stored(palette: palette, appearance: appearance)
        if let data = try? JSONEncoder().encode(stored) {
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
            // Every other agent mark, held to the same bar. Without these the
            // contrast test could not see the marks that needed it most.
            for (markName, mark) in [
                ("gemini", gemini ?? Self.defaultGemini),
                ("opencode", opencode ?? Self.defaultOpenCode),
                ("grok", grok ?? Self.defaultGrok),
                ("cursor", cursor ?? Self.defaultCursor),
                ("amp", amp ?? Self.defaultAmp),
            ] {
                pairs.append(.init(
                    label: "\(markName) on \(name)", foreground: mark, background: surface,
                    minimum: Self.minimumSecondaryTextContrast
                ))
            }
            // The highlight and the four meanings are used as text and as icons
            // on every surface, so they are held to the same bar as the marks.
            for (meaning, color) in [
                ("highlight", highlight), ("ok", ok), ("warn", warn),
                ("danger", danger), ("info", info),
            ] {
                pairs.append(.init(
                    label: "\(meaning) on \(name)", foreground: color, background: surface,
                    minimum: Self.minimumSecondaryTextContrast
                ))
            }
        }
        // A filled highlight has to carry readable text — this is the pair a
        // primary button is made of.
        pairs.append(.init(
            label: "text on highlight fill", foreground: textOnHighlight,
            background: highlight, minimum: Self.minimumTextContrast
        ))
        // The pressed state is held to the secondary bar rather than the text
        // bar: it exists only while a mouse button is down, between two states
        // that both clear 4.5, and the shipped dark pair measures 4.34 there.
        // Raising it would mean changing a colour the palette's author chose.
        pairs.append(.init(
            label: "text on active highlight fill", foreground: textOnHighlight,
            background: highlightActive, minimum: Self.minimumSecondaryTextContrast
        ))
        pairs.append(.init(
            label: "highlight on its muted surface", foreground: highlight,
            background: highlightMuted, minimum: Self.minimumSecondaryTextContrast
        ))
        pairs.append(.init(
            label: "highlight border on bg", foreground: highlightBorder, background: bg,
            minimum: Self.minimumBorderContrast
        ))
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
