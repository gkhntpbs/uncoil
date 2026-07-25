import AppKit
import SwiftUI

/// Measures how tall a hosted SwiftUI row wants to be.
///
/// AppKit asks for row heights before it has a cell to ask, so a prototype is
/// measured once per row kind and cached. Hard-coding the numbers instead would
/// desynchronise the moment a font or padding changed.
enum RowHeight {
    static func measure<Content: View>(_ content: Content, width: CGFloat) -> CGFloat {
        let view = NSHostingView(rootView: content)
        view.frame.size = CGSize(width: max(width, 1), height: 0)
        view.layoutSubtreeIfNeeded()
        return max(1, view.fittingSize.height)
    }
}

/// Per-kind row height cache, invalidated when the available width changes.
final class RowHeightCache {
    private var width: CGFloat = 0
    private var heights: [String: CGFloat] = [:]

    func height<Content: View>(
        kind: String,
        width: CGFloat,
        content: () -> Content
    ) -> CGFloat {
        if width != self.width {
            self.width = width
            heights.removeAll()
        }
        if let cached = heights[kind] { return cached }
        let measured = RowHeight.measure(content(), width: width)
        heights[kind] = measured
        return measured
    }

    func invalidate() {
        heights.removeAll()
    }
}
