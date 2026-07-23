import SwiftUI

enum MainSelection: Hashable {
    case project(UUID)
    case session(UUID)
}

struct MainWindow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var palette = PaletteModel()
    @State private var selection: MainSelection?
    /// Secondary session shown side-by-side (drop a session onto the view).
    @State private var splitSessionID: UUID?
    @State private var showFolderPicker = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Self.maxSidebarWidth)
    @State private var dragStartWidth: Double?

    static let maxSidebarWidth: Double = 252
    private static let hideThreshold: Double = 120

    var body: some View {
        ZStack {
            mainContent
            if palette.isOpen {
                CommandPaletteOverlay(model: palette)
            }
        }
        .onChange(of: selection) { _, _ in syncPaletteSelection() }
        .onChange(of: palette.pendingAction) { _, action in
            if let action { perform(action); palette.pendingAction = nil }
        }
    }

    private var mainContent: some View {
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
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet { url in
                projectStore.addProject(at: url)
                if let added = projectStore.projects.last {
                    selection = .project(added.id)
                }
            }
        }
        .onAppear {
            // Deferred: mutating @Published stores inside the first view
            // update triggers "Publishing changes from within view updates".
            DispatchQueue.main.async {
                LaunchConfig.shared.seedFixture(projectStore: projectStore)
                startServices()
                applyLaunchRoute()
                applyFixedWindowFrame()
                setupPalette()
            }
        }
    }

    // MARK: - Command palette

    private func setupPalette() {
        palette.configure(
            projectStore: projectStore,
            sessionStore: sessionStore,
            settingsPanes: SettingsView.Pane.allCases.map { ($0.rawValue, $0.title) }
        )
        syncPaletteSelection()
        PaletteHotkeyMonitor.install(model: palette)
    }

    private func syncPaletteSelection() {
        switch selection {
        case .project(let id):
            palette.currentProjectID = id
            palette.currentSessionID = nil
        case .session(let id):
            palette.currentSessionID = id
            palette.currentProjectID = projectStore.sessions.first { $0.id == id }?.projectID
        case nil:
            palette.currentProjectID = nil
            palette.currentSessionID = nil
        }
    }

    private func perform(_ action: PaletteAction) {
        switch action {
        case .addProject:
            showFolderPicker = true
        case .openProject(let id):
            selection = .project(id)
        case .focusSession(let id):
            selection = .session(id)
        case .newSession(let projectID, let provider):
            launchSession(projectID: projectID, provider: provider)
        case .createWorktree(let projectID):
            selection = .project(projectID)
        case .openSettings(let paneID):
            SettingsRoute.shared.requestedPane = paneID
            openWindow(id: "settings")
        case .restartSession(let id):
            TerminalRegistry.shared.closeTerminal(for: id)
            projectStore.updateSession(id) { $0.lastActivityAt = .now }
            sessionStore.bumpRestart(id)
        case .closeSession(let id):
            TerminalRegistry.shared.closeTerminal(for: id)
            sessionStore.setStatus(.terminated, for: id)
        case .popoutSession(let id):
            openWindow(id: "session-window", value: id)
        case .openFile(let url), .openArtifact(let url):
            settings.preferredEditor.open(url)
        case .askClaude(let prompt, let projectID):
            askClaude(prompt, projectID: projectID)
        }
    }

    @discardableResult
    private func launchSession(projectID: UUID, provider: AgentProvider) -> SessionRecord {
        let account = settings.defaultAccount(for: provider)
        let record = projectStore.createSession(
            projectID: projectID,
            provider: provider,
            accountID: provider == .terminal ? nil : account?.id,
            title: provider == .terminal ? "terminal" : "\(provider.rawValue): yeni oturum"
        )
        selection = .session(record.id)
        return record
    }

    /// Starts (or reuses a live) Claude session in the project and sends the
    /// query as its initial prompt. Mirrors the control-plane child launcher.
    private func askClaude(_ prompt: String, projectID: UUID) {
        let live = projectStore.sessions(for: projectID).first {
            $0.provider == .claude && sessionStore.status(of: $0.id) != .terminated
        }
        let record = live ?? projectStore.createSession(
            projectID: projectID, provider: .claude,
            accountID: settings.defaultAccount(for: .claude)?.id,
            title: "claude: yeni oturum")
        selection = .session(record.id)

        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
        _ = TerminalRegistry.shared.terminal(
            for: record, project: project,
            account: settings.account(id: record.accountID),
            settings: settings, sessionStore: sessionStore)

        let sid = record.id
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, sessionStore.status(of: sid) == .terminated {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            RuntimeClient.shared.sendText(Data((prompt + "\n").utf8), sid: sid)
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
                HSplitView {
                    SessionDetailView(
                        record: record,
                        project: project,
                        selection: $selection,
                        splitSessionID: $splitSessionID
                    )
                    .id(record.id)
                    .frame(minWidth: 320)

                    if let splitID = splitSessionID, splitID != id,
                       let splitRecord = projectStore.sessions.first(where: { $0.id == splitID }),
                       let splitProject = projectStore.projects.first(where: { $0.id == splitRecord.projectID }) {
                        SplitSessionPane(
                            record: splitRecord,
                            project: splitProject,
                            onClose: { splitSessionID = nil }
                        )
                        .id(splitID)
                        .frame(minWidth: 320)
                    }
                }
            } else {
                EmptyDetailView(showFolderPicker: $showFolderPicker)
            }
        case nil:
            EmptyDetailView(showFolderPicker: $showFolderPicker)
        }
    }

    private func applyLaunchRoute() {
        let config = LaunchConfig.shared
        if config.route == "session",
           let record = projectStore.sessions.first {
            selection = .session(record.id)
            return
        }
        if selection == nil, let first = projectStore.projects.first {
            selection = .project(first.id)
        }
    }

    /// Deterministic window frame for visual testing (-window-width/-height).
    private func applyFixedWindowFrame() {
        let config = LaunchConfig.shared
        guard let width = config.windowWidth, let height = config.windowHeight else { return }
        // The window may not be visible yet at onAppear; defer one runloop turn.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.setFrame(NSRect(x: 80, y: 120, width: width, height: height), display: true)
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
                notificationPrefs: { [weak settings] in
                    settings?.notifications ?? NotificationPrefs()
                },
                sessionTitle: { id in
                    projects.sessions.first(where: { $0.id == id })?.displayTitle
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
        startControlPlane()
        Task { await settings.resolveBinaries() }
    }

    /// Starts the MCP control-plane socket server. Gated off under UI testing
    /// unless -control-plane is passed (mirrors the runtime daemon gating).
    private func startControlPlane() {
        guard sessionStore.controlServer == nil else { return }
        let gatedOn = !LaunchConfig.shared.isUITesting
            || ProcessInfo.processInfo.arguments.contains("-control-plane")
        guard gatedOn else { return }

        let dataDir = ProjectStore.defaultDirectory()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        let router = CapabilityRouter(
            projectStore: projectStore,
            sessionStore: sessionStore,
            settings: settings,
            audit: AuditLog(dataDirectory: dataDir),
            dataDirectory: dataDir,
            appVersion: version
        )
        router.hookServerRunning = { [weak sessionStore] in sessionStore?.hookServer != nil }

        // Directional permission service, shared with the Settings → İzinler pane.
        let permissions = PermissionService(dataDirectory: dataDir)
        sessionStore.permissionService = permissions
        router.permissions = permissions

        // Child-session launcher: spawn the PTY through the normal terminal
        // path so the child shows up in the sidebar like any session, then
        // deliver its initial prompt once the agent is ready.
        router.childLauncher = { [weak projectStore, weak settings, weak sessionStore] record, prompt in
            guard let projectStore, let settings, let sessionStore,
                  let project = projectStore.projects.first(where: { $0.id == record.projectID })
            else { return }
            let account = settings.account(id: record.accountID)
            _ = TerminalRegistry.shared.terminal(
                for: record, project: project, account: account,
                settings: settings, sessionStore: sessionStore)
            guard let prompt, !prompt.isEmpty else { return }
            let sid = record.id
            Task { @MainActor in
                // Wait for the first hook to flip status off .terminated, else
                // fall back to a fixed delay, then send the prompt as input.
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline, sessionStore.status(of: sid) == .terminated {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                RuntimeClient.shared.sendText(Data((prompt + "\n").utf8), sid: sid)
            }
        }

        let server = ControlPlaneServer(
            socketPath: ControlPlaneServer.defaultSocketPath(), router: router)
        do {
            try server.start()
            sessionStore.controlServer = server
        } catch {
            NSLog("Uncoil control plane could not start: \(error)")
        }
    }
}
