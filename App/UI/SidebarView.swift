import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    @Binding var showFolderPicker: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var showCreateGroup = false
    @State private var showBulkDelete = false
    @State private var groupName = ""
    @State private var isMultiSelecting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(uncoilAnimation(.easeOut(duration: 0.15))) {
                        isMultiSelecting.toggle()
                        if !isMultiSelecting {
                            selectedSessionIDs.removeAll()
                        }
                    }
                } label: {
                    TablerIcon(
                        name: "list-check",
                        size: 13,
                        color: isMultiSelecting ? Theme.codex : Theme.textDim
                    )
                    .frame(width: 24, height: 24)
                    .background(
                        isMultiSelecting ? Theme.panelActive : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .help(isMultiSelecting ? "Çoklu seçimi kapat" : "Birden fazla seç")
                .accessibilityIdentifier("sidebar.multiSelectButton")
                .accessibilityValue(isMultiSelecting ? "Açık" : "Kapalı")
            }
            .frame(height: 38)
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(projectStore.projects) { project in
                        ProjectSection(
                            project: project,
                            selection: $selection,
                            selectedSessionIDs: $selectedSessionIDs,
                            isMultiSelecting: isMultiSelecting
                        )
                    }
                    if projectStore.projects.isEmpty {
                        VStack(spacing: 8) {
                            Text("Henüz proje yok")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textFaint)
                            Button("Proje ekle") { showFolderPicker = true }
                                .buttonStyle(GhostButtonStyle())
                        }
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 8)
                .uncoilScrollers()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.container")

            if !selectedSessionIDs.isEmpty {
                batchActions
            }

            HStack(spacing: 10) {
                RailButton(iconName: "settings") {
                    openWindow(id: "settings")
                }
                .accessibilityIdentifier("sidebar.settingsButton")
                RailButton(iconName: "plus") {
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
                CollapseAllButton()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .alert("Yeni Grup", isPresented: $showCreateGroup) {
            TextField("Grup adı", text: $groupName)
            Button("Oluştur") { createGroup() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(selectedSessionIDs.count) oturum bu gruba taşınacak.")
        }
        .confirmationDialog(
            "\(selectedSessionIDs.count) oturum silinsin mi?",
            isPresented: $showBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Oturumları Sil", role: .destructive) { deleteSelectedSessions() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Çalışan süreçler kapatılır; kayıtlar geri alınamaz.")
        }
    }

    private var selectedProjectIDs: Set<UUID> {
        Set(projectStore.sessions.filter {
            selectedSessionIDs.contains($0.id)
        }.map(\.projectID))
    }

    private var batchActions: some View {
        HStack(spacing: 8) {
            Text("\(selectedSessionIDs.count) seçili")
                .font(Theme.mono(10.5, .semibold))
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
            .help("Seçilenleri grupla")
            .accessibilityIdentifier("sidebar.selection.createGroup")
            Button {
                showBulkDelete = true
            } label: {
                TablerIcon(name: "trash", size: 13, color: Theme.danger)
            }
            .buttonStyle(.plain)
            .help("Seçilenleri sil")
            .accessibilityIdentifier("sidebar.selection.delete")
            Button {
                selectedSessionIDs.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Seçimi temizle")
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

private struct RailButton: View {
    let iconName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(name: iconName, size: 13, color: hovering ? Theme.text : Theme.textDim)
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Project section

private struct ProjectSection: View {
    let project: Project
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    let isMultiSelecting: Bool
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false
    @State private var showCustomize = false
    @ObservedObject private var collapsedStore = CollapsedProjects.shared

    private var sessionsCollapsed: Bool {
        collapsedStore.contains(project.id)
    }

    private var isProjectSelected: Bool {
        selection == .project(project.id)
    }

    private var records: [SessionRecord] {
        projectStore.sessions(for: project.id)
    }

    private var groups: [SessionGroup] {
        projectStore.groups(for: project.id)
    }

    private var ungroupedRecords: [SessionRecord] {
        records.filter { $0.groupID == nil }
    }

    var body: some View {
        VStack(spacing: 1) {
            // Project row — hover reveals collapse chevron + agent launcher.
            HStack(spacing: 8) {
                ProjectIcon(project: project)
                Text(project.name)
                    .font(Theme.mono(12.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !records.isEmpty {
                    Button {
                        toggleCollapsed()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(sessionsCollapsed ? -90 : 0))
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || sessionsCollapsed ? 1 : 0)
                }
                Spacer(minLength: 4)
                if hovering {
                    AgentLauncherStrip(project: project, selection: $selection)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isProjectSelected ? Theme.panelActive : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture { selection = .project(project.id) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.project.\(project.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection = .project(project.id) }
            .onHover { value in
                withAnimation(uncoilAnimation(.easeOut(duration: 0.12))) { hovering = value }
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                loadSessionIDs(from: providers) { ids in
                    projectStore.assignSessions(ids, to: nil)
                }
            }
            .contextMenu {
                Button("Özelleştir…") { showCustomize = true }
                Button(sessionsCollapsed ? "Oturumları Göster" : "Oturumları Gizle") {
                    toggleCollapsed()
                }
                Divider()
                Button("Finder'da Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
                Button("Listeden Kaldır", role: .destructive) {
                    projectStore.removeProject(project)
                }
            }
            .sheet(isPresented: $showCustomize) {
                ProjectCustomizeSheet(project: project)
            }

            if !sessionsCollapsed {
                ForEach(groups) { group in
                    SessionGroupRow(
                        group: group,
                        selection: $selection,
                        selectedSessionIDs: $selectedSessionIDs,
                        isMultiSelecting: isMultiSelecting
                    )
                }
                ForEach(ungroupedRecords) { record in
                    SessionRow(
                        record: record,
                        isSelected: selection == .session(record.id)
                            || selectedSessionIDs.contains(record.id),
                        isMultiSelected: selectedSessionIDs.contains(record.id),
                        showsSelectionControl: isMultiSelecting,
                        dragIDs: selectedSessionIDs.contains(record.id)
                            ? selectedSessionIDs
                            : [record.id]
                    ) {
                        select(record)
                    } onToggleSelection: {
                        toggleSelection(record.id)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func toggleCollapsed() {
        withAnimation(uncoilAnimation(.easeOut(duration: 0.15))) {
            collapsedStore.set(project.id, collapsed: !sessionsCollapsed)
        }
    }

    private func select(_ record: SessionRecord) {
        if isMultiSelecting {
            toggleSelection(record.id)
            return
        }
        selectedSessionIDs.removeAll()
        selection = .session(record.id)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedSessionIDs.contains(id) {
            selectedSessionIDs.remove(id)
        } else {
            selectedSessionIDs.insert(id)
        }
    }

    private func loadSessionIDs(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (Set<UUID>) -> Void
    ) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            let ids = Set(payload.split(separator: ",").compactMap {
                UUID(uuidString: String($0))
            })
            guard !ids.isEmpty else { return }
            Task { @MainActor in completion(ids) }
        }
        return true
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
            ForEach([AgentProvider.claude, .codex, .terminal]) { provider in
                LauncherButton(provider: provider) {
                    launch(provider)
                }
            }
        }
        .padding(3)
        .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: 6))
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
                : "\(provider.rawValue): yeni oturum",
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
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("launcher.\(provider.rawValue)")
        .help("\(provider.displayName) başlat")
    }
}

private struct SessionGroupRow: View {
    let group: SessionGroup
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    let isMultiSelecting: Bool
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var isExpanded = true
    @State private var isTargeted = false
    @State private var showRename = false
    @State private var renameValue = ""

    private var records: [SessionRecord] {
        projectStore.sessions(in: group.id)
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(uncoilAnimation(.easeOut(duration: 0.15))) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                TablerIcon(
                    name: "folder",
                    size: 12,
                    color: isTargeted ? Theme.codex : Theme.textDim
                )
                Text(group.name)
                    .font(Theme.mono(11.5, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Spacer()
                Text("\(records.count)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(
                selection == .group(group.id) || isTargeted
                    ? Theme.panelActive
                    : Theme.panel.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture {
                selectedSessionIDs.removeAll()
                selection = .group(group.id)
            }
            .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let payload = object as? String else { return }
                    let ids = Set(payload.split(separator: ",").compactMap {
                        UUID(uuidString: String($0))
                    })
                    Task { @MainActor in
                        projectStore.assignSessions(ids, to: group.id)
                        selectedSessionIDs.removeAll()
                        selection = .group(group.id)
                    }
                }
                return true
            }
            .contextMenu {
                Button("Yeniden Adlandır") {
                    renameValue = group.name
                    showRename = true
                }
                Button("Grubu Sil", role: .destructive) {
                    projectStore.removeGroup(group.id)
                    selection = .project(group.projectID)
                }
            }
            .alert("Grubu Yeniden Adlandır", isPresented: $showRename) {
                TextField("Grup adı", text: $renameValue)
                Button("Kaydet") {
                    let value = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    projectStore.updateGroup(group.id) { $0.name = value }
                }
                Button("Vazgeç", role: .cancel) {}
            }
            .accessibilityIdentifier("sidebar.group.\(group.name)")

            if isExpanded {
                ForEach(records) { record in
                    SessionRow(
                        record: record,
                        isSelected: selection == .session(record.id)
                            || selectedSessionIDs.contains(record.id),
                        isMultiSelected: selectedSessionIDs.contains(record.id),
                        showsSelectionControl: isMultiSelecting,
                        dragIDs: selectedSessionIDs.contains(record.id)
                            ? selectedSessionIDs
                            : [record.id]
                    ) {
                        select(record)
                    } onToggleSelection: {
                        if selectedSessionIDs.contains(record.id) {
                            selectedSessionIDs.remove(record.id)
                        } else {
                            selectedSessionIDs.insert(record.id)
                        }
                    }
                }
            }
        }
    }

    private func select(_ record: SessionRecord) {
        if isMultiSelecting {
            if selectedSessionIDs.contains(record.id) {
                selectedSessionIDs.remove(record.id)
            } else {
                selectedSessionIDs.insert(record.id)
            }
            return
        }
        selectedSessionIDs.removeAll()
        selection = .session(record.id)
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    let isSelected: Bool
    let isMultiSelected: Bool
    let showsSelectionControl: Bool
    let dragIDs: Set<UUID>
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var confirmDelete = false

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsSelectionControl {
                Button(action: onToggleSelection) {
                    Image(systemName: isMultiSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(isMultiSelected ? Theme.codex : Theme.textFaint)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.select.\(record.title)")
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textDim : Theme.textFaint)
                .frame(width: 12, height: 22)
                .contentShape(Rectangle())
                .overlay(
                    // Dragging onto a group still works; dropping outside the
                    // window opens the session in its own one.
                    PopoutDragHandle(
                        payload: dragIDs.map(\.uuidString).sorted().joined(separator: ","),
                        onDropOutside: { openWindow(id: "session-window", value: record.id) }
                    )
                )
                .accessibilityIdentifier("sidebar.drag.\(record.title)")
                .help("Gruba sürükle, pencere dışına bırakınca yeni pencerede açılır")

            Button(action: onSelect) {
                HStack(spacing: 8) {
                ProviderMark(provider: record.provider, size: 11)
                    .opacity(status == .terminated ? 0.45 : 1)
                Text(record.displayTitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(status == .terminated ? Theme.textDim : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if record.isPinned == true || hovering {
                    PinButton(record: record)
                }
                StatusOrb(status: status, size: 11)
                Text(RelativeClock.short(since: record.lastActivityAt))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 34, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.session.\(record.title)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            isSelected ? Theme.panelActive : (hovering ? Theme.panelHover : .clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .onDrop(of: [.text], delegate: SessionDropDelegate(
            targetID: record.id,
            projectStore: projectStore
        ))
        .contextMenu {
            Button(record.isPinned == true ? "Sabitlemeyi Kaldır" : "Sabitle") {
                projectStore.togglePin(record.id)
            }
            Button("Yeni Pencerede Aç") {
                openWindow(id: "session-window", value: record.id)
            }
            Divider()
            Button("Oturumu Sil", role: .destructive) {
                confirmDelete = true
            }
        }
        .confirmationDialog(
            "\"\(record.displayTitle)\" oturumu silinsin mi?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                TerminalRegistry.shared.closeTerminal(for: record.id)
                projectStore.removeSession(record.id)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Çalışan süreç kapatılır; kayıt geri alınamaz.")
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
            TablerIcon(
                name: isPinned ? "pinned-filled" : "pin",
                size: 10,
                color: isPinned ? Theme.warn : (hovering ? Theme.text : Theme.textFaint)
            )
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.pin.\(record.title)")
        .help(isPinned ? "Sabitlemeyi kaldır" : "Sabitle")
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
            withAnimation(uncoilAnimation(.easeOut(duration: 0.15))) {
                collapsedStore.setAll(projectStore.projects.map(\.id), collapsed: !allCollapsed)
            }
        } label: {
            TablerIcon(
                name: allCollapsed ? "layout-navbar-expand" : "layout-navbar-collapse",
                size: 13,
                color: hovering ? Theme.text : Theme.textDim
            )
            .frame(width: 24, height: 24)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("sidebar.collapseAllButton")
        .help(allCollapsed ? "Tüm oturumları göster" : "Tüm oturumları gizle")
    }
}


/// Reorders sessions when one row is dropped onto another.
private struct SessionDropDelegate: DropDelegate {
    let targetID: UUID
    let projectStore: ProjectStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let draggedID = UUID(uuidString: string) else {
                return
            }
            Task { @MainActor in
                projectStore.moveSession(draggedID, before: targetID)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
