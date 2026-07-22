import SwiftUI
import AppKit

struct MainWindow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var selectedProjectID: UUID?

    private var selectedProject: Project? {
        projectStore.projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedProjectID: $selectedProjectID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let project = selectedProject {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                EmptyStateView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uncoilAddProject)) { _ in
            presentAddProjectPanel()
        }
        .onAppear {
            if selectedProjectID == nil {
                selectedProjectID = projectStore.projects.first?.id
            }
        }
    }

    private func presentAddProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Proje klasörünü seç"
        panel.prompt = "Ekle"
        if panel.runModal() == .OK, let url = panel.url {
            projectStore.addProject(at: url)
            selectedProjectID = projectStore.projects.last?.id
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Proje ekleyerek başla")
                .font(.title3)
            Text("⇧⌘O ile ya da kenar çubuğundaki + düğmesiyle bir klasör ekle.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
