import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var sessionStore: SessionStore

    private var session: AgentSession? {
        sessionStore.session(for: project.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHostView(project: project)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    launchClaude()
                } label: {
                    Label("Claude Başlat", systemImage: "sparkles")
                }
                .help("Bu projenin terminalinde claude komutunu çalıştırır")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(project.name)
                .fontWeight(.semibold)
            Text(project.rootPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let session {
                StatusBadge(status: session.status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func launchClaude() {
        if sessionStore.session(for: project.id) == nil {
            let session = sessionStore.startSession(projectID: project.id, title: project.name)
            session.status = .running
        }
        TerminalRegistry.shared.send(text: "claude\n", to: project)
    }
}
