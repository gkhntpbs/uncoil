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
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Self.maxSidebarWidth)
    @State private var dragStartWidth: Double?

    static let maxSidebarWidth: Double = 252
    private static let hideThreshold: Double = 120

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(
                    selection: $selection,
                    showFolderPicker: $showFolderPicker
                )
                .frame(width: sidebarWidth)
                .clipped()
                .transition(.move(edge: .leading))

                // Divider doubles as a resize handle: drag to size the
                // sidebar (max = default width), drag to the left edge to
                // hide it entirely.
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                    .overlay(
                        Color.clear
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside {
                                    NSCursor.resizeLeftRight.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStartWidth == nil {
                                            dragStartWidth = sidebarWidth
                                        }
                                        let proposed = (dragStartWidth ?? sidebarWidth)
                                            + value.translation.width
                                        sidebarWidth = min(Self.maxSidebarWidth, max(0, proposed))
                                    }
                                    .onEnded { _ in
                                        dragStartWidth = nil
                                        if sidebarWidth < Self.hideThreshold {
                                            sidebarVisible = false
                                            sidebarWidth = Self.maxSidebarWidth
                                        }
                                    }
                            )
                    )
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .top)
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
