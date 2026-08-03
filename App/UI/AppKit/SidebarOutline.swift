import AppKit
import SwiftUI

/// In-memory collapse state for session groups.
///
/// Projects persist theirs in `CollapsedProjects`; groups did not before the
/// move to an outline view and still do not, so a group reopens expanded.
@MainActor
final class CollapsedGroups: ObservableObject {
    static let shared = CollapsedGroups()
    @Published private(set) var ids: Set<UUID> = []

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func set(_ id: UUID, collapsed: Bool) {
        if collapsed { ids.insert(id) } else { ids.remove(id) }
    }
}

/// What a sidebar row draws besides its own record.
///
/// A hosted row bakes these in when it is built, so when they change the rows
/// that care have to be rebuilt. Getting this wrong is invisible in the store
/// and obvious on screen: the checkbox column never appears when multi-select is
/// switched on, and the previously selected row keeps its highlight while the
/// new one stays plain.
struct SidebarRowInputs: Equatable {
    var isMultiSelecting: Bool
    var selection: MainSelection?
    var selected: Set<UUID>
}

/// Which rows a change of those inputs invalidates. Pure, so the rule is
/// testable without an outline view.
enum SidebarRowReload: Equatable {
    /// Every row: the checkbox column appeared or disappeared.
    case all
    /// Only these outline node ids.
    case items(Set<String>)

    static func plan(from old: SidebarRowInputs?, to new: SidebarRowInputs) -> SidebarRowReload {
        guard let old else { return .all }
        guard old != new else { return .items([]) }
        if old.isMultiSelecting != new.isMultiSelecting { return .all }

        var affected = Set<String>()
        for selection in [old.selection, new.selection] {
            switch selection {
            case .project(let id): affected.insert(SidebarItem.project(id).nodeID)
            case .group(let id): affected.insert(SidebarItem.group(id).nodeID)
            case .session(let id): affected.insert(SidebarItem.session(id).nodeID)
            case nil: break
            }
        }
        // Only the rows that joined or left the batch selection changed.
        affected.formUnion(
            old.selected.symmetricDifference(new.selected).map { SidebarItem.session($0).nodeID }
        )
        return .items(affected)
    }
}

/// What the sidebar offers a drop target, inside the app and outside it.
enum SidebarDragMask {
    /// Inside Uncoil a session moves: into a group, to another slot, or onto a
    /// session view to open beside it.
    static let local: NSDragOperation = .move

    /// Empty on purpose. Offering `.copy` outside the app meant the Finder
    /// accepted the drag as text and wrote a clipping to the desktop — and
    /// because something *had* accepted it, the drag never counted as refused
    /// everywhere, which is the condition for opening the session in its own
    /// window. Refusing every external operation is what makes dragging a
    /// session out of the window do what it looks like it does.
    static let external: NSDragOperation = []
}

