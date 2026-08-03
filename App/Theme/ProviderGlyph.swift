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
struct ProviderMark: View {
    let provider: AgentProvider
    var size: CGFloat = 13

    private var mark: (asset: String, isTemplate: Bool)? {
        switch provider {
        case .claude: ("ProviderMarkClaude", true)
        case .codex: ("ProviderMarkCodex", true)
        case .gemini: ("ProviderMarkGemini", false)
        // A shell has no logo; the icon font's chevron-and-underscore says it.
        case .terminal: nil
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
                TablerIcon(name: "terminal-2", size: size, color: provider.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
