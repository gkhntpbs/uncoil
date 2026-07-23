import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedSessionID: UUID?
    @State private var showFolderPicker = false

    private var selection: (record: SessionRecord, project: Project)? {
        guard
            let id = selectedSessionID,
            let record = projectStore.sessions.first(where: { $0.id == id }),
            let project = projectStore.projects.first(where: { $0.id == record.projectID })
        else { return nil }
        return (record, project)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selectedSessionID: $selectedSessionID,
                showFolderPicker: $showFolderPicker
            )
            .frame(width: 252)

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)

            Group {
                if let selection {
                    SessionDetailView(record: selection.record, project: selection.project)
                        .id(selection.record.id)
                } else {
                    EmptyDetailView(showFolderPicker: $showFolderPicker)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet { url in
                projectStore.addProject(at: url)
            }
        }
        .onAppear {
            startServices()
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
                }
            )
        }
        Task { await settings.resolveBinaries() }
    }
}
