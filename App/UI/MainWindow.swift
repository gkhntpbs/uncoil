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

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: $selection,
                showFolderPicker: $showFolderPicker
            )
            .frame(width: 252)

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
