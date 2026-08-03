import SwiftUI

enum MainSelection: Hashable {
    case project(UUID)
    case group(UUID)
    case session(UUID)
}

struct MainWindow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var onboarding = OnboardingPresenter.shared
    @State private var selection: MainSelection?
    @State private var selectedSessionIDs: Set<UUID> = []
    /// Secondary session shown side-by-side (drop a session onto the view).
    @State private var splitSessionID: UUID?
    @State private var showFolderPicker = false
    @State private var testWorkspaceError: String?
    @State private var debugBundleMessage: String?
    @State private var debugBundleURL: URL?
    @State private var runtimeCompatibilityError: String?
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Self.maxSidebarWidth)
    @AppStorage("mainSelectionKind") private var persistedSelectionKind = ""
    @AppStorage("mainSelectionID") private var persistedSelectionID = ""
    @State private var dragStartWidth: Double?

    static let maxSidebarWidth: Double = 252
    private static let hideThreshold: Double = 120

    var body: some View {
        ZStack {
            mainContent
            if palette.isOpen {
                CommandPaletteOverlay(model: palette)
            }
            // Setup covers the app rather than sitting beside it: a half-set-up
            // window behind the flow is the state the flow exists to end.
            if onboarding.isPresenting {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        // The palette used to appear and vanish outright: its transition never
        // ran because nothing animated the condition that mounts it.
        .animation(Theme.Motion.expressive, value: palette.isOpen)
        .animation(Theme.Motion.expressive, value: onboarding.isPresenting)
        .onChange(of: selection) { _, _ in
            syncPaletteSelection()
            persistSelection()
        }
        .onChange(of: palette.pendingAction) { _, action in
            if let action { perform(action); palette.pendingAction = nil }
        }
        .alert(
            "Test Workspace Could Not Be Created",
            isPresented: Binding(
                get: { testWorkspaceError != nil },
                set: { if !$0 { testWorkspaceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testWorkspaceError ?? "")
        }
        .alert(
            "Debug Bundle",
            isPresented: Binding(
                get: { debugBundleMessage != nil },
                set: { if !$0 { debugBundleMessage = nil } }
            )
        ) {
            if let debugBundleURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([debugBundleURL])
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(debugBundleMessage ?? "")
        }
        .alert(
            "Runtime Mismatch",
            isPresented: Binding(
                get: { runtimeCompatibilityError != nil },
                set: { if !$0 { runtimeCompatibilityError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runtimeCompatibilityError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .runtimeCompatibilityError)) {
            runtimeCompatibilityError = $0.object as? String
        }
        .onReceive(MainRoute.shared.$requestCounter) { _ in
            guard let requested = MainRoute.shared.requestedSelection else { return }
            selectedSessionIDs.removeAll()
            selection = requested
            MainRoute.shared.requestedSelection = nil
        }
        .onChange(of: sessionStore.statuses) { _, _ in refreshAttention() }
        .onChange(of: sessionStore.codexAuthentication) { _, _ in refreshAttention() }
        .task {
            if LaunchConfig.shared.runtimeMismatchFixture {
                runtimeCompatibilityError =
                    "Runtime protocol mismatch: app 1.1, daemon 2.0."
            }
        }
        .task {
            // At launch, and once a day while the app runs: a Bumblebee scan when
            // the last one is old enough to be worth redoing. With no binary
            // installed this returns "not installed" and changes nothing.
            let scans = BumblebeeScanCoordinator(registry: ExtensionRegistry())
            // A scan the daemon ran while the app was closed is read first.
            _ = scans.importDaemonResult()
            _ = await scans.scanAtLaunchIfStale()
            // And the daily one is handed to the daemon so it keeps happening
            // after the app quits.
            _ = scans.scheduleInDaemon()
            while !Task.isCancelled {
                _ = await scans.scanDailyBaselineIfDue()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
        .task {
            // Merge conflicts and the runtime phase are not observable, so the
            // Attention Center re-derives them on a slow poll.
            while !Task.isCancelled {
                await AttentionRefresher.shared.scanTasks(projectStore: projectStore)
                await AttentionRefresher.shared.scanConflicts(
                    projectStore: projectStore,
                    sessionStore: sessionStore
                )
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func refreshAttention() {
        AttentionRefresher.shared.refresh(
            projectStore: projectStore,
            sessionStore: sessionStore
        )
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(
                    selection: $selection,
                    selectedSessionIDs: $selectedSessionIDs,
                    showFolderPicker: $showFolderPicker
                )
                .frame(width: sidebarWidth)
                .background(Theme.sidebarSurface)
                .clipped()
                // The sidebar wins every argument about width.
                //
                // `.frame(width:)` fixes what the sidebar *asks* for, but when
                // the detail column's own minimum was wider than what was left,
                // the HStack overflowed and centred itself — pushing the
                // sidebar off the left edge, where it could not be reached at
                // all. Priority plus a detail column that may shrink to nothing
                // is what keeps that from happening.
                .layoutPriority(1)
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
                // minWidth 0: whatever is on the right compresses, scrolls or
                // clips inside itself. It is never allowed to demand width from
                // the window and take it out of the sidebar.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .ignoresSafeArea(edges: .top)
        // The toggle also lives in the title bar, which is its own SwiftUI tree:
        // a `withAnimation` there cannot reach this one. Animating on the value
        // means the sidebar slides whoever asked for it.
        .animation(Theme.Motion.expressive, value: sidebarVisible)
        .background(
            // Setup owns the whole window, so the app's own title-bar controls
            // are taken out of it: a sidebar toggle and a palette button over a
            // window with neither behind them are just two dead controls.
            Group {
                if !onboarding.isPresenting {
                    TitlebarControls(onOpenPalette: { palette.open() })
                }
            }
            .frame(width: 0, height: 0)
        )
        .background(Theme.bg)
        .folderPicker(
            isPresented: $showFolderPicker,
            prompt: String(localized: "Add Project")
        ) { url in
            projectStore.addProject(at: url)
            if let added = projectStore.projects.last {
                selection = .project(added.id)
            }
        }
        .background(MainWindowFrame())
        .onAppear {
            // Deferred: mutating @Published stores inside the first view
            // update triggers "Publishing changes from within view updates".
            DispatchQueue.main.async {
                LaunchConfig.shared.seedFixture(projectStore: projectStore)
                LaunchConfig.shared.seedAttentionFixture(
                    projectStore: projectStore, sessionStore: sessionStore
                )
                startServices()
                applyLaunchRoute()
                setupPalette()
                presentOnboardingIfNeeded()
            }
        }
    }

    // MARK: - Command palette

    private func setupPalette() {
        palette.configure(
            projectStore: projectStore,
            sessionStore: sessionStore,
            settingsPanes: SettingsView.Pane.allCases.map { ($0.rawValue, $0.title) },
            launcherProviders: { [weak settings] in
                settings?.launcherProviders ?? AgentProvider.sessionKinds
            }
        )
        syncPaletteSelection()
        PaletteHotkeyMonitor.install(model: palette, settings: settings)
    }

    private func syncPaletteSelection() {
        switch selection {
        case .project(let id):
            palette.currentProjectID = id
            palette.currentSessionID = nil
        case .session(let id):
            palette.currentSessionID = id
            palette.currentProjectID = projectStore.sessions.first { $0.id == id }?.projectID
        case .group(let id):
            palette.currentSessionID = nil
            palette.currentProjectID = projectStore.sessionGroups.first { $0.id == id }?.projectID
        case nil:
            palette.currentProjectID = nil
            palette.currentSessionID = nil
        }
    }

    private func perform(_ action: PaletteAction) {
        switch action {
        case .addProject:
            showFolderPicker = true
        case .createTestWorkspace:
            do {
                let url = try TestWorkspaceService().create()
                projectStore.addProject(at: url)
                if let project = projectStore.projects.first(where: { $0.rootPath == url.path }) {
                    selection = .project(project.id)
                }
            } catch {
                testWorkspaceError = error.localizedDescription
            }
        case .createDebugBundle:
            do {
                let result = try DebugBundleService().create()
                debugBundleURL = result.bundleURL
                debugBundleMessage = "Created: \(result.bundleURL.path)"
            } catch {
                debugBundleURL = nil
                debugBundleMessage = error.localizedDescription
            }
        case .openExtensions:
            openWindow(id: "extensions")
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
            projectStore.markSessionEnded(id, exitCode: nil)
        case .popoutSession(let id):
            openWindow(id: "session-window", value: id)
        case .openFile(let url), .openArtifact(let url):
            settings.preferredEditor.open(url)
        case .ask(let prompt, let target, let projectID):
            ask(prompt, target: target, projectID: projectID)
        case .beginAsk:
            break                       // handled inside the palette; it stays open
        case .captureTask(let text, let projectID, let sourcePath, let heading):
            captureTask(text, projectID: projectID, sourcePath: sourcePath, heading: heading)
        case .newScratchSession(let provider):
            let record = projectStore.createScratchSession(
                provider: provider,
                accountID: settings.defaultAccount(for: provider)?.id
            )
            selection = .session(record.id)
        }
    }

    /// Writes a captured task straight into its TODO.md.
    ///
    /// Through the same byte-range patch the Tasks screen uses, not an append:
    /// the file belongs to the project and may be open in an editor or being
    /// edited by an agent, and rewriting it wholesale is how a captured thought
    /// costs someone else their work.
    private func captureTask(
        _ text: String, projectID: UUID, sourcePath: String, heading: [String]
    ) {
        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
        let sources = ProjectTaskStores.sources(
            projectID: projectID, projectRoot: project.rootPath
        )
        guard let document = sources.document(for: sourcePath) else { return }
        do {
            let patch = try TodoEditor.insertTaskPatch(
                text: text, under: heading, in: document
            )
            _ = try TodoEditor.write(
                patches: [patch],
                to: document.path,
                expectedHash: document.contentHash,
                // The palette's copy of the file can be a keystroke out of
                // date, and a captured thought must not be lost to that: the
                // patch is recomputed against whatever is on disk right now.
                rebuild: { current in
                    try? [TodoEditor.insertTaskPatch(
                        text: text, under: heading, in: current
                    )]
                }
            )
            Task { @MainActor in
                await sources.refreshAsync()
            }
        } catch {
            AttentionStore.shared.report(
                kind: .runtime,
                title: String(localized: "Could not file that task"),
                detail: error.localizedDescription,
                projectID: projectID,
                sessionID: nil,
                id: "capture:\(projectID)"
            )
        }
    }

    @discardableResult
    private func launchSession(projectID: UUID, provider: AgentProvider) -> SessionRecord {
        let account = settings.defaultAccount(for: provider)
        let record = projectStore.createSession(
            projectID: projectID,
            provider: provider,
            accountID: provider == .terminal ? nil : account?.id,
            title: provider == .terminal ? "terminal" : String(localized: "\(provider.rawValue): new session")
        )
        selection = .session(record.id)
        return record
    }

    /// Sends a quick question to the agent the user picked in the palette.
    ///
    /// An existing session gets the question in its own conversation; a new one
    /// is created with the question as its opening prompt. Either way the
    /// session is focused, because the answer is the point.
    private func ask(_ prompt: String, target: AskTarget, projectID: UUID) {
        let record: SessionRecord
        switch target {
        case .session(let id):
            guard let existing = projectStore.sessions(for: projectID)
                .first(where: { $0.id == id }) else { return }
            record = existing
        case .newSession(let provider):
            record = projectStore.createSession(
                projectID: projectID, provider: provider,
                accountID: settings.defaultAccount(for: provider)?.id,
                title: String(localized: "\(provider.rawValue): \(prompt)"))
        }
        selection = .session(record.id)

        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
        _ = TerminalRegistry.shared.terminal(
            for: record, project: project,
            account: settings.account(id: record.accountID),
            settings: settings, sessionStore: sessionStore,
            projectStore: projectStore)

        let sid = record.id
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, sessionStore.status(of: sid) == .terminated {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await TerminalRegistry.shared.submitText(
                prompt, for: sid, provider: record.provider)
        }
    }

    /// Every route starts below the title bar, from one place.
    ///
    /// The window draws under its own title bar, and the sidebar clears it with
    /// an explicit spacer. The detail column had no such clearance: a session
    /// happened to get one from the split view it sits in, while the project
    /// page — a plain scroll view — began at the very top of the window, so the
    /// two screens' header bars sat about forty points apart.
    private var detail: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: SidebarView.titlebarClearance)
            routedDetail
        }
        // Without this the split view re-applies the inset that is now here.
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var routedDetail: some View {
        switch selection {
        case .project(let id):
            if let project = projectStore.projects.first(where: { $0.id == id }) {
                ProjectDashboardView(
                    project: project,
                    selection: $selection,
                    onOrganizeSessions: { organizeSessions(projectID: project.id) }
                )
                    .id(project.id)
            } else {
                EmptyDetailView(showFolderPicker: $showFolderPicker)
            }
        case .group(let id):
            if let group = projectStore.sessionGroups.first(where: { $0.id == id }),
               let project = projectStore.projects.first(where: { $0.id == group.projectID }) {
                SessionGroupView(
                    group: group,
                    project: project,
                    selection: $selection,
                    selectedSessionIDs: $selectedSessionIDs
                )
                .id(group.id)
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session.splitGroup")
                // Opening the session is what "seen" means: the sidebar row
                // stops pulsing here rather than when the banner was shown.
                .task(id: id) { sessionStore.clearAttention(id) }
            } else {
                EmptyDetailView(showFolderPicker: $showFolderPicker)
            }
        case nil:
            EmptyDetailView(showFolderPicker: $showFolderPicker)
        }
    }

    private func organizeSessions(projectID: UUID) {
        let record = projectStore.createSession(
            projectID: projectID,
            provider: .claude,
            accountID: settings.defaultAccount(for: .claude)?.id,
            title: String(localized: "claude: organise sessions")
        )
        selection = .session(record.id)
        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
        _ = TerminalRegistry.shared.terminal(
            for: record,
            project: project,
            account: settings.account(id: record.accountID),
            settings: settings,
            sessionStore: sessionStore,
            projectStore: projectStore
        )
        var prompt = """
        Organise the Uncoil sessions in this project. Use only the Uncoil MCP tools. \
        Start by calling uncoil_sessions list and list_groups. Decide on a small number \
        of understandable groups based on the sessions' titles, providers and purposes. \
        Create the groups you need with create_group, then move sessions with assign_group. \
        Do not group this organiser session. Keep existing meaningful groups, and do not \
        create empty or duplicate ones. When you are done, report your arrangement as a \
        short table.
        """
        if let directive = settings.language.resolvedAgent().directive {
            prompt += "\n\(directive)"
        }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, sessionStore.status(of: record.id) == .terminated {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await TerminalRegistry.shared.submitText(
                prompt, for: record.id, provider: record.provider)
        }
    }

    /// Opens the first-run window on a machine that has never seen it — and on
    /// an upgrade that added steps. A UI-testing run only gets it when it asks.
    private func presentOnboardingIfNeeded() {
        let config = LaunchConfig.shared
        if config.isUITesting {
            if config.route == "onboarding" { OnboardingPresenter.shared.present() }
            return
        }
        if settings.shouldPresentOnboarding {
            OnboardingPresenter.shared.present()
        }
    }

    private func applyLaunchRoute() {
        let config = LaunchConfig.shared
        if config.route == "extensions" {
            // Deterministic way into the Extensions window: the section it opens
            // on is an argument rather than a click.
            ExtensionsCommandBus.shared.open(
                config.extensionsSection.flatMap(ExtensionsView.Section.init(rawValue:))
                    ?? .overview
            )
            openWindow(id: "extensions")
        }
        if config.route == "session",
           let record = projectStore.sessions.first {
            selection = .session(record.id)
            return
        }
        if !config.isUITesting, let restored = restoredSelection() {
            selection = restored
            return
        }
        if selection == nil, let first = projectStore.visibleProjects.first {
            selection = .project(first.id)
        }
    }

    private func persistSelection() {
        MainRoute.shared.lastSelection = selection
        guard !LaunchConfig.shared.isUITesting else { return }
        switch selection {
        case .project(let id):
            persistedSelectionKind = "project"
            persistedSelectionID = id.uuidString
        case .group(let id):
            persistedSelectionKind = "group"
            persistedSelectionID = id.uuidString
        case .session(let id):
            persistedSelectionKind = "session"
            persistedSelectionID = id.uuidString
        case nil:
            persistedSelectionKind = ""
            persistedSelectionID = ""
        }
    }

    private func restoredSelection() -> MainSelection? {
        guard let id = UUID(uuidString: persistedSelectionID) else { return nil }
        switch persistedSelectionKind {
        case "project":
            return projectStore.projects.contains { $0.id == id } ? .project(id) : nil
        case "group":
            return projectStore.sessionGroups.contains { $0.id == id } ? .group(id) : nil
        case "session":
            return projectStore.sessions.contains { $0.id == id } ? .session(id) : nil
        default:
            return nil
        }
    }


    private func startServices() {
        if sessionStore.hookServer == nil {
            let projects = projectStore
            let sessions = sessionStore
            sessionStore.startHookServer(
                projectResolver: { path in projects.project(containing: path) },
                sessionResolver: { project, event in
                    sessions.sessionID(
                        forProviderSessionID: event.sessionID,
                        cwd: event.cwd,
                        projectSessions: projects.sessions(for: project.id),
                        project: project
                    )
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
                },
                endSession: { id in
                    projects.markSessionEnded(id, exitCode: nil)
                }
            )
            startNotificationBridges()
        }
        // The daemon reports what it still has at every handshake; that is the
        // moment the sidebar can tell a session that survived the app from one
        // that did not.
        RuntimeClient.shared.onAliveSessions = { [weak sessionStore, weak projectStore] alive in
            guard let sessionStore, let projectStore else { return }
            // Before reconciling: a session that was asleep when the app quit
            // must get its status back, or it reopens looking terminated.
            SessionSleepService.restoreStatuses(
                projectStore: projectStore, sessionStore: sessionStore
            )
            sessionStore.reconcile(
                aliveSessionIDs: alive,
                records: projectStore.sessions,
                markEnded: { projectStore.markSessionEnded($0, exitCode: nil) }
            )
        }
        startControlPlane()
        // Drop directories whose sessions are gone. Once at start rather than
        // on a timer: the only thing that creates them is a session that no
        // longer exists, and that set does not change while the app runs.
        projectStore.pruneDroppedImages()
        Task { await settings.resolveBinaries() }
    }

    /// Wires the two notification sources that are not the hook reducer:
    /// attention rows (failing tests, lost logins, finished tasks) and the
    /// repeat-reminder sweep for states nobody has answered.
    private func startNotificationBridges() {
        let projects = projectStore
        let sessions = sessionStore
        let store = settings

        AttentionStore.shared.onNewItems = { [weak store] items in
            guard let prefs = store?.notifications else { return }
            for item in items {
                guard let event = item.kind.notificationEvent,
                      let projectID = item.projectID,
                      let sessionID = item.sessionID
                else { continue }
                sessions.notify(
                    event,
                    title: projects.projects.first { $0.id == projectID }?.name ?? "Uncoil",
                    body: String(localized: "\(item.kind.label) · \(item.title)"),
                    projectID: projectID,
                    sessionID: sessionID,
                    prefs: prefs
                )
            }
        }

        sessionStore.startNotificationReminders(
            prefs: { [weak store] in store?.notifications ?? NotificationPrefs() },
            projectID: { id in projects.sessions.first { $0.id == id }?.projectID },
            projectName: { id in
                guard let projectID = projects.sessions.first(where: { $0.id == id })?.projectID
                else { return nil }
                return projects.projects.first { $0.id == projectID }?.name
            },
            sessionTitle: { id in projects.sessions.first { $0.id == id }?.displayTitle },
            visibleSessionID: {
                if case .session(let id) = MainRoute.shared.lastSelection { return id }
                return nil
            }
        )
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
        permissions.pendingTTL = settings.permissionTimeout
        sessionStore.permissionService = permissions
        router.permissions = permissions

        // Permission banners: tapping opens the session; only non-sensitive
        // grants can be answered from the notification itself.
        let notifications = PermissionNotificationCenter.shared
        notifications.permissions = permissions
        notifications.notificationPrefs = { [weak settings] in
            settings?.notifications ?? NotificationPrefs()
        }
        notifications.sessionResolver = { [weak projectStore] raw in
            guard let id = UUID(uuidString: raw) else { return nil }
            return projectStore?.sessions.first { $0.id == id }
        }
        notifications.activate()
        permissions.onRequestCreated = { [weak projectStore] request in
            let target = request.targetSessionID ?? request.fromSessionID
            let projectID = UUID(uuidString: target).flatMap { id in
                projectStore?.sessions.first { $0.id == id }?.projectID
            }
            notifications.post(request, projectID: projectID)
        }

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
                settings: settings, sessionStore: sessionStore,
                projectStore: projectStore)
            guard let prompt, !prompt.isEmpty else { return }
            let sid = record.id
            Task { @MainActor in
                // Wait for the first hook to flip status off .terminated, else
                // fall back to a fixed delay, then send the prompt as input.
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline, sessionStore.status(of: sid) == .terminated {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await TerminalRegistry.shared.submitText(
                    prompt, for: sid, provider: record.provider)
            }
        }

        let server = ControlPlaneServer(
            socketPath: ControlPlaneServer.defaultSocketPath(), router: router)
        do {
            try server.start()
            sessionStore.controlServer = server
            McpStatusStore.shared.setServing(true)
        } catch {
            McpStatusStore.shared.setServing(false)
            NSLog("Uncoil control plane could not start: \(error)")
        }
        startExtensionSecretServer()
    }

    /// Serves MCP secrets to `uncoil-extension`. Secret values live in the
    /// Keychain and are handed over per launch, so they never reach a config
    /// file, a manifest or a log.
    private func startExtensionSecretServer() {
        guard sessionStore.extensionSecretServer == nil else { return }
        let launcher = ExtensionLauncherService(
            layout: .default(),
            launcherPath: ExtensionLauncherService.bundledLauncherPath()
        )
        let store = ExtensionSecretStore()
        let server = ExtensionSecretServer(
            socketPath: ExtensionSecretServer.defaultSocketPath()
        ) { extensionID in
            guard let entry = launcher.readManifest()?.entry(id: extensionID) else {
                return .failure("bilinmeyen extension: \(extensionID)")
            }
            guard !entry.isQuarantined else {
                return .failure("\(extensionID) karantinada")
            }
            let resolved = store.environment(for: extensionID, keys: entry.secretKeys)
            guard resolved.missing.isEmpty else {
                return .failure(
                    "eksik secret: \(resolved.missing.joined(separator: ", "))"
                )
            }
            return .success(resolved.environment)
        }
        do {
            try server.start()
            sessionStore.extensionSecretServer = server
        } catch {
            NSLog("Uncoil extension secret server could not start: \(error)")
        }
    }
}

/// Restores and remembers the main window's frame.
///
/// It works from its own view's window rather than from `NSApp.windows`: that
/// list also holds the menu-bar extra's status-item window, which is visible,
/// tiny, and parked at the top of the screen. Naming *that* window
/// "UncoilMainWindow" is what wrote a 32×30 frame at the screen's top edge into
/// the saved defaults, and every later launch restored the app into the corner.
struct MainWindowFrame: NSViewRepresentable {
    static let autosaveName = "UncoilMainWindow"
    /// Anything smaller than this is not an app window, whatever it claims.
    private static let minimumSensibleSize = NSSize(width: 400, height: 300)

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        attach(probe, retries: 3)
        return probe
    }

    /// The view is not in a window yet on the first turn of the run loop; a few
    /// attempts cost nothing and beat never restoring the frame at all.
    private func attach(_ probe: NSView, retries: Int) {
        DispatchQueue.main.async {
            guard let window = probe.window else {
                if retries > 0 { attach(probe, retries: retries - 1) }
                return
            }
            guard window.canBecomeMain else { return }
            let config = LaunchConfig.shared
            if let width = config.windowWidth, let height = config.windowHeight {
                // A UI-test launch is placed exactly, and never remembered.
                window.setFrame(
                    NSRect(x: 80, y: 120, width: width, height: height), display: true
                )
                return
            }
            Self.forgetImplausibleFrame()
            // With nothing saved, place it ourselves. `.defaultPosition(.center)`
            // centres the window's *origin* before its content size is known, so
            // the window then grows up and to the right and lands in the corner —
            // which is exactly where every fresh launch was starting.
            if !window.setFrameUsingName(Self.autosaveName, force: true) {
                window.center()
            }
            window.setFrameAutosaveName(Self.autosaveName)
            window.saveFrame(usingName: Self.autosaveName)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Drops a saved frame too small to be this window. Without this, the frame
    /// the status-item window wrote would keep pulling the app into the corner.
    static func forgetImplausibleFrame(
        defaults: UserDefaults = .standard,
        key: String? = nil
    ) {
        let key = key ?? "NSWindow Frame \(autosaveName)"
        guard let saved = defaults.string(forKey: key) else { return }
        let numbers = saved.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4 else {
            defaults.removeObject(forKey: key)
            return
        }
        if numbers[2] < minimumSensibleSize.width || numbers[3] < minimumSensibleSize.height {
            defaults.removeObject(forKey: key)
        }
    }
}
