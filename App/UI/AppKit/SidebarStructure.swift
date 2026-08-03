import Foundation

/// What a sidebar row stands for. Rows hold ids rather than records so a
/// renamed session or a new status re-renders from the store instead of needing
/// the outline view to be told about it.
enum SidebarItem: Equatable {
    case project(UUID)
    case group(UUID)
    case session(UUID)

    /// Stable outline-view identity. Prefixed because a group and a session can
    /// never collide, but reading `"s:…"` in a log is worth more than the
    /// guarantee.
    var nodeID: String {
        switch self {
        case .project(let id): return "p:\(id.uuidString)"
        case .group(let id): return "g:\(id.uuidString)"
        case .session(let id): return "s:\(id.uuidString)"
        }
    }
}

/// The sidebar's tree, as ids only.
///
/// Pure so the shape of the tree — and whether a store change actually changed
/// it — is testable without a window server, and so the outline view can reload
/// on structure changes only, leaving status ticks to the hosted SwiftUI rows.
struct SidebarStructure: Equatable {
    /// A session and the sessions it spawned.
    ///
    /// An agent can create child sessions through the control plane, and a child
    /// is a real session with its own terminal — so it belongs under the session
    /// that asked for it rather than beside it in a flat list, where nothing
    /// says which agent is doing the work and which one is waiting.
    struct SessionNode: Equatable {
        let id: UUID
        var children: [SessionNode] = []
    }

    struct Group: Equatable {
        let id: UUID
        let sessions: [SessionNode]
    }

    struct Project: Equatable {
        let id: UUID
        let groups: [Group]
        let ungrouped: [SessionNode]
    }

    var projects: [Project] = []

    static func build(
        projectIDs: [UUID],
        groups: (UUID) -> [UUID],
        sessions: (UUID) -> [(id: UUID, groupID: UUID?, parentID: UUID?)]
    ) -> SidebarStructure {
        SidebarStructure(projects: projectIDs.map { projectID in
            let records = sessions(projectID)
            let groupIDs = groups(projectID)
            let knownGroups = Set(groupIDs)
            let nesting = Nesting(records: records)

            // A child is placed by its parent, never by its own group: it is
            // drawn inside the parent's row, and honouring its group as well
            // would draw it twice.
            let roots = records.filter { nesting.isRoot($0.id) }
            func node(_ id: UUID) -> SessionNode {
                SessionNode(id: id, children: nesting.children(of: id).map(node))
            }

            return Project(
                id: projectID,
                groups: groupIDs.map { groupID in
                    Group(
                        id: groupID,
                        sessions: roots.filter { $0.groupID == groupID }.map { node($0.id) }
                    )
                },
                // A session whose group was deleted from under it still has to
                // appear somewhere, so anything not in a live group counts as
                // ungrouped rather than vanishing.
                ungrouped: roots
                    .filter { $0.groupID.map { !knownGroups.contains($0) } ?? true }
                    .map { node($0.id) }
            )
        })
    }

    /// Resolves parent links into a tree within one project.
    ///
    /// Two things can go wrong and neither may lose a session: a parent that is
    /// not in this project (it was moved, or ended and was swept), and a cycle
    /// in the links. Both make the session a root, so it is drawn at the top
    /// level instead of disappearing into a branch that is never reached.
    private struct Nesting {
        private let childrenByParent: [UUID: [UUID]]
        private let rootIDs: Set<UUID>

        init(records: [(id: UUID, groupID: UUID?, parentID: UUID?)]) {
            let present = Set(records.map(\.id))
            let parentOf = Dictionary(
                records.compactMap { record in
                    record.parentID.map { (record.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )

            func reachesARoot(from id: UUID) -> Bool {
                var seen: Set<UUID> = [id]
                var current = id
                while let parent = parentOf[current] {
                    guard present.contains(parent) else { return true }
                    guard seen.insert(parent).inserted else { return false }
                    current = parent
                }
                return true
            }

            var roots: Set<UUID> = []
            var byParent: [UUID: [UUID]] = [:]
            for record in records {
                guard let parent = record.parentID,
                      present.contains(parent),
                      reachesARoot(from: record.id) else {
                    roots.insert(record.id)
                    continue
                }
                byParent[parent, default: []].append(record.id)
            }
            childrenByParent = byParent
            rootIDs = roots
        }

        func isRoot(_ id: UUID) -> Bool { rootIDs.contains(id) }
        func children(of id: UUID) -> [UUID] { childrenByParent[id] ?? [] }
    }

    /// How deep a row sits: a project is 0, its groups and loose sessions are 1,
    /// a session inside a group is 2. Rows indent themselves by this rather than
    /// by asking the outline view, so a row is measured at the same width it is
    /// drawn at.
    func depth(of item: SidebarItem) -> Int {
        switch item {
        case .project:
            return 0
        case .group:
            return 1
        case .session(let id):
            for project in projects {
                for group in project.groups {
                    if let nested = Self.depth(of: id, in: group.sessions) { return 2 + nested }
                }
                if let nested = Self.depth(of: id, in: project.ungrouped) { return 1 + nested }
            }
            return 1
        }
    }

    /// How far below the given roots a session sits, or nil when it is not in
    /// this branch at all.
    private static func depth(of id: UUID, in nodes: [SessionNode]) -> Int? {
        for node in nodes {
            if node.id == id { return 0 }
            if let found = depth(of: id, in: node.children) { return found + 1 }
        }
        return nil
    }

    /// True when this session was spawned by another one, so a row can say so.
    func isChild(sessionID: UUID) -> Bool {
        parent(ofSession: sessionID) != nil
    }

    /// The session that spawned this one, if any.
    func parent(ofSession id: UUID) -> UUID? {
        for project in projects {
            for group in project.groups {
                if let found = Self.parent(of: id, in: group.sessions) { return found }
            }
            if let found = Self.parent(of: id, in: project.ungrouped) { return found }
        }
        return nil
    }

    private static func parent(of id: UUID, in nodes: [SessionNode], under: UUID? = nil) -> UUID? {
        for node in nodes {
            if node.id == id { return under }
            if let found = parent(of: id, in: node.children, under: node.id) { return found }
        }
        return nil
    }

    /// Every session in a branch, parents before their children.
    static func flatten(_ nodes: [SessionNode]) -> [UUID] {
        nodes.flatMap { [$0.id] + flatten($0.children) }
    }

    /// Whether this project shows any children at all — a project with none has
    /// no disclosure triangle.
    func hasChildren(projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        return !project.groups.isEmpty || !project.ungrouped.isEmpty
    }

    /// The context a drop needs: who owns which group and session.
    var dropContext: SidebarDropContext {
        var context = SidebarDropContext(projectIDs: projects.map(\.id))
        for project in projects {
            for group in project.groups {
                context.projectOfGroup[group.id] = project.id
                // Children too: a nested session is still droppable, and one
                // missing from this map reads as belonging to no project.
                for session in Self.flatten(group.sessions) {
                    context.projectOfSession[session] = project.id
                }
            }
            for session in Self.flatten(project.ungrouped) {
                context.projectOfSession[session] = project.id
            }
        }
        return context
    }
}
