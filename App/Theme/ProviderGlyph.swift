import SwiftUI

/// The agent marks: each product's own logo, from the vector assets in
/// `Assets.xcassets`.
///
/// Icon-font glyphs stood in for these before — a generic asterisk for Claude —
/// and they carried the font's stroke weight, tuned for 16pt UI icons rather
/// than for a brand mark. The assets keep their vector representation, so one
/// file serves every size the app draws them at.
///
/// Claude's and Codex's marks are single-colour, so they ship as templates and
/// take the theme's tint. Gemini's is a four-colour gradient: tinting it would
/// throw away the thing that makes it recognisable, so it is drawn in its own
/// colours. That is the whole reason a mark carries its own rendering mode
/// rather than the view assuming one.
extension ExtensionAgentID {
    /// The colour that stands for this agent in dots, badges and charts.
    ///
    /// The three launch providers use the theme's own tokens, so a palette
    /// change carries through. The rest are fixed here — and the monochrome
    /// ones (Cursor, OpenCode) are deliberately muted, because those brands
    /// present themselves in black and white; painting them a hue they never
    /// chose would be a lie the UI repeats everywhere.
    ///
    /// Amp's brand green is `2C3A2A`, which is darker than this app's own
    /// panels: used literally it disappeared into the surface behind it. The
    /// value here keeps Amp's hue and lifts only the lightness, which is the
    /// smallest change that leaves a 7pt status dot actually visible.
    // `Theme` reads the shared palette, which lives on the main actor.
    @MainActor var brandColor: Color {
        switch self {
        case .claudeCode: Theme.claude
        case .codex: Theme.codex
        case .geminiCLI: Theme.gemini
        case .cursor: Theme.cursor
        case .amp: Theme.amp
        case .opencode: Theme.opencode
        case .grok: Theme.grok
        case .hermes: Theme.hermes
        }
    }
}

/// `ProviderMark`'s counterpart for the wider agent list the Extensions system
/// knows: every agent ships a real brand mark, tinted with its own colour.
/// The icon-font fallback stays for an agent added before its mark is.
struct AgentMark: View {
    let agent: ExtensionAgentID
    var size: CGFloat = 13

    /// Every mark occupies this multiple of `size` in width, whatever its own
    /// proportions. A list of agents reads down the left edge, so the labels
    /// have to start at the same x — a wide mark that pushed its own row's
    /// text across would be more distracting than the extra whitespace a
    /// square mark carries here.
    private static let slotAspect: CGFloat = 1.55

    /// `aspect` is the mark's own width÷height; `heightFactor` trims a mark
    /// that would otherwise outweigh its neighbours.
    ///
    /// Not every brand mark is square: Amp's is the `amp` wordmark at 281×144.
    /// Fitting that into a square box renders it at half the height of every
    /// neighbour, which reads as "the icon is broken" rather than "the logo is
    /// wide". Drawn at full height it has the opposite problem — a wordmark
    /// spread over twice the width carries far more ink than a glyph — so it
    /// is set slightly shorter to match their weight rather than their height.
    /// Non-optional on purpose: every agent ships a mark, and a new case added
    /// without one fails this switch to compile rather than falling back to a
    /// generic robot glyph nobody would notice was wrong.
    private var mark: (asset: String, isTemplate: Bool, aspect: CGFloat, heightFactor: CGFloat) {
        switch agent {
        case .claudeCode: ("ProviderMarkClaude", true, 1, 1)
        case .codex: ("ProviderMarkCodex", true, 1, 1)
        case .geminiCLI: ("ProviderMarkGemini", false, 1, 1)
        case .cursor: ("ProviderMarkCursor", true, 1, 1)
        case .opencode: ("ProviderMarkOpenCode", true, 1, 1)
        case .amp: ("ProviderMarkAmp", true, 281.0 / 144.0, 0.78)
        case .grok: ("ProviderMarkGrok", true, 1, 1)
        // Drawn here rather than taken from the product: Nous ships no
        // vector mark for Hermes — its favicon is a text glyph and its
        // logo is a 1772px illustration that is unreadable at 13pt. This
        // is an original winged-staff glyph standing in until there is a
        // real mark to replace it with.
        case .hermes: ("ProviderMarkHermes", true, 1, 1)
        }
    }

    var body: some View {
        let height = size * mark.heightFactor
        Image(mark.asset)
            .renderingMode(mark.isTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(agent.brandColor)
            .frame(width: height * mark.aspect, height: height)
            .frame(width: size * Self.slotAspect, height: size)
            .accessibilityHidden(true)
    }
}

struct ProviderMark: View {
    let provider: AgentProvider
    var size: CGFloat = 13

    private var mark: (asset: String, isTemplate: Bool)? {
        switch provider {
        case .claude: ("ProviderMarkClaude", true)
        case .codex: ("ProviderMarkCodex", true)
        case .gemini: ("ProviderMarkGemini", false)
        case .opencode: ("ProviderMarkOpenCode", true)
        case .grok: ("ProviderMarkGrok", true)
        case .hermes: ("ProviderMarkHermes", true)
        case .cursor: ("ProviderMarkCursor", true)
        // A shell has no logo; the icon font's chevron-and-underscore says it.
        case .terminal, .uncoil: nil
        }
    }

    var body: some View {
        Group {
            if let mark {
                Image(mark.asset)
                    .renderingMode(mark.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
            } else {
                TablerIcon(name: provider == .uncoil ? "sparkles" : "terminal-2", size: size, color: provider.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
