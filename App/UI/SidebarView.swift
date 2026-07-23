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
            }

            // Bottom rail: settings gear + add project
            HStack(spacing: 10) {
                RailButton(systemName: "gearshape.fill") {
                    openWindow(id: "settings")
                }
                RailButton(systemName: "plus") {
                    showFolderPicker = true
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct RailButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
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

    private var isProjectSelected: Bool {
        selection == .project(project.id)
    }

    var body: some View {
        VStack(spacing: 1) {
            // Project row — hover reveals the agent launcher strip.
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                Text(project.name)
                    .font(Theme.mono(12.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
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
            .onHover { value in
                withAnimation(.easeOut(duration: 0.12)) { hovering = value }
            }
            .contextMenu {
                Button("Finder'da Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
                Button("Listeden Kaldır", role: .destructive) {
                    projectStore.removeProject(project)
                }
            }

            // Session rows
            ForEach(projectStore.sessions(for: project.id)) { record in
                SessionRow(
                    record: record,
                    isSelected: selection == .session(record.id)
                ) {
                    selection = .session(record.id)
                }
            }
        }
        .padding(.bottom, 6)
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
            Group {
                if provider == .terminal {
                    Image(systemName: "terminal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                } else {
                    DotGlyph(color: provider.color, dotSize: 2.2)
                }
            }
            .frame(width: 22, height: 18)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                DotGlyph(color: record.provider.color, dotSize: 2.0)
                    .opacity(status == .terminated ? 0.4 : 1)
                Text(record.title)
                    .font(Theme.mono(12))
                    .foregroundStyle(status == .terminated ? Theme.textDim : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
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
        .contextMenu {
            Button("Oturumu Sil", role: .destructive) {
                TerminalRegistry.shared.closeTerminal(for: record.id)
                projectStore.removeSession(record.id)
            }
        }
    }
}
