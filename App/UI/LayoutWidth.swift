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
