import Foundation

/// What a sidebar row stands for. Rows hold ids rather than records so a
/// renamed session or a new status re-renders from the store instead of needing
/// the outline view to be told about it.
enum SidebarItem: Equatable {
    case folder(UUID)
    case project(UUID)
    case group(UUID)
    case session(UUID)
    /// The row closing a list that pages its sessions: "Load more" while it
    /// holds some back, "Show less" once it shows more than its first page.
    /// Carries the id of the list it extends: a group's, or the project's for
    /// its ungrouped sessions — the two never collide, both being UUIDs minted
    /// for different things.
    case more(UUID)

    /// A row that is drawn but holds nothing: a drop "on" it means "in front
    /// of it", the way it does on a session.
    var isLeafRow: Bool {
        switch self {
        case .session, .more: true
        case .folder, .project, .group: false
        }
    }

    /// Stable outline-view identity. Prefixed because a group and a session can
    /// never collide, but reading `"s:…"` in a log is worth more than the
    /// guarantee.
    var nodeID: String {
        switch self {
        case .folder(let id): return "f:\(id.uuidString)"
        case .project(let id): return "p:\(id.uuidString)"
        case .group(let id): return "g:\(id.uuidString)"
        case .session(let id): return "s:\(id.uuidString)"
        case .more(let id): return "m:\(id.uuidString)"
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
        /// Sessions held back behind "Load more". Zero when the list is whole.
        var hiddenCount = 0
        /// More than the first page is showing, so "Show less" can fold it back.
        var canShowLess = false
    }

    struct Project: Equatable {
        let id: UUID
        let groups: [Group]
        let ungrouped: [SessionNode]
        /// Ungrouped sessions held back behind "Load more".
        var hiddenCount = 0
        /// More than the first page of ungrouped sessions is showing.
        var canShowLess = false
    }

    var projects: [Project] = []
    var folders: [ProjectFolder] = []
    var folderOfProject: [UUID: UUID] = [:]
    var rootItems: [SidebarItem] = []

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
        case .folder: return 0
        case .project(let id):
            return folderOfProject[id] == nil ? 0 : 1
        case .group(let id):
            let owner = projects.first { $0.groups.contains { $0.id == id } }
            return 1 + (owner.flatMap { folderOfProject[$0.id] } == nil ? 0 : 1)
        case .more(let id):
            // Sits at the depth of the sessions it continues.
            if let owner = projects.first(where: { $0.groups.contains { $0.id == id } }) {
                return 2 + (folderOfProject[owner.id] == nil ? 0 : 1)
            }
            return 1 + (folderOfProject[id] == nil ? 0 : 1)
        case .session(let id):
            for project in projects {
                for group in project.groups {
                    if let nested = Self.depth(of: id, in: group.sessions) { return 2 + nested + (folderOfProject[project.id] == nil ? 0 : 1) }
                }
                if let nested = Self.depth(of: id, in: project.ungrouped) { return 1 + nested + (folderOfProject[project.id] == nil ? 0 : 1) }
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

extension SidebarStructure {
    /// Each list cut down to its `limit` most recently used sessions, `limit`
    /// more per "Load more" already pressed for it.
    ///
    /// A project that has collected a hundred sessions used to draw all of
    /// them, and the projects under it were a long scroll away. The cut is per
    /// list — a project's ungrouped sessions and each of its groups — because
    /// a group is a section of its own: sharing one budget across them would
    /// leave a group's header standing over nothing.
    ///
    /// Which sessions make the cut is decided by `rank`, not by position: a
    /// new session is stamped at the *end* of its list so rows never move on
    /// their own, so "the first five" would be the five oldest. The sessions
    /// shown keep their place in the user's order; only the choice of which to
    /// show follows recency.
    ///
    /// Only top-level sessions count. A sub-agent rides with its parent — a
    /// shown session shows its whole branch, and a branch ranks by its most
    /// recent member, so a parent whose sub-agent is busy stays in view.
    ///
    /// The session open on the right is never held back, however far down the
    /// ranking it sits: a sidebar with no row for what fills the window is the
    /// problem `revealing` exists to prevent, and paging must not bring it back.
    ///
    /// - Parameters:
    ///   - limit: sessions per page; nil shows every session.
    ///   - pages: extra pages already loaded, by list id (group or project).
    ///   - rank: how recently a session was used; later ranks higher. A pinned
    ///     session answers `.distantFuture`, so it always makes the cut.
    func paged(
        limit: Int?,
        pages: [UUID: Int],
        keeping sessionID: UUID?,
        rank: (UUID) -> Date
    ) -> SidebarStructure {
        guard let limit, limit > 0 else { return self }
        func branchRank(_ node: SessionNode) -> Date {
            node.children.map(branchRank).reduce(rank(node.id), max)
        }
        func cut(
            _ nodes: [SessionNode], listID: UUID
        ) -> (shown: [SessionNode], hidden: Int, canShowLess: Bool) {
            let budget = limit * (1 + max(0, pages[listID] ?? 0))
            // Only a list that is longer than one page has anything to fold.
            let canShowLess = budget > limit && nodes.count > limit
            guard nodes.count > budget else { return (nodes, 0, canShowLess) }
            let ranks: [Date] = nodes.map(branchRank)
            // Ties keep list order, so the same store always cuts the same way.
            let byRecency: [Int] = nodes.indices.sorted { left, right in
                ranks[left] != ranks[right] ? ranks[left] > ranks[right] : left < right
            }
            let chosen = Set(byRecency.prefix(budget))
            var shown: [SessionNode] = []
            for (index, node) in nodes.enumerated() {
                let isOpen = sessionID.map { Self.contains($0, in: [node]) } ?? false
                if chosen.contains(index) || isOpen { shown.append(node) }
            }
            return (shown, nodes.count - shown.count, canShowLess)
        }
        return SidebarStructure(projects: projects.map { project in
            let ungrouped = cut(project.ungrouped, listID: project.id)
            return Project(
                id: project.id,
                groups: project.groups.map { group in
                    let sessions = cut(group.sessions, listID: group.id)
                    return Group(
                        id: group.id,
                        sessions: sessions.shown,
                        hiddenCount: sessions.hidden,
                        canShowLess: sessions.canShowLess
                    )
                },
                ungrouped: ungrouped.shown,
                hiddenCount: ungrouped.hidden,
                canShowLess: ungrouped.canShowLess
            )
        })
    }

    private static func contains(_ sessionID: UUID, in nodes: [SessionNode]) -> Bool {
        nodes.contains { $0.id == sessionID || contains(sessionID, in: $0.children) }
    }

    /// What a folded project still shows.
    ///
    /// Folding a project used to hide everything under it, including the
    /// session open on the right — so the sidebar could be showing no trace of
    /// the agent filling the rest of the window, and there was no row to click
    /// back to. A collapsed project keeps exactly one child: the session you
    /// are looking at. Everything else stays folded away.
    ///
    /// The session is shown at the top level of the project even when it is a
    /// sub-agent nested three deep — the point is a row that says "this is
    /// where you are", not a reconstruction of the branch it came from.
    func revealing(sessionID: UUID?, inCollapsed collapsed: Set<UUID>) -> SidebarStructure {
        guard !collapsed.isEmpty else { return self }
        return SidebarStructure(projects: projects.map { project in
            guard collapsed.contains(project.id) else { return project }
            let revealed = sessionID.flatMap { id in
                Self.contains(id, in: project) ? SessionNode(id: id) : nil
            }
            return Project(
                id: project.id,
                groups: [],
                ungrouped: revealed.map { [$0] } ?? []
            )
        })
    }

    private static func contains(_ sessionID: UUID, in project: Project) -> Bool {
        func search(_ nodes: [SessionNode]) -> Bool {
            nodes.contains { $0.id == sessionID || search($0.children) }
        }
        return search(project.ungrouped) || project.groups.contains { search($0.sessions) }
    }
}

/// Which folded projects a new session should open.
///
/// A session started in a folded project used to appear as the one row under
/// it — the reveal that keeps the open session visible — with every other
/// session still hidden, so the project looked as if it held only the new one.
/// Starting a session is a reason to look at the project, so it opens.
enum SidebarUnfold {
    /// - Parameters:
    ///   - known: the sessions the sidebar had already seen, or nil before the
    ///     first pass — a launch must not unfold everything that was restored.
    ///   - current: every session now, with its project.
    static func projects(
        known: Set<UUID>?,
        current: [(session: UUID, project: UUID)],
        collapsed: Set<UUID>
    ) -> Set<UUID> {
        guard let known else { return [] }
        return Set(current.filter { !known.contains($0.session) && collapsed.contains($0.project) }
            .map(\.project))
    }
}

/// What a click on a project row does to the sessions under it.
///
/// Pure, because this is the rule that was silently wrong: it was first written
/// against the selection changing, and the case that matters most — folding the
/// project you are already on — changes no selection at all, so it never ran and
/// a folded project had no way back open once the disclosure chevron was gone.
enum ProjectRowClick {
    enum Outcome: Equatable {
        case open
        case fold
        /// Select it and leave what it is holding alone.
        case leaveAlone
    }

    /// A folded project opens, and a project you are already on folds away.
    /// Landing on a project from somewhere else only selects it, so arriving at
    /// a project never hides what it is holding.
    static func outcome(isFolded: Bool, wasAlreadySelected: Bool) -> Outcome {
        if isFolded { return .open }
        return wasAlreadySelected ? .fold : .leaveAlone
    }
}
