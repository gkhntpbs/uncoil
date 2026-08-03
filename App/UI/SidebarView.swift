import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    @Binding var showFolderPicker: Bool
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @Environment(\.openWindow) private var openWindow
    @State private var showCreateGroup = false
    @State private var showBulkDelete = false
    @State private var groupName = ""
    @State private var isMultiSelecting = false
    // Sheets and dialogs the row context menus ask for. They live here rather
    // than in the rows because a recycled row is the wrong owner for a window.
    @State private var customizingProject: Project?
    /// Project getting a new, empty group from its context menu. Until now a
    /// group could only be born from a multi-selection.
    @State private var groupingProject: Project?
    @State private var renamingGroup: SessionGroup?
    @State private var renameValue = ""
    @State private var deletingSession: SessionRecord?

    /// How far the window's own title bar reaches into the content.
    static let titlebarClearance: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            // The window controls that used to sit here now live in the title
            // bar, in one place regardless of the sidebar. What is left is the
            // clearance the first row needs from it — shared with the detail
            // column, so a project's header bar starts on the same line as the
            // first project in the list.
            Spacer().frame(height: Self.titlebarClearance)

            SidebarOutline(
                selection: $selection,
                selectedSessionIDs: $selectedSessionIDs,
                isMultiSelecting: isMultiSelecting,
                actions: SidebarRowActions(
                    openSessionWindow: { openWindow(id: "session-window", value: $0) },
                    customizeProject: { customizingProject = $0 },
                    createGroup: {
                        groupName = ""
                        groupingProject = $0
                    },
                    renameGroup: {
                        renameValue = $0.name
                        renamingGroup = $0
                    },
                    confirmDeleteSession: { deletingSession = $0 }
                )
            )
            .overlay(alignment: .top) {
                if projectStore.projects.isEmpty {
                    VStack(spacing: 8) {
                        Text("No projects yet")
                            .font(Theme.ui(.body))
                            .foregroundStyle(Theme.textFaint)
                        Button("Add a Project") { showFolderPicker = true }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.top, 40)
                }
            }

            if !selectedSessionIDs.isEmpty {
                batchActions
            }

            OnboardingResumeRow()

            HStack(spacing: 2) {
                RailButton(iconName: "settings", help: String(localized: "Settings")) {
                    openWindow(id: "settings")
                }
                .accessibilityIdentifier("sidebar.settingsButton")
                RailButton(iconName: "plus", help: String(localized: "Add a project")) {
                    showFolderPicker = true
                }
                .accessibilityIdentifier("sidebar.addProjectButton")
                AttentionRailButton { item in
                    if let sessionID = item.sessionID {
                        selectedSessionIDs.removeAll()
                        selection = .session(sessionID)
                    } else if let projectID = item.projectID {
                        selection = .project(projectID)
                    }
                }
                Spacer()
                RailButton(
                    iconName: "list-check",
                    help: isMultiSelecting ? String(localized: "Turn off multiple selection") : String(localized: "Select several"),
                    isOn: isMultiSelecting
                ) {
                    withAnimation(Theme.Motion.standard) {
                        isMultiSelecting.toggle()
                        if !isMultiSelecting {
                            selectedSessionIDs.removeAll()
                        }
                    }
                }
                .accessibilityIdentifier("sidebar.multiSelectButton")
                .accessibilityValue(isMultiSelecting ? "On" : "Off")
                CollapseAllButton()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .alert("New Group", isPresented: $showCreateGroup) {
            TextField("Group name", text: $groupName)
            Button("Create") { createGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedSessionIDs.count) sessions will move into this group.")
        }
        .confirmationDialog(
            "Delete \(selectedSessionIDs.count) sessions?",
            isPresented: $showBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Sessions", role: .destructive) { deleteSelectedSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running processes are closed; the recordings cannot be recovered.")
        }
        .sheet(item: $customizingProject) { project in
            ProjectCustomizeSheet(project: project)
        }
        .alert("New Group", isPresented: isPresenting($groupingProject)) {
            TextField("Group name", text: $groupName)
            Button("Create") {
                guard let project = groupingProject,
                      let group = projectStore.createGroup(
                          projectID: project.id, name: groupName
                      ) else { return }
                selection = .group(group.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty group is created; drag sessions into it.")
        }
        .alert("Rename Group", isPresented: isPresenting($renamingGroup)) {
            TextField("Group name", text: $renameValue)
            Button("Save") {
                let value = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, let group = renamingGroup else { return }
                projectStore.updateGroup(group.id) { $0.name = value }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deletingSession.map { "Delete the \"\($0.displayTitle)\" session?" } ?? "",
            isPresented: isPresenting($deletingSession),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let record = deletingSession else { return }
                TerminalRegistry.shared.closeTerminal(for: record.id)
                projectStore.removeSession(record.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The running process is closed; the recording cannot be recovered.")
        }
    }

    /// Presents an alert or dialog off an optional value, clearing it on dismiss.
    private func isPresenting<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }

    private var selectedProjectIDs: Set<UUID> {
        Set(projectStore.sessions.filter {
            selectedSessionIDs.contains($0.id)
        }.map(\.projectID))
    }

    private var batchActions: some View {
        HStack(spacing: 8) {
            Text("\(selectedSessionIDs.count) selected")
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                groupName = ""
                showCreateGroup = true
            } label: {
                TablerIcon(name: "folder-plus", size: 13, color: Theme.text)
            }
            .buttonStyle(.plain)
            .disabled(selectedProjectIDs.count != 1)
            .help("Group the selected")
            .accessibilityIdentifier("sidebar.selection.createGroup")
            Button {
                showBulkDelete = true
            } label: {
                TablerIcon(name: "trash", size: 13, color: Theme.danger)
            }
            .buttonStyle(.plain)
            .help("Delete the selected")
            .accessibilityIdentifier("sidebar.selection.delete")
            Button {
                selectedSessionIDs.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Clear the selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panelActive)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func createGroup() {
        guard let projectID = selectedProjectIDs.first,
              selectedProjectIDs.count == 1,
              let group = projectStore.createGroup(projectID: projectID, name: groupName)
        else { return }
        projectStore.assignSessions(selectedSessionIDs, to: group.id)
        selection = .group(group.id)
        selectedSessionIDs.removeAll()
    }

    private func deleteSelectedSessions() {
        let projectID = selectedProjectIDs.first
        for id in selectedSessionIDs {
            TerminalRegistry.shared.closeTerminal(for: id)
        }
        projectStore.removeSessions(selectedSessionIDs)
        if case .session(let id) = selection, selectedSessionIDs.contains(id) {
            selection = projectID.map(MainSelection.project)
        }
        selectedSessionIDs.removeAll()
    }
}

private extension View {
    /// `sheet(item:)` for a plain optional, so a row's context menu can raise a
    /// sheet the sidebar owns.
    func sheet<Value: Identifiable, Content: View>(
        item: Binding<Value?>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}

// MARK: - Hierarchy metrics

/// The one place the sidebar's nesting is defined.
///
/// Sessions used to sit at almost the same inset as the project above them, so a
/// project and its sessions read as one flat list. Depth now buys both an indent
/// and a hairline that ties a child to the row it belongs to.
enum SidebarIndent {
    /// Inset of the whole list from the sidebar's edge.
    static let outer: CGFloat = 8
    /// Content inset per depth, measured from the cell's leading edge.
    ///
    /// A project sits close to the edge: indentation exists to show what belongs
    /// to what, and a top-level row belongs to nothing.
    static func leading(depth: Int) -> CGFloat {
        switch depth {
        case 0: return 4
        case 1: return 16
        default: return 28
        }
    }

    /// Where the connecting hairlines sit for a row at this depth. A session
    /// inside a group gets two: its project's and its group's.
    static func rails(depth: Int) -> [CGFloat] {
        switch depth {
        case 0: return []
        case 1: return [11]
        default: return [11, 23]
        }
    }
}

/// The hairlines that tie a row to the project — and group — it lives under.
private struct IndentRails: View {
    let depth: Int

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(SidebarIndent.rails(depth: depth), id: \.self) { x in
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                    .padding(.leading, x)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The pinned marker.
///
/// It was drawn as `pinned-filled`, a name the bundled outline font does not
/// have — and `TablerIcon` falls back to a dot for an unknown name, which is why
/// pinning showed a yellow dot instead of a pin. The filled set is not bundled;
/// `pinned` is the glyph that actually exists and reads as a stuck pin.
/// The pin, in one icon and one colour.
///
/// It was drawn with `TablerIcon(name: "pinned-filled")` — a name the bundled
/// font does not have, because that font is the outline set and carries no
/// filled variants at all, and an unknown name silently falls back to a dot.
/// That is what showed up as a yellow dot. Pinned state is the *same* pin,
/// filled, in the same colour as the unpinned one; SF Symbols has that pair, the
/// bundled font does not.
struct PinMark: View {
    let isPinned: Bool
    var size: CGFloat = 11
    var color: Color = Theme.textFaint

    var body: some View {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: size))
            .foregroundStyle(color)
    }
}

private struct RailButton: View {
    let iconName: String
    var help: String = ""
    /// Drawn as engaged — the multi-select toggle is the one rail button that
    /// has a state rather than just an action.
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(
                name: iconName,
                size: 12,
                color: isOn ? Theme.highlight : (hovering ? Theme.text : Theme.textDim)
            )
            .frame(width: 20, height: 20)
            .background(
                isOn ? Theme.panelActive : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
        }
        .buttonStyle(.pressable)
        .animation(Theme.Motion.quick, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Hide/show the sidebar, and open the command palette.
///
/// Lives in the sidebar when there is one and beside the traffic lights when
/// there is not: a control that hides a surface cannot be the first casualty of
/// hiding it, or there is no way back except the menu bar.
struct WindowControlsCluster: View {
    var onOpenPalette: () -> Void
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        HStack(spacing: 2) {
            RailButton(
                iconName: "layout-sidebar",
                help: sidebarVisible ? String(localized: "Hide the sidebar") : String(localized: "Show the sidebar")
            ) {
                withAnimation(Theme.Motion.standard) {
                    sidebarVisible.toggle()
                }
            }
            .accessibilityIdentifier("sidebar.toggleButton")
            RailButton(iconName: "search", help: String(localized: "Open the command palette (⌘K)")) {
                onOpenPalette()
            }
            .accessibilityIdentifier("sidebar.paletteButton")
        }
    }
}

// MARK: - Project row

/// A project row.
///
/// Selection, dragging, reordering and the context menu belong to the outline
/// view that hosts this; what stays here is the design, the hover reveal, and
/// the two controls that are genuinely the row's own. The project is read from
/// the store by id so a rename or a pin redraws this row without the outline
/// view needing to hear about it.
struct ProjectRowView: View {
    let projectID: UUID
    let isFirst: Bool
    @Binding var selection: MainSelection?
    let actions: SidebarRowActions
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var hovering = false
    @ObservedObject private var collapsedStore = CollapsedProjects.shared

    private var project: Project? {
        projectStore.projects.first { $0.id == projectID }
    }

    private var sessionsCollapsed: Bool {
        collapsedStore.contains(projectID)
    }

    private var isProjectSelected: Bool {
        selection == .project(projectID)
    }

    private var childCount: Int {
        projectStore.sessions(for: projectID).count
    }

    private var hasChildren: Bool {
        childCount > 0 || !projectStore.groups(for: projectID).isEmpty
    }

    /// The chevron's slot at the trailing edge: its hit target, and the width
    /// the project name stops short of. Fixed so the chevron sits in the same
    /// place on every row whatever the name's length or the hover state.
    static let chevronSlot: CGFloat = 22

    var body: some View {
        if let project {
            HStack(spacing: 8) {
                ProjectIcon(project: project)
                Text(project.name)
                    .font(Theme.mono(.large, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if project.isPinned == true {
                    PinMark(isPinned: true, size: 10, color: Theme.textDim)
                        .help("Pinned")
                }
                // Nothing follows the name inline. The chevron owns a fixed slot
                // at the trailing edge and the name stops short of it.
                Spacer(minLength: Self.chevronSlot)
            }
            .padding(.leading, SidebarIndent.leading(depth: 0))
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            // The collapse chevron never moves.
            //
            // It used to be laid out after the project name, which put it in a
            // different place on every row and, on a long name, directly under
            // the launcher strip. Then it was grouped with the launcher, which
            // was worse: hovering *inserted* the strip to its left, so the
            // chevron jumped ~90pt away from the cursor that was reaching for
            // it. A control you have to chase is a control you do not have.
            // It gets its own slot, sized and placed the same on every row,
            // hovered or not; the launcher is laid out to the left of it.
            .overlay(alignment: .trailing) {
                if hasChildren {
                    Button {
                        toggleCollapsed()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(sessionsCollapsed ? -90 : 0))
                            // An 8pt glyph is an 8pt target: the chevron is
                            // drawn small on purpose, but it still has to be
                            // hittable without aiming. The frame is the target,
                            // not the mark.
                            .frame(width: Self.chevronSlot, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .opacity(hovering || sessionsCollapsed ? 1 : 0)
                    .allowsHitTesting(hovering || sessionsCollapsed)
                    .padding(.trailing, 6)
                }
            }
            // The launcher and the collapsed count share the space to the left
            // of the chevron's slot — they swap on hover, and neither can push
            // the chevron anywhere, because the chevron is not in this stack.
            .overlay(alignment: .trailing) {
                Group {
                    if hovering {
                        // The launcher floats above the row instead of sitting
                        // in it: laid out inline it grew the row on hover (the
                        // whole list twitched), and reserving its full width
                        // truncated every project name for good.
                        AgentLauncherStrip(project: project, selection: $selection)
                    } else if sessionsCollapsed, childCount > 0 {
                        // Collapsed, the project has to say how much it hides.
                        Text("\(childCount)")
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(.trailing, Self.chevronSlot + 6)
                .animation(Theme.Motion.quick, value: hovering)
            }
            .background(
                isProjectSelected ? Theme.highlightMuted : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.horizontal, 8)
            // Sections used to be separated by the stack's own padding; as
            // outline rows they carry the gap themselves.
            .padding(.top, isFirst ? 0 : 6)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.project.\(project.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection = .project(projectID) }
        }
    }

    private func toggleCollapsed() {
        withAnimation(Theme.Motion.standard) {
            collapsedStore.set(projectID, collapsed: !sessionsCollapsed)
        }
    }
}

/// Persisted per-project "sessions hidden" state, observable so the
/// collapse-all rail button updates every section at once.
@MainActor
final class CollapsedProjects: ObservableObject {
    static let shared = CollapsedProjects()
    private static let key = "collapsedProjects"

    @Published private(set) var ids: Set<String>

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id.uuidString) }

    func set(_ id: UUID, collapsed: Bool) {
        if collapsed { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        persist()
    }

    func setAll(_ projectIDs: [UUID], collapsed: Bool) {
        if collapsed {
            ids.formUnion(projectIDs.map(\.uuidString))
        } else {
            ids.subtract(projectIDs.map(\.uuidString))
        }
        persist()
    }

    func allCollapsed(_ projectIDs: [UUID]) -> Bool {
        !projectIDs.isEmpty && projectIDs.allSatisfy { ids.contains($0.uuidString) }
    }

    private func persist() {
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }
}

/// Hover strip: pick an agent, it launches into this project
/// (or into a specific worktree when `worktreePath` is set).
struct AgentLauncherStrip: View {
    let project: Project
    var worktreePath: String? = nil
    @Binding var selection: MainSelection?
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AgentProvider.sessionKinds) { provider in
                LauncherButton(provider: provider) {
                    launch(provider)
                }
            }
        }
        .padding(3)
        .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    private func launch(_ provider: AgentProvider) {
        let account = settings.defaultAccount(for: provider)
        let worktreeName = worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let record = projectStore.createSession(
            projectID: project.id,
            provider: provider,
            accountID: provider == .terminal ? nil : account?.id,
            title: provider == .terminal
                ? (worktreeName.map { "terminal @ \($0)" } ?? "terminal")
                : String(localized: "\(provider.rawValue): new session"),
            worktreePath: worktreePath
        )
        selection = .session(record.id)
    }
}

private struct LauncherButton: View {
    let provider: AgentProvider
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ProviderMark(provider: provider, size: 11)
                .frame(width: 22, height: 18)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("launcher.\(provider.rawValue)")
        .help("Start \(provider.displayName)")
    }
}

// MARK: - Group row

/// A session group's header row. The chevron collapses it; the outline view
/// takes care of what the collapse means for the rows below.
struct SessionGroupRowView: View {
    let groupID: UUID
    let isSelected: Bool
    let actions: SidebarRowActions
    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var collapsedGroups = CollapsedGroups.shared

    private var group: SessionGroup? {
        projectStore.sessionGroups.first { $0.id == groupID }
    }

    private var isExpanded: Bool { !collapsedGroups.contains(groupID) }

    var body: some View {
        if let group {
            HStack(spacing: 7) {
                Button {
                    withAnimation(Theme.Motion.standard) {
                        collapsedGroups.toggle(groupID)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(Theme.textFaint)
                        // Same target as the project row's chevron — the two sit
                        // in the same list and should not aim differently.
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -5)
                }
                .buttonStyle(.pressable)
                TablerIcon(name: "folder", size: 12, color: Theme.textDim)
                Text(group.name)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Spacer()
                Text("\(projectStore.sessions(in: groupID).count)")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.leading, SidebarIndent.leading(depth: 1))
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Theme.highlightMuted : Theme.panel.opacity(0.45),
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.horizontal, SidebarIndent.outer)
            .overlay(alignment: .leading) { IndentRails(depth: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.group.\(group.name)")
        }
    }
}

// MARK: - Session row

/// A session row. The whole row is the drag source now — the grip is the
/// affordance for it rather than the only place it works.
struct SessionRowView: View {
    let sessionID: UUID
    /// 1 directly under a project, 2 inside one of its groups.
    let depth: Int
    let isSelected: Bool
    let isMultiSelected: Bool
    let showsSelectionControl: Bool
    @Binding var selectedSessionIDs: Set<UUID>
    let actions: SidebarRowActions
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var hovering = false
    /// Drives the attention pulse; flipped by the status, animated by SwiftUI.
    @State private var pulsing = false
    @ObservedObject private var attentionMotion = AttentionMotion.shared

    private var record: SessionRecord? {
        projectStore.sessions.first { $0.id == sessionID }
    }

    private var status: AgentSessionStatus {
        sessionStore.status(of: sessionID)
    }

    /// Waiting on the user right now, or carrying a notification nobody has
    /// looked at yet.
    private var wantsAttention: Bool {
        sessionStore.wantsAttention(sessionID)
    }

    /// The colour of what it is waiting for — the same one the status orb uses,
    /// so the row and the orb never disagree. A finished turn reads as idle, so
    /// its unlooked-at notification borrows the "ready" accent instead.
    private var attentionColor: Color {
        status.needsAttention ? status.color : Theme.highlight
    }

    private var emphasis: AttentionEmphasis {
        attentionMotion.emphasis
    }

    /// Starts or stops the breath. Deferred for the same reason the orb defers:
    /// a repeating animation started during the first render keeps the window
    /// from being presented at all.
    private func updatePulse(wants: Bool) {
        guard wants, attentionMotion.animates else {
            pulsing = false
            return
        }
        DeferredMotion.start { pulsing = true }
    }

    var body: some View {
        if let record {
            HStack(spacing: 6) {
                if showsSelectionControl {
                    Button {
                        if selectedSessionIDs.contains(sessionID) {
                            selectedSessionIDs.remove(sessionID)
                        } else {
                            selectedSessionIDs.insert(sessionID)
                        }
                    } label: {
                        Image(systemName: isMultiSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(isMultiSelected ? Theme.highlight : Theme.textFaint)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("sidebar.select.\(record.title)")
                }

                HStack(spacing: 8) {
                    // The grip is gone: it existed because SwiftUI could not
                    // drag a row, so a session needed one spot that could. The
                    // whole row is the drag source now, and in a sidebar this
                    // narrow those 18 points are worth more as title than as a
                    // decoration. Its identifier stays here, on the row's first
                    // element, so a drag still starts from the same place.
                    ProviderMark(provider: record.provider, size: 11)
                        .opacity(status == .terminated ? 0.45 : 1)
                        .accessibilityIdentifier("sidebar.drag.\(record.title)")
                        .help("Drag onto a group to move it; drop outside the window to open it in a new one")
                    Text(record.displayTitle)
                        .font(Theme.mono(.body))
                        .foregroundStyle(status == .terminated ? Theme.textDim : Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if record.isPinned == true || hovering {
                        PinButton(record: record)
                    }
                    StatusOrb(status: status, size: 11)
                    Text(RelativeClock.short(since: record.lastActivityAt))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 34, alignment: .trailing)
                }
                // A container element, not a combined one: without this the
                // identifier is copied onto every label inside and the row
                // matches several times over; with `.combine` the pin button
                // would stop being addressable on its own.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.session.\(record.title)")
                // The highlight is a background colour, which no test and no
                // screen reader can see. The trait says it out loud — and a row
                // keeping a stale highlight was a real bug.
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            .padding(.leading, SidebarIndent.leading(depth: depth))
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            // Selection is the highlight's muted surface, not a grey one: the
            // palette carries a pair for exactly this, and grey-on-grey made a
            // selected row hard to find at a glance.
            .background(
                isSelected ? Theme.highlightMuted : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            // A session that stopped to ask something has to be findable without
            // reading the list: it is marked in that status's own colour until
            // it is dealt with, and — unless the user turned the motion off —
            // breathes. How far it breathes is `AttentionEmphasis`; a dozen
            // agents working at once used to make the whole sidebar flicker.
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(attentionColor.opacity(
                        wantsAttention && pulsing ? emphasis.fillOpacity : 0.0
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(
                        wantsAttention
                            ? attentionColor.opacity(
                                pulsing ? emphasis.borderRange.high : emphasis.borderRange.low
                            )
                            : (isSelected ? Theme.highlightBorder : .clear),
                        lineWidth: 1
                    )
            )
            .animation(
                pulsing
                    ? uncoilAnimation(
                        .easeInOut(duration: emphasis.period).repeatForever(autoreverses: true)
                    )
                    : Theme.Motion.standard,
                value: pulsing
            )
            .onChange(of: wantsAttention, initial: true) { _, wants in
                updatePulse(wants: wants)
            }
            // Turning the emphasis down mid-pulse has to stop the old
            // animation, not leave the row breathing at the previous rate.
            .onChange(of: emphasis) { _, _ in
                pulsing = false
                updatePulse(wants: wantsAttention)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.horizontal, SidebarIndent.outer)
            .overlay(alignment: .leading) { IndentRails(depth: depth) }
            .onHover { hovering = $0 }
        }
    }
}

private struct PinButton: View {
    let record: SessionRecord
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var hovering = false

    private var isPinned: Bool { record.isPinned == true }

    var body: some View {
        Button {
            projectStore.togglePin(record.id)
        } label: {
            // Same icon, same colour language, whether it is a button to pin
            // with or the mark saying it is pinned — only filled or not.
            PinMark(
                isPinned: isPinned,
                size: 10,
                color: isPinned ? Theme.textDim : (hovering ? Theme.text : Theme.textFaint)
            )
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.pin.\(record.title)")
        .help(isPinned ? "Unpin" : "Pin")
    }
}

/// Rail button: hide/show the session lists of every project at once.
private struct CollapseAllButton: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var collapsedStore = CollapsedProjects.shared
    @State private var hovering = false

    private var allCollapsed: Bool {
        collapsedStore.allCollapsed(projectStore.projects.map(\.id))
    }

    var body: some View {
        Button {
            withAnimation(Theme.Motion.standard) {
                collapsedStore.setAll(projectStore.projects.map(\.id), collapsed: !allCollapsed)
            }
        } label: {
            TablerIcon(
                name: allCollapsed ? "layout-navbar-expand" : "layout-navbar-collapse",
                size: 12,
                color: hovering ? Theme.text : Theme.textDim
            )
            .frame(width: 20, height: 20)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.collapseAllButton")
        .help(allCollapsed ? "Show all sessions" : "Hide all sessions")
    }
}
