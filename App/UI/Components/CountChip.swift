import SwiftUI

/// A small tally: a word and a number, or just a number.
///
/// Its whole job is to be readable at a glance and quiet when it has nothing to
/// say. A count of zero is drawn muted whatever its colour would be — a red
/// `0 failed` shouts about the absence of a problem — and the colour comes back
/// the moment the number does.
struct CountChip: View {
    let label: String?
    let count: Int
    var tint: Color = Theme.textDim
    /// Filled and outlined when this is the chip in force.
    var isSelected = false
    /// Set when the chip is a control; nil draws it as a label.
    var action: (() -> Void)?
    var identifier: String?

    private var isMuted: Bool { count == 0 && !isSelected }
    private var foreground: Color { isMuted ? Theme.textFaint : tint }

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            chip.accessibilityIdentifier(identifier ?? "")
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(foreground)
            if let label {
                Text(label).foregroundStyle(isMuted ? Theme.textFaint : foreground.opacity(0.9))
            }
        }
        .font(Theme.mono(.small, isSelected ? .semibold : .regular))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            isSelected ? tint.opacity(0.16) : Theme.statusSurface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(isSelected ? tint.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Progress as a fraction — `3/15`. Its own type because a fraction is not two
/// counts: the pair only means anything read together, and it is the one thing
/// on a summary bar that changes while you are looking at it.
struct ProgressChip: View {
    let done: Int
    let total: Int
    /// Boxed while the work is in flight, plain once it has stopped.
    var isLive = false

    /// A total of zero means it is not known yet — a run in flight has no idea
    /// how many tests it is about to report, and `3/0` would be a lie where
    /// `3` is a fact.
    private var text: String { total > 0 ? "\(done)/\(total)" : "\(done)" }

    var body: some View {
        Text(text)
            .font(Theme.mono(.small, isLive ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isLive ? Theme.text : Theme.textDim)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                isLive ? Theme.panelHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(isLive ? Theme.border : .clear, lineWidth: 1)
            )
    }
}
