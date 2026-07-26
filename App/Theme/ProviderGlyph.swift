import SwiftUI

/// The agent marks: each product's own logo, from the vector assets in
/// `Assets.xcassets`, tinted with that product's colour.
///
/// Icon-font glyphs stood in for these before — a generic asterisk for Claude —
/// and they carried the font's stroke weight, tuned for 16pt UI icons rather
/// than for a brand mark. The assets keep their vector representation, so one
/// file serves every size the app draws them at, and they are template images,
/// so the colour comes from the theme rather than from the file.
struct ProviderMark: View {
    let provider: AgentProvider
    var size: CGFloat = 13

    private var assetName: String? {
        switch provider {
        case .claude: "ProviderMarkClaude"
        case .codex: "ProviderMarkCodex"
        // A shell has no logo; the icon font's chevron-and-underscore says it.
        case .terminal: nil
        }
    }

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .renderingMode(.template)
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