/// The sidebar tree, as an `NSOutlineView`.
///
/// Rows stay ordinary SwiftUI — same design, same hover, same little buttons —
/// because a hosted view passes the clicks it does not handle up the responder
/// chain (see `HostingHitTestTests`). That leaves the outline view holding
/// exactly what SwiftUI could not do: insertion-point drags, drops into a
/// collapsed group, ⌘/⇧ multi-selection, keyboard navigation, and recycled rows
/// so a status tick redraws one row instead of the list.
struct SidebarOutline: NSViewRepresentable {
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    let isMultiSelecting: Bool
    let actions: SidebarRowActions

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var collapsedProjects = CollapsedProjects.shared
    @ObservedObject private var collapsedGroups = CollapsedGroups.shared

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("sidebar"))
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
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        // Indentation and disclosure triangles are part of the row design, drawn
        // by the SwiftUI content, so AppKit contributes neither.
        outlineView.indentationPerLevel = 0
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.setAccessibilityIdentifier("sidebar.container")
        outlineView.registerForDraggedTypes([.string])
        outlineView.setDraggingSourceOperationMask(SidebarDragMask.local, forLocal: true)
        outlineView.setDraggingSourceOperationMask(SidebarDragMask.external, forLocal: false)
        context.coordinator.outlineView = outlineView
        outlineView.coordinator = context.coordinator
        return makeUncoilScrollView(documentView: outlineView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(
            environment: .init(
                projectStore: projectStore,
                sessionStore: sessionStore,
                settings: settings,
                actions: actions,
                isMultiSelecting: isMultiSelecting,
                selection: $selection,
                selectedSessionIDs: $selectedSessionIDs
            ),
            collapsedProjects: collapsedProjects,
            collapsedGroups: collapsedGroups
        )
    }

    /// Everything a row needs, gathered once per update so the coordinator does
    /// not reach into SwiftUI state of its own.
    struct RowEnvironment {
        let projectStore: ProjectStore
        let sessionStore: SessionStore
        let settings: SettingsStore
        let actions: SidebarRowActions
        let isMultiSelecting: Bool
        let selection: Binding<MainSelection?>
        let selectedSessionIDs: Binding<Set<UUID>>
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outlineView: SidebarOutlineView?
        private var environment: RowEnvironment?
        private var structure = SidebarStructure()
        private var root = OutlineNode<SidebarItem>(
            id: "root", payload: .project(UUID()), isGroup: true
        )
        private let heights = RowHeightCache()
        private var lastRowInputs: SidebarRowInputs?
        /// Set while the coordinator is the one changing selection or expansion,
        /// so its own writes do not come back as user intent.
        private var isSyncing = false

        var isMultiSelecting: Bool { environment?.isMultiSelecting ?? false }

        // MARK: - Update cycle

        func apply(
            environment: RowEnvironment,
            collapsedProjects: CollapsedProjects,
            collapsedGroups: CollapsedGroups
        ) {
            self.environment = environment
            // Everything below is SwiftUI's update pass. `reloadData`,
            // `expandItem` and `selectRowIndexes` all call delegate methods back
            // synchronously — and those write to `@Binding`s and stores, which
            // from inside an update is exactly the "Publishing changes from
            // within view updates is not allowed" the console fills up with.
            // Nothing the coordinator triggers itself counts as user intent, so
            // the whole pass is marked as ours.
            isSyncing = true
            defer { isSyncing = false }

            let fresh = Self.structure(from: environment.projectStore)
            let structureChanged = fresh != structure
            structure = fresh
            if structureChanged {
                root = Self.makeTree(from: fresh)
                outlineView?.reloadData()
            }

            let inputs = SidebarRowInputs(
                isMultiSelecting: environment.isMultiSelecting,
                selection: environment.selection.wrappedValue,
                selected: environment.selectedSessionIDs.wrappedValue
            )
            // A full reload already rebuilt every row with the current inputs.
            if !structureChanged {
                apply(SidebarRowReload.plan(from: lastRowInputs, to: inputs))
            }
            lastRowInputs = inputs

            syncExpansion(collapsedProjects: collapsedProjects, collapsedGroups: collapsedGroups)
            syncSelection()
        }

        private func apply(_ reload: SidebarRowReload) {
            guard let outlineView else { return }
            switch reload {
            case .all:
                outlineView.reloadData()
            case .items(let ids):
                for id in ids {
                    guard let node = root.node(withID: id) else { continue }
                    outlineView.reloadItem(node)
                }
            }
        }

        private static func structure(from store: ProjectStore) -> SidebarStructure {
            SidebarStructure.build(
                projectIDs: store.projects.map(\.id),
                groups: { store.groups(for: $0).map(\.id) },
                sessions: { store.sessions(for: $0).map { ($0.id, $0.groupID) } }
            )
        }

        private static func makeTree(from structure: SidebarStructure) -> OutlineNode<SidebarItem> {
            OutlineNode(
                id: "root",
                payload: .project(UUID()),
                isGroup: true,
                children: structure.projects.map { project in
                    OutlineNode(
                        id: SidebarItem.project(project.id).nodeID,
                        payload: .project(project.id),
                        isGroup: !project.groups.isEmpty || !project.ungrouped.isEmpty,
                        children: project.groups.map { group in
                            OutlineNode(
                                id: SidebarItem.group(group.id).nodeID,
                                payload: .group(group.id),
                                isGroup: true,
                                children: group.sessions.map { session in
                                    OutlineNode(
                                        id: SidebarItem.session(session).nodeID,
                                        payload: .session(session),
                                        isGroup: false
                                    )
                                }
                            )
                        } + project.ungrouped.map { session in
                            OutlineNode(
                                id: SidebarItem.session(session).nodeID,
                                payload: .session(session),
                                isGroup: false
                            )
                        }
                    )
                }
            )
        }

        /// Mirrors the collapse stores into the outline view. One direction
        /// only: a chevron writes to the store, the store lands here.
        private func syncExpansion(
            collapsedProjects: CollapsedProjects,
            collapsedGroups: CollapsedGroups
        ) {
            guard let outlineView else { return }
            for node in root.children {
                guard case .project(let id) = node.payload else { continue }
                setExpanded(!collapsedProjects.contains(id), for: node, in: outlineView)
                for child in node.children {
                    guard case .group(let groupID) = child.payload else { continue }
                    setExpanded(!collapsedGroups.contains(groupID), for: child, in: outlineView)
                }
            }
        }

        private func setExpanded(
            _ expanded: Bool,
            for node: OutlineNode<SidebarItem>,
            in outlineView: NSOutlineView
        ) {
            guard outlineView.isItemExpanded(node) != expanded else { return }
            if expanded {
                outlineView.expandItem(node)
            } else {
                outlineView.collapseItem(node)
            }
        }

        /// Mirrors `selection` and `selectedSessionIDs` into the outline view's
        /// own selection, so opening a session from the dashboard highlights its
        /// sidebar row and scrolls it into view.
        private func syncSelection() {
            guard let outlineView, let environment else { return }
            let wanted: [String]
            if !environment.selectedSessionIDs.wrappedValue.isEmpty {
                wanted = environment.selectedSessionIDs.wrappedValue
                    .map { SidebarItem.session($0).nodeID }
            } else {
                switch environment.selection.wrappedValue {
                case .project(let id): wanted = [SidebarItem.project(id).nodeID]
                case .group(let id): wanted = [SidebarItem.group(id).nodeID]
                case .session(let id): wanted = [SidebarItem.session(id).nodeID]
                case nil: wanted = []
                }
            }
            let rows = wanted.compactMap { id -> Int? in
                guard let node = root.node(withID: id) else { return nil }
                let row = outlineView.row(forItem: node)
                return row >= 0 ? row : nil
            }
            let target = IndexSet(rows)
            guard target != outlineView.selectedRowIndexes else { return }
            outlineView.selectRowIndexes(target, byExtendingSelection: false)
            if let first = rows.min(), rows.count == 1 {
                outlineView.scrollRowToVisible(first)
            }
        }

        private func node(_ item: Any?) -> OutlineNode<SidebarItem> {
            (item as? OutlineNode<SidebarItem>) ?? root
        }

        func item(_ item: Any?) -> SidebarItem? {
            guard let node = item as? OutlineNode<SidebarItem> else { return nil }
            return node.payload
        }

        // MARK: - Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(item).children.count
        }

        func outlineView(
            _ outlineView: NSOutlineView, child index: Int, ofItem item: Any?
        ) -> Any {
            node(item).children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            node(item).isGroup
        }

        // MARK: - Rows

        func outlineView(
            _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
        ) -> NSView? {
            let node = node(item)
            guard let content = content(for: node) else { return nil }
            return dequeueHostingCell(
                from: outlineView,
                identifier: .init(reuseIdentifier(for: node)),
                owner: self,
                content: content
            )
        }

        private func reuseIdentifier(for node: OutlineNode<SidebarItem>) -> String {
            switch node.payload {
            case .project: return root.children.first?.id == node.id
                ? "sidebar-project-first" : "sidebar-project"
            case .group: return "sidebar-group"
            // Depth is in the identifier because it changes the row's indent,
            // and the height cache is keyed by the same string.
            case .session: return "sidebar-session-\(structure.depth(of: node.payload))"
            }
        }

        /// The SwiftUI view a row hosts. One builder for both the cell and the
        /// height measurement, so a row can never be measured as something other
        /// than what it draws.
        private func content(for node: OutlineNode<SidebarItem>) -> AnyView? {
            guard let environment else { return nil }
            switch node.payload {
            case .project(let id):
                return AnyView(
                    ProjectRowView(
                        projectID: id,
                        isFirst: root.children.first?.id == node.id,
                        selection: environment.selection,
                        actions: environment.actions
                    )
                    .environmentObject(environment.projectStore)
                    .environmentObject(environment.sessionStore)
                    .environmentObject(environment.settings)
                )
            case .group(let id):
                return AnyView(
                    SessionGroupRowView(
                        groupID: id,
                        isSelected: environment.selection.wrappedValue == .group(id),
                        actions: environment.actions
                    )
                    .environmentObject(environment.projectStore)
                )
            case .session(let id):
                let selected = environment.selectedSessionIDs.wrappedValue
                return AnyView(
                    SessionRowView(
                        sessionID: id,
                        depth: structure.depth(of: node.payload),
                        isSelected: environment.selection.wrappedValue == .session(id)
                            || selected.contains(id),
                        isMultiSelected: selected.contains(id),
                        showsSelectionControl: environment.isMultiSelecting,
                        selectedSessionIDs: environment.selectedSessionIDs,
                        actions: environment.actions
                    )
                    .environmentObject(environment.projectStore)
                    .environmentObject(environment.sessionStore)
                )
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            PlainTableRowView()
        }

        /// Rows of one kind are all the same height — every label is
        /// `lineLimit(1)` and the launcher strip is an overlay — so one
        /// measurement per kind is enough, and it is taken from a real row.
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            let node = node(item)
            guard let content = content(for: node) else { return 30 }
            return heights.height(
                kind: reuseIdentifier(for: node),
                width: max(outlineView.bounds.width, 120)
            ) { content }
        }

        /// The disclosure triangle is drawn by the row's own SwiftUI chevron, but
        /// it is hidden by giving the outline cell an empty frame — not here.
        ///
        /// Answering `false` does more than hide the triangle: AppKit then treats
        /// the item as permanently expanded and quietly ignores `collapseItem`,
        /// which is exactly what left the chevron rotating with the sessions
        /// still on screen. `SidebarCollapseTests` holds this down.
        func outlineView(
            _ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any
        ) -> Bool {
            true
        }

        // MARK: - Selection

        /// In multi-select mode a plain click adds to the selection instead of
        /// replacing it — the accumulate-by-clicking that the checkbox mode has
        /// always had, now from anywhere on the row.
        ///
        /// Done here rather than by intercepting `mouseDown`, because the table
        /// view's own mouse handling is also what starts a drag: taking the
        /// event would have made a multi-selection impossible to drag into a
        /// group, which is the whole point of selecting several.
        func outlineView(
            _ outlineView: NSOutlineView,
            selectionIndexesForProposedSelection proposed: IndexSet
        ) -> IndexSet {
            guard isMultiSelecting,
                  let event = NSApp.currentEvent,
                  event.type == .leftMouseDown,
                  event.modifierFlags.isDisjoint(with: [.command, .shift]),
                  proposed.count == 1,
                  let row = proposed.first else { return proposed }
            var result = outlineView.selectedRowIndexes
            if result.contains(row) { result.remove(row) } else { result.insert(row) }
            return result
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outlineView, let environment else { return }
            let selected = outlineView.selectedRowIndexes.compactMap {
                outlineView.item(atRow: $0) as? OutlineNode<SidebarItem>
            }
            guard !selected.isEmpty else { return }

            let sessionIDs = selected.compactMap { node -> UUID? in
                guard case .session(let id) = node.payload else { return nil }
                return id
            }
            // More than one row selected only ever means a batch of sessions —
            // that is what the batch bar acts on.
            if selected.count > 1 || (environment.isMultiSelecting && !sessionIDs.isEmpty) {
                environment.selectedSessionIDs.wrappedValue = Set(sessionIDs)
                return
            }

            environment.selectedSessionIDs.wrappedValue = []
            switch selected[0].payload {
            case .project(let id): environment.selection.wrappedValue = .project(id)
            case .group(let id): environment.selection.wrappedValue = .group(id)
            case .session(let id): environment.selection.wrappedValue = .session(id)
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            writeExpansion(from: notification, collapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            writeExpansion(from: notification, collapsed: true)
        }

        /// Expansion driven from the outline view itself — a double-click, an
        /// arrow key — is written back so the chevron and the collapse-all
        /// button agree with it.
        private func writeExpansion(from notification: Notification, collapsed: Bool) {
            guard !isSyncing,
                  let node = notification.userInfo?["NSObject"] as? OutlineNode<SidebarItem>
            else { return }
            switch node.payload {
            case .project(let id): CollapsedProjects.shared.set(id, collapsed: collapsed)
            case .group(let id): CollapsedGroups.shared.set(id, collapsed: collapsed)
            case .session: break
            }
        }

        // MARK: - Dragging

        func outlineView(
            _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
        ) -> NSPasteboardWriting? {
            guard let environment else { return nil }
            switch node(item).payload {
            case .project(let id):
                return SidebarDragPayload.project(id).pasteboardString as NSString
            case .session(let id):
                // Dragging a row of a multi-selection carries the whole
                // selection, the way the old drag handle did.
                let selected = environment.selectedSessionIDs.wrappedValue
                let ids = selected.contains(id) ? Array(selected) : [id]
                return SidebarDragPayload.sessions(ids).pasteboardString as NSString
            case .group:
                // Groups are containers, not payloads: dragging one would have
                // to mean "move its sessions", which the group row already does
                // as a drop target.
                return nil
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let plan = plan(for: info, item: item, childIndex: index, in: outlineView),
                  plan.plan != .refuse else { return [] }
            // Retarget so the insertion point is drawn between the rows the drop
            // will actually land between, rather than on the row under the mouse.
            outlineView.setDropItem(plan.retargetedItem, dropChildIndex: plan.retargetedIndex)
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let environment,
                  let resolved = plan(for: info, item: item, childIndex: index, in: outlineView)
            else { return false }
            switch resolved.plan {
            case .refuse:
                return false
            case .reorderProjects(let dragged, let toIndex):
                environment.projectStore.moveProject(dragged, toIndex: toIndex)
                return true
            case .moveSessions(let ids, let projectID, let groupID, let toIndex):
                environment.projectStore.moveSessions(
                    ids, toGroup: groupID, inProject: projectID, at: toIndex
                )
                environment.selectedSessionIDs.wrappedValue = []
                if let groupID {
                    environment.selection.wrappedValue = .group(groupID)
                }
                return true
            }
        }

        /// A drag ending outside the window with nothing accepting it opens the
        /// session in its own window — the behaviour the old drag handle had.
        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard let environment,
                  let frame = outlineView.window?.frame,
                  PopoutDragDecision.shouldPopOut(
                      operation: operation, endedAt: screenPoint, windowFrame: frame
                  ),
                  let string = session.draggingPasteboard.string(forType: .string),
                  case .sessions(let ids) = SidebarDragPayload.parse(string),
                  // One window for one session. A dragged-out batch would open a
                  // window per row, which is never what the gesture meant.
                  ids.count == 1, let id = ids.first
            else { return }
            environment.actions.openSessionWindow(id)
        }

        private struct ResolvedDrop {
            let plan: SidebarDropPlan
            let retargetedItem: Any?
            let retargetedIndex: Int
        }

        /// Turns the outline view's proposal into a store mutation, retargeting a
        /// drop *on* a row into an insertion beside it.
        private func plan(
            for info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int,
            in outlineView: NSOutlineView
        ) -> ResolvedDrop? {
            guard let string = info.draggingPasteboard.string(forType: .string),
                  let payload = SidebarDragPayload.parse(string) else { return nil }

            var targetItem = item
            var targetIndex = index
            // A session is a leaf: a drop "on" one means "in front of it".
            if let node = item as? OutlineNode<SidebarItem>, case .session = node.payload {
                let parent = outlineView.parent(forItem: node) as? OutlineNode<SidebarItem>
                targetIndex = outlineView.childIndex(forItem: node)
                targetItem = parent
            }

            let parent: SidebarDropParent
            switch (targetItem as? OutlineNode<SidebarItem>)?.payload {
            case .project(let id): parent = .project(id)
            case .group(let id): parent = .group(id)
            case .session, .none: parent = .root
            }

            return ResolvedDrop(
                plan: SidebarDropResolver.plan(
                    payload: payload,
                    parent: parent,
                    childIndex: targetIndex,
                    context: structure.dropContext
                ),
                retargetedItem: targetItem,
                retargetedIndex: targetIndex
            )
        }

        // MARK: - Context menu

        /// Right-click menus are AppKit's, so they work over the whole row and
        /// select the row they act on first — the titles are the ones the rows
        /// used to declare in SwiftUI.
        func menu(for row: Int) -> NSMenu? {
            guard let outlineView,
                  let node = outlineView.item(atRow: row) as? OutlineNode<SidebarItem>,
                  let environment else { return nil }
            let menu = NSMenu()
            switch node.payload {
            case .project(let id):
                guard let project = environment.projectStore.projects.first(where: { $0.id == id })
                else { return nil }
                add(
                    to: menu,
                    title: project.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin")
                ) { environment.projectStore.toggleProjectPin(id) }
                add(to: menu, title: String(localized: "Move Up")) {
                    environment.projectStore.nudgeProject(id, by: -1)
                }
                add(to: menu, title: String(localized: "Move Down")) {
                    environment.projectStore.nudgeProject(id, by: 1)
                }
                menu.addItem(.separator())
                add(to: menu, title: String(localized: "New Group…")) {
                    environment.actions.createGroup(project)
                }
                add(to: menu, title: String(localized: "Customise…")) {
                    environment.actions.customizeProject(project)
                }
                let collapsed = CollapsedProjects.shared.contains(id)
                add(to: menu, title: collapsed ? String(localized: "Show Sessions") : String(localized: "Hide Sessions")) {
                    CollapsedProjects.shared.set(id, collapsed: !collapsed)
                }
                menu.addItem(.separator())
                add(to: menu, title: String(localized: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
                add(to: menu, title: String(localized: "Remove from List")) {
                    environment.projectStore.removeProject(project)
                }
            case .group(let id):
                guard let group = environment.projectStore.sessionGroups
                    .first(where: { $0.id == id }) else { return nil }
                add(to: menu, title: String(localized: "Rename")) {
                    environment.actions.renameGroup(group)
                }
                add(to: menu, title: String(localized: "Delete Group")) {
                    environment.projectStore.removeGroup(id)
                    environment.selection.wrappedValue = .project(group.projectID)
                }
            case .session(let id):
                guard let record = environment.projectStore.sessions.first(where: { $0.id == id })
                else { return nil }
                add(
                    to: menu,
                    title: record.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin")
                ) { environment.projectStore.togglePin(id) }
                // Ordering a session should not require a steady hand: the same
                // nudges projects have, applied among its siblings.
                add(to: menu, title: String(localized: "Move Up")) {
                    environment.projectStore.nudgeSession(id, by: -1)
                }
                add(to: menu, title: String(localized: "Move Down")) {
                    environment.projectStore.nudgeSession(id, by: 1)
                }
                if record.groupID != nil {
                    add(to: menu, title: String(localized: "Remove from Group")) {
                        environment.projectStore.moveSessions(
                            [id], toGroup: nil, inProject: record.projectID, at: -1
                        )
                    }
                }
                menu.addItem(.separator())
                add(to: menu, title: String(localized: "Open in a New Window")) {
                    environment.actions.openSessionWindow(id)
                }
                menu.addItem(.separator())
                // The session ID is what the control plane and the MCP tools
                // address a session by, so copying it is the fastest way to
                // hand one to an agent.
                add(to: menu, title: String(localized: "Copy the Session ID")) {
                    copyToPasteboard(id.uuidString)
                }
                if let providerID = record.providerSessionID, !providerID.isEmpty {
                    add(to: menu, title: String(localized: "Copy the Provider Session ID")) {
                        copyToPasteboard(providerID)
                    }
                }
                menu.addItem(.separator())
                add(to: menu, title: String(localized: "Delete the Session")) {
                    environment.actions.confirmDeleteSession(record)
                }
            }
            return menu
        }

        /// The menu for the space below the rows.
        func emptyAreaMenu() -> NSMenu? {
            guard let environment else { return nil }
            let menu = NSMenu()
            add(to: menu, title: String(localized: "New Project…")) {
                environment.actions.addProject()
            }
            return menu
        }

        private func add(to menu: NSMenu, title: String, action: @escaping () -> Void) {
            let item = MenuItem(title: title, action: action)
            menu.addItem(item)
        }

        /// Carries its own closure so menu actions do not need a selector
        /// per entry.
        private final class MenuItem: NSMenuItem {
            private let handler: () -> Void

            init(title: String, action: @escaping () -> Void) {
                handler = action
                super.init(title: title, action: #selector(fire), keyEquivalent: "")
                target = self
            }

            @available(*, unavailable)
            required init(coder: NSCoder) { fatalError("not supported") }

            @objc private func fire() { handler() }
        }
    }
}

/// Menu actions run outside the coordinator's lifetime expectations, so the
/// clipboard write stays a free function rather than a captured method.
private func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

/// The outline view itself, for the two behaviours that need the mouse before
/// the table's default handling gets it.
final class SidebarOutlineView: NSOutlineView {
    weak var coordinator: SidebarOutline.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Below the last row there is no project to act on, and right-clicking
        // there did nothing at all — including on a first run, where the empty
        // sidebar *is* the whole window and adding a project is the only thing
        // to do.
        guard row >= 0 else { return coordinator?.emptyAreaMenu() }
        // Right-clicking acts on the row under the cursor, so it becomes the
        // selected one unless it is already part of a selection being acted on.
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.menu(for: row)
    }

    /// Hides AppKit's disclosure triangle — the rows draw their own chevron —
    /// without telling the outline view the item has no outline cell, which is
    /// what would make the item impossible to collapse.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

/// The handful of things a sidebar row cannot do on its own, because they open a
/// window or a sheet owned by the screen around it.
struct SidebarRowActions {
    var openSessionWindow: (UUID) -> Void
    var customizeProject: (Project) -> Void
    var createGroup: (Project) -> Void
    var renameGroup: (SessionGroup) -> Void
    var confirmDeleteSession: (SessionRecord) -> Void
    /// Raised from the empty space below the rows, where there is no project to
    /// act on and adding one is the only thing that makes sense.
    var addProject: () -> Void
}
