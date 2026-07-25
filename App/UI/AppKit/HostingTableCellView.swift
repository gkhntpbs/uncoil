import AppKit
import SwiftUI

/// A table/outline cell whose content is a SwiftUI view.
///
/// The point of the AppKit migration is to take over *structure and
/// interaction* — insertion-point drags, real selection, targeted row reloads —
/// without redrawing the design in `draw(_:)`. So each row keeps rendering the
/// same SwiftUI view it always did, hosted inside a reused cell.
///
/// The hosting view is created once per cell and only its `rootView` is swapped
/// on reuse: rebuilding an `NSHostingView` per row defeats the recycling that
/// made the move worthwhile in the first place.
final class HostingTableCellView<Content: View>: NSTableCellView {
    private var hostingView: NSHostingView<Content>?

    /// Replaces the hosted content, installing the hosting view on first use.
    func host(_ content: Content) {
        if let hostingView {
            hostingView.rootView = content
            return
        }
        let view = NSHostingView(rootView: content)
        view.translatesAutoresizingMaskIntoConstraints = false
        // The row's own SwiftUI padding is the layout: the cell must not add
        // any, or every row would shift relative to the current design.
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = view
    }

    /// The size the hosted SwiftUI content wants, for variable row heights.
    func fittingHeight(width: CGFloat) -> CGFloat? {
        guard let hostingView else { return nil }
        // Width first, then measure: a hosted row wraps its text, so its height
        // is only meaningful once it knows how wide the column is.
        hostingView.frame.size.width = width
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    /// AppKit draws no selection or hover background of its own: those are part
    /// of the SwiftUI row design and drawing them twice would double up.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { _ = newValue }
    }
}

/// Dequeues a hosting cell for `identifier`, creating one when the queue is dry.
func dequeueHostingCell<Content: View>(
    from view: NSTableView,
    identifier: NSUserInterfaceItemIdentifier,
    owner: Any?,
    content: Content
) -> HostingTableCellView<Content> {
    let cell = view.makeView(withIdentifier: identifier, owner: owner)
        as? HostingTableCellView<Content>
        ?? {
            let fresh = HostingTableCellView<Content>()
            fresh.identifier = identifier
            return fresh
        }()
    cell.host(content)
    return cell
}

/// A table row view that draws nothing.
///
/// `NSTableRowView` paints a system selection highlight; Uncoil rows paint their
/// own selected/hover surfaces from `Theme`, so the system one has to go or
/// selected rows would turn blue.
final class PlainTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set { _ = newValue }
    }
}

/// A scroll view configured the way every Uncoil list wants it: no background of
/// its own, Uncoil's thin scrollers, no automatic content insets.
func makeUncoilScrollView(documentView: NSView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.verticalScroller = UncoilScroller()
    scrollView.scrollerStyle = .overlay
    scrollView.documentView = documentView
    return scrollView
}
