import SwiftUI

/// "This is the branch the work lands on" — the project header's git chip.
///
/// Sized like the control blocks it sits between: 22pt of content inside a 3pt
/// inset, one 8pt-radius bordered box. It hugs its text rather than taking a
/// flexible width, because a flexible frame in the header stretched the chip
/// across whatever room was left.
struct BranchBadge: View {
    let branch: String
    /// Longest name shown before it is cut; a chip is not the place to read a
    /// forty-character branch.
    var maximumCharacters = 22

    var body: some View {
        HStack(spacing: 5) {
            TablerIcon(name: "git-branch", size: 12, color: Theme.textFaint)
            Text(shortened)
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .padding(3)
        .fixedSize()
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
        )
        .help("Aktif dal: \(branch)")
        .accessibilityIdentifier("branch.badge")
    }

    private var shortened: String {
        branch.count > maximumCharacters
            ? branch.prefix(maximumCharacters - 1) + "…"
            : branch
    }
}
