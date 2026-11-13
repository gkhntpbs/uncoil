import SwiftUI

/// Reports how wide a view actually got, so a header can drop labels before it
/// starts wrapping them.
///
/// macOS 14 is the floor, so `onGeometryChange` is not available — a background
/// `GeometryReader` feeding a preference is the portable way to ask.
private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Calls `onChange` with this view's width whenever it changes.
    func measureWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: WidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(WidthPreferenceKey.self) { onChange($0) }
    }
}

/// Sizes its single child to its natural width, but never wider than `max` —
/// and narrower still when the parent offers less.
///
/// `.frame(maxWidth:)` cannot do this: offered more room, a flexible frame
/// grows to the cap even around a two-word label, so a capsule background
/// drawn behind it would stretch. This keeps short text snug and makes long
/// text truncate at the cap.
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        let width = Swift.min(ideal.width, max, proposal.width ?? .infinity)
        let fitted = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    /// Natural width, capped at `max`. See `CappedWidth`.
    func cappedWidth(_ max: CGFloat) -> some View {
        CappedWidth(max: max) { self }
    }
}
