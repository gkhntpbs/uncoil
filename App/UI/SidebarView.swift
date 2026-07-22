import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @Binding var selectedProjectID: UUID?

    var body: some View {
        List(selection: $selectedProjectID) {
            Section("Projeler") {
                ForEach(projectStore.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Finder'da Göster") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                            }
                            Button("Listeden Kaldır", role: .destructive) {
                                projectStore.removeProject(project)
                                if selectedProjectID == project.id {
                                    selectedProjectID = nil
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    NotificationCenter.default.post(name: .uncoilAddProject, object: nil)
                } label: {
                    Label("Proje Ekle", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Uncoil")
    }
}

struct ProjectRow: View {
    let project: Project
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var git = GitInfo.Snapshot(branch: nil, isDirty: false)

    private var session: AgentSession? {
        sessionStore.session(for: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(project.name)
                    .fontWeight(.medium)
                if let session {
                    StatusBadge(status: session.status)
                }
            }
            if let branch = git.branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                    Text(branch + (git.isDirty ? " •" : ""))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: project.id) {
            let path = project.rootPath
            let snapshot = await Task.detached(priority: .utility) {
                GitInfo.snapshot(forRepoAt: path)
            }.value
            git = snapshot
        }
    }
}

struct StatusBadge: View {
    let status: AgentSessionStatus

    private var color: Color {
        switch status {
        case .waitingForPermission: .orange
        case .waitingForInput: .yellow
        case .running: .green
        case .completed: .blue
        case .idle, .terminated: .gray
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
