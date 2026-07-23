import SwiftUI

enum MainSelection: Hashable {
    case project(UUID)
    case session(UUID)
}

struct MainWindow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var selection: MainSelection?
    @State private var showFolderPicker = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(
                    selection: $selection,
                    showFolderPicker: $showFolderPicker
                )
                .frame(width: 252)
                .transition(.move(edge: .leading))

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Content underlaps the (hidden) title bar so the toggle can sit on
        // the same row as the traffic lights — fixed spot, never moves.
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topLeading) {
            SidebarToggle(sidebarVisible: $sidebarVisible)
                .padding(.leading, 76)
                .padding(.top, 8)
                .ignoresSafeArea(edges: .top)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet { url in
                projectStore.addProject(at: url)
                if let added = projectStore.projects.last {
                    selection = .project(added.id)
                }
            }
        }
        .onAppear {
            startServices()
            if selection == nil, let first = projectStore.projects.first {
                selection = .project(first.id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .project(let id):
            if let project = projectStore.projects.first(where: { $0.id == id }) {
                ProjectDashboardView(project: project, selection: $selection)
                    .id(project.id)
            } else {
                EmptyDetailView(showFolderPicker: $showFolderPicker)
            }
        case .session(let id):
            if let record = projectStore.sessions.first(where: { $0.id == id }),
               let project = projectStore.projects.first(where: { $0.id == record.projectID }) {
                SessionDetailView(record: record, project: project, selection: $selection)
                    .id(record.id)
            } else {
                EmptyDetailView(showFolderPicker: $showFolderPicker)
            }
        case nil:
            EmptyDetailView(showFolderPicker: $showFolderPicker)
        }
    }

    private struct SidebarToggle: View {
        @Binding var sidebarVisible: Bool
        @State private var hovering = false

        var body: some View {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
            } label: {
                TablerIcon(
                    name: sidebarVisible ? "layout-sidebar-left-collapse" : "layout-sidebar-left-expand",
                    size: 14,
                    color: hovering ? Theme.text : Theme.textFaint
                )
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut("\\", modifiers: .command)
            .help("Kenar çubuğunu göster/gizle (⌘\\)")
        }
    }

    private func startServices() {
        if sessionStore.hookServer == nil {
            let projects = projectStore
            let sessions = sessionStore
            sessionStore.startHookServer(
                projectResolver: { path in projects.project(containing: path) },
                sessionResolver: { projectID in
                    sessions.liveSessionID(projectSessions: projects.sessions(for: projectID))
                },
                touchSession: { id in
                    projects.updateSession(id) { $0.lastActivityAt = .now }
                },
                applyMeta: { id, providerSessionID, titleCandidate in
                    projects.updateSession(id) { record in
                        if let providerSessionID {
                            record.providerSessionID = providerSessionID
                        }
                        if let titleCandidate, record.hasPlaceholderTitle {
                            record.title = titleCandidate
                        }
                    }
                }
            )
        }
        Task { await settings.resolveBinaries() }
    }
}
