import AppKit

/// An item handed to `NSOutlineView`, wrapping a value-type payload.
///
/// `NSOutlineView` identifies rows by object identity *or* `isEqual`, and it
/// keeps expansion state keyed by that identity. Uncoil's models are structs
/// rebuilt on every store change, so a fresh wrapper is created on each reload
/// and equality is defined on the stable `id` instead of on the instance. That
/// is what lets a project stay expanded across a session status tick.
///
/// Children can be supplied up front (the sidebar knows its whole tree) or
/// loaded on first access (the file tree reads a directory only once the row is
/// expanded).
final class OutlineNode<Payload>: NSObject {
    /// Stable identity — equal ids mean "the same row" to the outline view.
    let id: String
    let payload: Payload

    /// Whether the outline view should offer a disclosure triangle. Kept
    /// separate from `children.isEmpty` so a lazy node need not be read to know
    /// it is a container.
    let isGroup: Bool

    private let loadChildren: () -> [OutlineNode<Payload>]
    private var cachedChildren: [OutlineNode<Payload>]?

    init(
        id: String,
        payload: Payload,
        isGroup: Bool,
        children: @autoclosure @escaping () -> [OutlineNode<Payload>] = []
    ) {
        self.id = id
        self.payload = payload
        self.isGroup = isGroup
        self.loadChildren = children
        super.init()
    }

    var children: [OutlineNode<Payload>] {
        if let cachedChildren { return cachedChildren }
        let loaded = loadChildren()
        cachedChildren = loaded
        return loaded
    }

    /// Adopts the children already read by an equal node from a previous
    /// reload, so a lazy tree does not re-read the disk on every refresh.
    func adoptCachedChildren(from other: OutlineNode<Payload>) {
        guard let existing = other.cachedChildren else { return }
        cachedChildren = existing
    }

    func invalidateChildren() {
        cachedChildren = nil
    }

    /// Depth-first walk including `self`.
    func flattened() -> [OutlineNode<Payload>] {
        [self] + children.flatMap { $0.flattened() }
    }

    func node(withID target: String) -> OutlineNode<Payload>? {
        if id == target { return self }
        for child in children {
            if let found = child.node(withID: target) { return found }
        }
        return nil
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? OutlineNode<Payload> else { return false }
        return other.id == id
    }

    override var hash: Int { id.hashValue }
    override var description: String { "OutlineNode(\(id))" }
}
