import SwiftUI

/// A card with a drawer tucked under it.
///
/// Two surfaces, not one: the head is what the thing *is* — its name, its
/// state, the one button that acts on it — and the drawer underneath is what it
/// *did*, which is longer, changes constantly, and should be able to grow
/// without the head moving. The drawer is inset and sits behind the head's
/// bottom edge, so the pair reads as one object with something folded into it
/// rather than as two stacked panels.
///
/// Generic on purpose. A run, a task, a session, a suite — anything with a
/// headline and a body of detail — can be drawn with this.
struct StackedCard<Head: View, Drawer: View>: View {
    /// How far the drawer is inset on each side.
    var inset: CGFloat = 14
    /// How far it tucks under the head. Enough to overlap the corner radius,
    /// so no seam of background shows between the two.
    var overlap: CGFloat = 10
    @ViewBuilder var head: () -> Head
    @ViewBuilder var drawer: () -> Drawer

    var body: some View {
        VStack(spacing: 0) {
            head()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.roomy)
                .padding(.vertical, Theme.Space.snug)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                // Above the drawer, so the tucked edge is hidden by the head
                // rather than drawn over it.
                .zIndex(1)
            drawer()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, overlap + 4)
                .padding(.bottom, Theme.Space.tight)
                .padding(.horizontal, Theme.Space.tight)
                .background(
                    Theme.bg.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .strokeBorder(Theme.border.opacity(0.7), lineWidth: 1)
                )
                .padding(.horizontal, inset)
                .padding(.top, -overlap)
        }
    }
}

/// A row of a list inside a card: a status mark, a name, and whatever the row
/// needs on its right.
///
/// Rounded and inset rather than full-bleed with a divider under it. Rows that
/// are their own shapes can be tinted — a failure, a selection — without the
/// tint running into the container's corner, and a list of them reads as a set
/// of things rather than as a table.
struct EntityRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// A second line under the subtitle, in its own colour — a failure message,
    /// a warning, a path.
    var detail: String?
    var detailColor: Color?
    var ring: StatusRing.State?
    var tint: Color?
    var isSelected = false
    var identifier: String?
    var onTap: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.snug) {
            if let ring {
                StatusRing(state: ring, size: 17, showsGlyph: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(detailColor ?? Theme.textDim)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.tight)
            trailing()
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(tint?.opacity(0.35) ?? .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var background: Color {
        if let tint {
            return hovering ? tint.opacity(0.24) : tint.opacity(0.14)
        }
        if isSelected { return Theme.panelActive }
        return hovering ? Theme.panelHover : Theme.panel.opacity(0.55)
    }
}

extension EntityRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        detailColor: Color? = nil,
        ring: StatusRing.State? = nil,
        tint: Color? = nil,
        isSelected: Bool = false,
        identifier: String? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.init(
            title: title, subtitle: subtitle, detail: detail, detailColor: detailColor,
            ring: ring, tint: tint, isSelected: isSelected, identifier: identifier,
            onTap: onTap, trailing: { EmptyView() }
        )
    }
}
