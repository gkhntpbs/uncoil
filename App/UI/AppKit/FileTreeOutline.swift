import AppKit
import SwiftUI

/// One entry in the dashboard's file tree.
struct FileTreeEntry: Equatable {
    let url: URL
    let isDirectory: Bool

    var name: String { url.lastPathComponent }
}

/// Reads a directory, folders first, then case-insensitive by name.
///
/// Pure and synchronous on purpose: the outline view only asks for the children
/// of a row the user actually expanded, so this runs once per opened folder
/// rather than on every view rebuild.
enum FileTreeLoader {
    static func entries(in directoryURL: URL) -> [FileTreeEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .map { url in
                FileTreeEntry(
                    url: url,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                        == true
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

/// The dashboard's project file tree.
///
/// An outline view rather than nested lazy stacks: a folder's contents are read
/// when it is expanded instead of on every rebuild of its parent, expansion
/// state lives in the view instead of in a `@State` per row, and the listing no
/// longer needs the 120-entry cap that made the eager version affordable.
struct FileTreeView: View {
    let rootURL: URL
    /// An AppKit view has no intrinsic height to offer SwiftUI, so the outline
    /// view reports how tall its rows actually are and the panel follows —
    /// growing as folders open, up to the same ceiling as before.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        FileTreeOutline(rootURL: rootURL, contentHeight: $contentHeight)
            .frame(height: min(max(contentHeight, 24), 340))
    }
}

private struct FileTreeOutline: NSViewRepresentable {
    let rootURL: URL
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(rootURL: rootURL)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.selectionHighlightStyle = .none
        outlineView.gridStyleMask = []
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.autoresizesOutlineColumn = false
        // The row's own SwiftUI chevron and leading padding are the design, so
        // AppKit contributes neither indentation nor a disclosure triangle.
        outlineView.indentationPerLevel = 0
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        context.coordinator.outlineView = outlineView
        return makeUncoilScrollView(documentView: outlineView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onHeightChange = { height in
            guard abs(height - contentHeight) > 0.5 else { return }
            // Out of this layout pass: reporting a size back into SwiftUI while
            // it is laying out is what makes it complain about a loop.
            DispatchQueue.main.async { contentHeight = height }
        }
        context.coordinator.setRoot(rootURL)
        context.coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: NSOutlineView?
        var onHeightChange: ((CGFloat) -> Void)?
        private var rootURL: URL
        private var root: OutlineNode<FileTreeEntry>
        private let heights = RowHeightCache()

        init(rootURL: URL) {
            self.rootURL = rootURL
            root = Self.makeNode(
                for: FileTreeEntry(url: rootURL, isDirectory: true)
            )
            super.init()
        }

        func setRoot(_ url: URL) {
            guard url != rootURL else { return }
            rootURL = url
            root = Self.makeNode(for: FileTreeEntry(url: url, isDirectory: true))
            outlineView?.reloadData()
            reportHeight()
        }

        /// How tall the visible rows are, so SwiftUI can size the panel.
        func reportHeight() {
            guard let outlineView else { return }
            let rows = outlineView.numberOfRows
            guard rows > 0 else {
                onHeightChange?(24)
                return
            }
            let last = outlineView.rect(ofRow: rows - 1)
            onHeightChange?(last.maxY)
        }

        private static func makeNode(for entry: FileTreeEntry) -> OutlineNode<FileTreeEntry> {
            OutlineNode(
                id: entry.url.path,
                payload: entry,
                isGroup: entry.isDirectory,
                children: FileTreeLoader.entries(in: entry.url).map(makeNode(for:))
            )
        }

        private func node(_ item: Any?) -> OutlineNode<FileTreeEntry> {
            (item as? OutlineNode<FileTreeEntry>) ?? root
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(item).children.count
        }

        func outlineView(
            _ outlineView: NSOutlineView, child index: Int, ofItem item: Any?
        ) -> Any {
            node(item).children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            // Answered from the file's own flag: asking would mean reading the
            // directory just to draw a chevron.
            node(item).payload.isDirectory
        }

        // MARK: Delegate

        func outlineView(
            _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
        ) -> NSView? {
            let node = node(item)
            return dequeueHostingCell(
                from: outlineView,
                identifier: .init("file-row"),
                owner: self,
                content: row(for: node, in: outlineView)
            )
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            PlainTableRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            heights.height(kind: "file-row", width: outlineView.bounds.width) {
                FileTreeRowView(
                    entry: FileTreeEntry(url: URL(fileURLWithPath: "/prototype"), isDirectory: false),
                    depth: 0,
                    isExpanded: false,
                    onActivate: {}
                )
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any
        ) -> Bool {
            false
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            reloadChevron(from: notification)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            reloadChevron(from: notification)
        }

        /// The chevron's rotation is drawn by the row, so the row has to be
        /// rebuilt when its expansion changes — and the panel resized, because
        /// opening a folder is what makes the tree taller.
        private func reloadChevron(from notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] else { return }
            outlineView?.reloadItem(item, reloadChildren: false)
            reportHeight()
        }

        private func row(
            for node: OutlineNode<FileTreeEntry>, in outlineView: NSOutlineView
        ) -> FileTreeRowView {
            FileTreeRowView(
                entry: node.payload,
                depth: max(0, outlineView.level(forItem: node)),
                isExpanded: outlineView.isItemExpanded(node)
            ) { [weak self] in
                self?.activate(node)
            }
        }

        private func activate(_ node: OutlineNode<FileTreeEntry>) {
            guard let outlineView else { return }
            guard node.payload.isDirectory else {
                NSWorkspace.shared.activateFileViewerSelecting([node.payload.url])
                return
            }
            if outlineView.isItemExpanded(node) {
                outlineView.animator().collapseItem(node)
            } else {
                outlineView.animator().expandItem(node)
            }
        }
    }
}

/// A file-tree row. Purely presentational: expansion and virtualisation belong
/// to the outline view, hover and clicks stay SwiftUI.
private struct FileTreeRowView: View {
    let entry: FileTreeEntry
    let depth: Int
    let isExpanded: Bool
    let onActivate: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 6) {
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.isDirectory ? Theme.warn.opacity(0.8) : Theme.textFaint)
                Text(entry.name)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3.5)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
