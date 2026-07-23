import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Binding var selection: MainSelection?
    @Binding var showFolderPicker: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Space for traffic lights — the window has no title bar.
            Spacer().frame(height: 38)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(projectStore.projects) { project in
                        ProjectSection(
                            project: project,
                            selection: $selection
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

            // Bottom rail: settings gear + add project
            HStack(spacing: 10) {
                RailButton(iconName: "settings") {
                    openWindow(id: "settings")
                }
                .accessibilityIdentifier("sidebar.settingsButton")
                RailButton(iconName: "plus") {
                    showFolderPicker = true
                }
                .accessibilityIdentifier("sidebar.addProjectButton")
                Spacer()
                CollapseAllButton()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
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

            // Session rows
            if !sessionsCollapsed {
                ForEach(records) { record in
                    SessionRow(
                        record: record,
                        isSelected: selection == .session(record.id)
                    ) {
                        selection = .session(record.id)
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

// MARK: - Session row

private struct SessionRow: View {
    let record: SessionRecord
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var hovering = false
    @State private var confirmDelete = false

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    var body: some View {
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
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Theme.panelActive : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Theme.border : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrag {
            NSItemProvider(object: record.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: SessionDropDelegate(
            targetID: record.id,
            projectStore: projectStore
        ))
        .accessibilityIdentifier("sidebar.session.\(record.title)")
        .contextMenu {
            Button(record.isPinned == true ? "Sabitlemeyi Kaldır" : "Sabitle") {
                projectStore.togglePin(record.id)
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
