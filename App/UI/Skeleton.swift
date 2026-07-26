import SwiftUI

/// A placeholder for content that has not arrived yet.
///
/// A spinner says "something is happening"; a skeleton says "this is what is
/// coming, and roughly how much of it" — which is what a panel that is about to
/// hold four rows of git status should say. Shaped from `Theme` so it reads as
/// the same surface it is standing in for.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 11
    var cornerRadius: CGFloat = 4

    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.panelActive)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                // A slow sweep rather than a pulse: it reads as loading without
                // pulling the eye away from whatever has already arrived.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Theme.panelHover.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: shimmer ? 220 : -220)
                    .mask(RoundedRectangle(cornerRadius: cornerRadius))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onAppear {
                guard let animation = uncoilAnimation(
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: false)
                ) else { return }
                withAnimation(animation) { shimmer = true }
            }
            .accessibilityHidden(true)
    }
}

/// A stack of placeholder rows, with the last one short so the block does not
/// read as a solid slab.
struct SkeletonRows: View {
    var count: Int = 3
    var rowHeight: CGFloat = 11
    var spacing: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<max(1, count), id: \.self) { index in
                SkeletonBlock(
                    width: index == count - 1 ? 120 : nil,
                    height: rowHeight
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// A placeholder row shaped like a session or file row: a small square, a line
/// of text, a short trailing value.
struct SkeletonListRows: View {
    var count: Int = 3

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<max(1, count), id: \.self) { index in
                HStack(spacing: 9) {
                    SkeletonBlock(width: 13, height: 13, cornerRadius: 3)
                    SkeletonBlock(width: index.isMultiple(of: 2) ? 150 : 110, height: 11)
                    Spacer(minLength: 8)
                    SkeletonBlock(width: 44, height: 9)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
