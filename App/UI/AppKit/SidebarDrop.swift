import Foundation

/// What is being dragged in the sidebar.
///
/// The wire format is deliberately the one the SwiftUI sidebar already wrote —
/// `project:<uuid>` for a project, comma-joined UUIDs for sessions — because
/// other screens (`SessionDetailView`, the kanban columns) read these same
/// strings off the pasteboard and must keep working.
enum SidebarDragPayload: Equatable {
    case project(UUID)
    case sessions([UUID])

    static let projectPrefix = "project:"

    static func parse(_ string: String) -> SidebarDragPayload? {
        if string.hasPrefix(projectPrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(projectPrefix.count)))
            else { return nil }
            return .project(id)
        }
        let ids = string.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        return ids.isEmpty ? nil : .sessions(ids)
    }

    var pasteboardString: String {
        switch self {
        case .project(let id):
            return Self.projectPrefix + id.uuidString
        case .sessions(let ids):
            return ids.map(\.uuidString).sorted().joined(separator: ",")
        }
    }
}

/// Where the outline view says the drag currently is.
enum SidebarDropParent: Equatable {
    case root
    case project(UUID)
    case group(UUID)
}

/// The store mutation a drop should perform, resolved before anything is
/// written. Keeping it a value means the rule is unit-testable without a
/// window server — the same reason `PopoutDragDecision` exists.
enum SidebarDropPlan: Equatable {
    case reorderProjects(dragged: UUID, toIndex: Int)
    case moveSessions(ids: [UUID], projectID: UUID, groupID: UUID?, toIndex: Int)
    case refuse
}

/// The slice of sidebar structure a drop decision needs.
struct SidebarDropContext: Equatable {
    /// Projects in display order.
    var projectIDs: [UUID] = []
    /// Which project a group belongs to.
    var projectOfGroup: [UUID: UUID] = [:]
    /// Which project a session belongs to.
    var projectOfSession: [UUID: UUID] = [:]
}

enum SidebarDropResolver {
    /// Resolves a hovering drag into the mutation it would perform.
    ///
    /// `childIndex` is the outline view's proposed child index within `parent`,
    /// with `-1` meaning "on the parent itself" (append).
    static func plan(
        payload: SidebarDragPayload,
        parent: SidebarDropParent,
        childIndex: Int,
        context: SidebarDropContext
    ) -> SidebarDropPlan {
        switch payload {
        case .project(let draggedID):
            // Projects only reorder, and only at the root: a project dropped
            // into another project's session list means nothing.
            guard case .root = parent,
                  context.projectIDs.contains(draggedID) else { return .refuse }
            let target = childIndex < 0 ? context.projectIDs.count : childIndex
            return .reorderProjects(dragged: draggedID, toIndex: target)

        case .sessions(let ids):
            let known = ids.filter { context.projectOfSession[$0] != nil }
            guard !known.isEmpty else { return .refuse }
            // Sessions belong to their project; a cross-project drop would have
            // to re-parent worktrees and accounts, so it is refused rather than
            // half-applied.
            let owners = Set(known.compactMap { context.projectOfSession[$0] })
            guard owners.count == 1, let owner = owners.first else { return .refuse }

            switch parent {
            case .root:
                return .refuse
            case .project(let projectID):
                guard projectID == owner else { return .refuse }
                return .moveSessions(
                    ids: known, projectID: projectID, groupID: nil, toIndex: childIndex
                )
            case .group(let groupID):
                guard context.projectOfGroup[groupID] == owner else { return .refuse }
                return .moveSessions(
                    ids: known, projectID: owner, groupID: groupID, toIndex: childIndex
                )
            }
        }
    }
}

/// Pure ordering arithmetic for a sidebar drop.
///
/// Session order is stored project-wide (`sortIndex` on every record) while the
/// sidebar shows sessions split into groups. So an insertion expressed as "third
/// child of this group" has to be translated into one project-wide sequence.
enum SidebarReorder {
    /// Moves `dragged` to `index` within `order`.
    ///
    /// `index` is interpreted against the list *before* removal — the
    /// convention `NSOutlineView` uses — so dropping an item just below itself
    /// is a no-op rather than an off-by-one.
    static func moved<ID: Hashable>(_ order: [ID], dragged: ID, toIndex index: Int) -> [ID] {
        guard let from = order.firstIndex(of: dragged) else { return order }
        var result = order
        result.remove(at: from)
        let clamped = max(0, min(index, order.count))
        let to = from < clamped ? clamped - 1 : clamped
        result.insert(dragged, at: max(0, min(to, result.count)))
        return result
    }

    /// Places `dragged` inside a sibling list at `index`, expressed as a new
    /// order for the whole enclosing sequence.
    ///
    /// - Parameters:
    ///   - order: every id in the enclosing sequence, in display order.
    ///   - siblings: the ids shown under the drop parent, before the drop.
    ///   - dragged: the ids being moved, in the order they should end up.
    ///   - index: child index within `siblings`; `-1` appends.
    static func moved<ID: Hashable>(
        _ order: [ID],
        siblings: [ID],
        dragged: [ID],
        toIndex index: Int
    ) -> [ID] {
        let moving = dragged.filter { order.contains($0) }
        guard !moving.isEmpty else { return order }
        let movingSet = Set(moving)

        // The row the drop should land in front of, skipping any row that is
        // itself being dragged (it is about to leave that position).
        var anchor: ID?
        if index >= 0, index < siblings.count {
            anchor = siblings[index...].first { !movingSet.contains($0) }
        }

        var remaining = order.filter { !movingSet.contains($0) }
        let insertAt: Int
        if let anchor, let position = remaining.firstIndex(of: anchor) {
            insertAt = position
        } else if let lastSibling = siblings.last(where: { !movingSet.contains($0) }),
                  let position = remaining.firstIndex(of: lastSibling) {
            // Appending to a non-empty section: land after its last row rather
            // than at the very end of the project.
            insertAt = position + 1
        } else {
            insertAt = remaining.count
        }
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}
