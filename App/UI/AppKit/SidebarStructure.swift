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
    struct Group: Equatable {
        let id: UUID
        let sessions: [UUID]
    }

    struct Project: Equatable {
        let id: UUID
        let groups: [Group]
        let ungrouped: [UUID]
    }

    var projects: [Project] = []

    static func build(
        projectIDs: [UUID],
        groups: (UUID) -> [UUID],
        sessions: (UUID) -> [(id: UUID, groupID: UUID?)]
    ) -> SidebarStructure {
        SidebarStructure(projects: projectIDs.map { projectID in
            let records = sessions(projectID)
            let groupIDs = groups(projectID)
            let knownGroups = Set(groupIDs)
            return Project(
                id: projectID,
                groups: groupIDs.map { groupID in
                    Group(
                        id: groupID,
                        sessions: records.filter { $0.groupID == groupID }.map(\.id)
                    )
                },
                // A session whose group was deleted from under it still has to
                // appear somewhere, so anything not in a live group counts as
                // ungrouped rather than vanishing.
                ungrouped: records
                    .filter { $0.groupID.map { !knownGroups.contains($0) } ?? true }
                    .map(\.id)
            )
        })
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
            let grouped = projects.contains { project in
                project.groups.contains { $0.sessions.contains(id) }
            }
            return grouped ? 2 : 1
        }
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
                for session in group.sessions {
                    context.projectOfSession[session] = project.id
                }
            }
            for session in project.ungrouped {
                context.projectOfSession[session] = project.id
            }
        }
        return context
    }
}
