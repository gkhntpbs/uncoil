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
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var router = Router.shared
    @State private var selection: MainSelection?
    @State private var selectedSessionIDs: Set<UUID> = []
    /// Secondary session shown side-by-side (drop a session onto the view).
    @State private var splitSessionID: UUID?
    @State private var showFolderPicker = false
    /// The project whose extension selection is being asked for, right after it
    /// was added. Nil at every other moment.
    @State private var configuringNewProject: Project?
    /// The project a blueprint is being chosen for, from the palette.
    @State private var blueprintProject: Project?
    /// The project whose settings sheet is up.
    ///
    /// Presented by the window rather than by the sidebar: the sidebar is
    /// unmounted when it is hidden, and a sheet whose presenter can vanish is a
    /// shortcut that sometimes does nothing.
    @State private var projectSettings: Project?
    /// Shared, not per-sheet. `save()` serialises the whole registry document
    /// from memory, so a sheet with its own instance would discard whatever the
    /// last one wrote — see `ExtensionRegistry.shared`.
    @ObservedObject private var extensionRegistry = ExtensionRegistry.shared
    @State private var testWorkspaceError: String?
    @State private var debugBundleMessage: String?
    @State private var debugBundleURL: URL?
    @State private var runtimeCompatibilityError: String?
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Self.defaultSidebarWidth)
    @State private var dragStartWidth: Double?
    /// This window's identity, and everything that depends on knowing which
    /// window this is. Assigned once, when the window first appears.
    @ObservedObject private var windows = WindowRegistry.shared
    @State private var windowID: UUID?
    /// Non-nil while the "what should this window open on?" question is up.
    @State private var newWindowOptions: [NewWindowOption]?

    static let defaultSidebarWidth: Double = 252
    private static let hideThreshold: Double = 120

    var body: some View {
        // Split in two on purpose: as one chain this stopped type-checking in
        // reasonable time.
        surfaces
            .modifier(MainWindowSignals(
                selection: $selection,
                selectedSessionIDs: $selectedSessionIDs,
                windowID: windowID,
                onRoute: { openInThisWindow(projectID(of: $0)) },
                onAttention: { refreshAttention() },
                projectStore: projectStore,
                sessionStore: sessionStore,
                usage: usage
            ))
    }

    private var surfaces: some View {
        ZStack {
            mainContent
            if palette.isOpen {
                CommandPaletteOverlay(model: palette)
            }
            // Setup covers the app rather than sitting beside it: a half-set-up
            // window behind the flow is the state the flow exists to end.
            if router.isPresentingOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
            // Below setup on purpose: a machine that has never been set up has
            // nothing worth cloning, and two questions at once is one too many.
            if let newWindowOptions, !router.isPresentingOnboarding {
                NewWindowOverlay(options: newWindowOptions) { choice in
                    apply(choice)
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expressive, value: newWindowOptions == nil)
        // The palette used to appear and vanish outright: its transition never
        // ran because nothing animated the condition that mounts it.
        .animation(Theme.Motion.expressive, value: palette.isOpen)
        .animation(Theme.Motion.expressive, value: router.isPresentingOnboarding)
        .onChange(of: selection) { _, _ in
            syncPaletteSelection()
            persistSelection()
            syncOwnership()
        }
        .onChange(of: splitSessionID) { _, _ in syncOwnership() }
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
        .task { QuotaMonitor.shared.start(usage: usage, settings: settings) }
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
        AttentionRefresher.shared.setUsage(
            UsageAttentionCollector.snapshot(
                usage: usage,
                sessions: projectStore.sessions,
                statuses: sessionStore.statuses,
                accounts: settings.accounts,
                threshold: settings.usageWarningThreshold,
                isEnabled: settings.usageWarningsEnabled
            )
        )
        AttentionRefresher.shared.refresh(
            projectStore: projectStore,
            sessionStore: sessionStore
        )
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(
                        selection: $selection,
                        selectedSessionIDs: $selectedSessionIDs,
                        showFolderPicker: $showFolderPicker,
                        scope: projectScope,
                        openProject: { openInThisWindow($0) }
                    )
                    .frame(width: min(sidebarWidth, max(Self.defaultSidebarWidth, geometry.size.width - 320)))
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
                                                dragStartWidth = min(sidebarWidth, max(Self.defaultSidebarWidth, geometry.size.width - 320))
                                            }
                                            let proposed = (dragStartWidth ?? sidebarWidth)
                                                + value.translation.width
                                            sidebarWidth = min(max(Self.defaultSidebarWidth, geometry.size.width - 320), max(0, proposed))
                                        }
                                        .onEnded { _ in
                                            dragStartWidth = nil
                                            if sidebarWidth < Self.hideThreshold {
                                                sidebarVisible = false
                                                sidebarWidth = Self.defaultSidebarWidth
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
                if !router.isPresentingOnboarding {
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
            // `addProject` answers with the project it made. Reaching for
            // `projects.last` instead used to pick the scratch workspace, which
            // `sortProjects` keeps at the bottom, and picked the wrong project
            // again when the folder was already open.
            guard let added = projectStore.addProject(at: url) else { return }
            openInThisWindow(added.id)
            selection = .project(added.id)
            // Deferred by one turn: this runs from the open panel's own
            // completion, and asking the window for a second sheet while the
            // first is still tearing down gets the second one dropped.
            DispatchQueue.main.async { configuringNewProject = added }
        }
        .sheet(item: $configuringNewProject) { project in
            NewProjectSheet(project: project, registry: extensionRegistry)
        }
        .sheet(item: $projectSettings) { project in
            ProjectSettingsSheet(project: project)
        }
        // Asked for by the sidebar's context menu, the project header's gear,
        // the menu bar and the palette alike — one sheet, one presenter.
        //
        // Every window hears the request and exactly one answers, by the same
        // rule that routes a selection: otherwise the menu bar's Cmd-I would
        // raise a sheet in every open window at once.
        .onReceive(Router.shared.$projectSettingsCounter) { _ in
            guard let id = Router.shared.requestedProjectSettingsID,
                  let windowID,
                  windows.routeTarget(for: .project(id)) == windowID,
                  let project = projectStore.projects.first(where: { $0.id == id })
            else { return }
            _ = Router.shared.takeProjectSettings()
            projectSettings = project
        }
        .sheet(item: $blueprintProject) { project in
            ApplyBlueprintSheet(project: project)
        }
        .background(
            MainWindowFrame(
                windowID: windowID,
                slot: windowID.flatMap { windows.order.firstIndex(of: $0) }
            )
        )
        .onAppear {
            // Deferred: mutating @Published stores inside the first view
            // update triggers "Publishing changes from within view updates".
            DispatchQueue.main.async {
                LaunchConfig.shared.seedFixture(projectStore: projectStore)
                LaunchConfig.shared.seedAttentionFixture(
                    projectStore: projectStore, sessionStore: sessionStore
                )
                AppServices.shared.startIfNeeded(
                    projectStore: projectStore,
                    sessionStore: sessionStore,
                    settings: settings
                )
                adoptWindowIdentity()
                applyLaunchRoute()
                setupPalette()
                presentOnboardingIfNeeded()
                // Nothing else does it on the way in: every other trigger is a
                // change, and a limit that was already low at launch is not a
                // change.
                refreshAttention()
            }
        }
        .onDisappear {
            // Whatever this window held goes back into circulation, or the
            // sessions inside a closed window would stay locked to it.
            if let windowID {
                windows.unregister(windowID)
                PaletteHotkeyMonitor.forget(windowID)
            }
        }
    }

    // MARK: - Command palette

    private func setupPalette() {
        palette.configure(
            projectStore: projectStore,
            sessionStore: sessionStore,
            settingsPanes: SettingsView.Pane.searchable.map { ($0.id, $0.title) },
            launcherProviders: { [weak settings] in
                settings?.launcherProviders ?? AgentProvider.sessionKinds
            }
        )
        syncPaletteSelection()
        if let windowID { PaletteHotkeyMonitor.register(palette, for: windowID) }
        PaletteHotkeyMonitor.install(settings: settings)
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

    private var sessionActions: SessionActions {
        SessionActions(projects: projectStore, sessions: sessionStore)
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
                    openInThisWindow(project.id)
                    selection = .project(project.id)
                }
            } catch {
                testWorkspaceError = error.localizedDescription
            }
        case .createDebugBundle:
            do {
                let diagnostics = usage.entries.keys.sorted {
                    ($0.provider.rawValue + ($0.accountID?.uuidString ?? "")) < ($1.provider.rawValue + ($1.accountID?.uuidString ?? ""))
                }.map { usage.diagnostics(for: $0) }.joined(separator: "\n\n")
                let result = try DebugBundleService().create(usageDiagnostics: diagnostics)
                debugBundleURL = result.bundleURL
                debugBundleMessage = "Created: \(result.bundleURL.path)"
            } catch {
                debugBundleURL = nil
                debugBundleMessage = error.localizedDescription
            }
        case .openExtensions:
            openWindow(.extensions)
        case .openProject(let id):
            openInThisWindow(id)
            selection = .project(id)
        case .focusSession(let id):
            if let projectID = projectStore.sessions.first(where: { $0.id == id })?.projectID {
                openInThisWindow(projectID)
            }
            selection = .session(id)
        case .newSession(let projectID, let provider):
            launchSession(projectID: projectID, provider: provider)
        case .createWorktree(let projectID):
            selection = .project(projectID)
        case .applyBlueprint(let projectID):
            blueprintProject = projectStore.projects.first { $0.id == projectID }
        case .openSettings(let paneID):
            Router.shared.go(to: .settings(pane: paneID))
            openWindow(.settings)
        case .restartSession(let id):
            sessionActions.restart(id)
        case .closeSession(let id):
            sessionActions.close(id)
        case .popoutSession(let id):
            openWindow(.session, value: id)
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
            accountID: provider.isAgent ? account?.id : nil,
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
        SessionPromptDelivery.deliver(
            prompt, to: record, project: project,
            settings: settings, sessionStore: sessionStore, projectStore: projectStore,
            namesTheSession: true
        )
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
               let holder = sessionHolder(of: id) {
                // Drawn instead of the terminal, never beside it: mounting the
                // terminal here is what would take it out of the other window.
                SessionElsewhereView(
                    sessionTitle: record.displayTitle,
                    windowTitle: windows.title(of: holder, projectStore: projectStore),
                    reveal: { windows.reveal(holder) },
                    moveHere: {
                        guard let windowID else { return }
                        windows.take(id, by: windowID)
                    }
                )
                .id(record.id)
            } else if let record = projectStore.sessions.first(where: { $0.id == id }),
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
        SessionPromptDelivery.deliver(
            prompt, to: record, project: project,
            settings: settings, sessionStore: sessionStore, projectStore: projectStore
        )
    }

    /// Opens the first-run window on a machine that has never seen it — and on
    /// an upgrade that added steps. A UI-testing run only gets it when it asks.
    private func presentOnboardingIfNeeded() {
        let config = LaunchConfig.shared
        if config.isUITesting {
            if config.route == "onboarding" { Router.shared.go(to: .onboarding) }
            return
        }
        if settings.shouldPresentOnboarding {
            Router.shared.go(to: .onboarding)
        }
    }

    private func applyLaunchRoute() {
        let config = LaunchConfig.shared
        if config.route == "extensions" {
            // Deterministic way into the Extensions window: the section it opens
            // on is an argument rather than a click.
            Router.shared.go(to: .extensions(
                section: config.extensionsSection
                    .flatMap(ExtensionsView.Section.init(rawValue:)) ?? .overview
            ))
            openWindow(.extensions)
        }
        // An agent session in preference to the first one seeded. The route
        // exists to open "a session" for inspection, and the plain terminal —
        // which the demo fixture happens to create first — is the one with no
        // agent, no status, no account and no usage, so it shows the least of
        // what there is to look at.
        if config.route == "session",
           let record = projectStore.sessions.first(where: { $0.provider.isAgent })
            ?? projectStore.sessions.first {
            selection = .session(record.id)
            return
        }
        // A window that is still asking must not be answered for it, and a
        // restored one already has its selection back.
        guard newWindowOptions == nil else { return }
        if selection == nil,
           let first = projectScope.filter(projectStore.visibleProjects).first {
            selection = .project(first.id)
        }
    }

    private func persistSelection() {
        Router.shared.currentSelection = selection
        guard let windowID else { return }
        windows.setSelection(selection, for: windowID)
    }

    /// Only what still exists. A selection saved against a project that has
    /// since been removed would open a window onto nothing and call it restored.
    private func liveSelection(_ selection: MainSelection?) -> MainSelection? {
        switch selection {
        case .project(let id):
            return projectStore.projects.contains { $0.id == id } ? .project(id) : nil
        case .group(let id):
            return projectStore.sessionGroups.contains { $0.id == id } ? .group(id) : nil
        case .session(let id):
            return projectStore.sessions.contains { $0.id == id } ? .session(id) : nil
        case nil:
            return nil
        }
    }

    // MARK: - Windows

    /// Which projects this window shows.
    private var projectScope: WindowProjects {
        windowID.map { windows.scope(of: $0) } ?? .all
    }

    private func openInThisWindow(_ projectID: UUID?) {
        guard let windowID, let projectID else { return }
        windows.open(project: projectID, in: windowID)
    }

    private func projectID(of selection: MainSelection?) -> UUID? {
        switch selection {
        case .project(let id): id
        case .group(let id): projectStore.sessionGroups.first { $0.id == id }?.projectID
        case .session(let id): projectStore.sessions.first { $0.id == id }?.projectID
        case nil: nil
        }
    }

    /// The sessions this window is actually showing — the selected one, and
    /// the one in the split pane beside it.
    private var shownSessionIDs: Set<UUID> {
        var ids: Set<UUID> = []
        if case .session(let id) = selection { ids.insert(id) }
        if let splitSessionID { ids.insert(splitSessionID) }
        return ids
    }

    /// Keeps the ownership map equal to what is on screen.
    ///
    /// Navigating away from a session gives it up. It has to: the terminal is
    /// unmounted the moment the detail column shows something else, so a window
    /// that kept the claim would be holding a session it is not displaying and
    /// locking every other window out of it for the rest of the run.
    private func syncOwnership() {
        guard let windowID else { return }
        let shown = shownSessionIDs
        for held in windows.ownership.sessions(heldBy: windowID) where !shown.contains(held) {
            windows.release(held, from: windowID)
        }
        for id in shown {
            if case .heldElsewhere = windows.claim(id, by: windowID), id == splitSessionID {
                // The split pane has no room to explain itself and is a
                // convenience rather than a destination, so a session another
                // window holds simply does not open there.
                splitSessionID = nil
            }
        }
    }

    /// Who holds the selected session, when it is not this window.
    private func sessionHolder(of id: UUID) -> UUID? {
        guard let windowID,
              case .heldElsewhere(let other) = windows.ownership.outcome(claiming: id, by: windowID)
        else { return nil }
        return other
    }

    private func adoptWindowIdentity() {
        guard windowID == nil else { return }
        // Asked before registering, so the count reflects the saved
        // arrangement rather than this window having already joined it.
        let extras = windows.prepareRestore()
        let registration = windows.register()
        windowID = registration.id
        for _ in 0..<extras { openWindow(.main) }
        switch registration.mode {
        case .restored(let saved):
            selection = liveSelection(
                SelectionCoding.decode(kind: saved.selectionKind, id: saved.selectionID)
            )
            persistSelection()
            syncOwnership()
        case .first:
            break
        case .asks:
            newWindowOptions = NewWindowOptions.options(
                windows: windows.summaries(excluding: registration.id, projectStore: projectStore)
            )
        }
    }

    private func apply(_ choice: NewWindowChoice) {
        guard let windowID else { return }
        switch choice {
        case .empty:
            // Already `.some([])` from the moment the window registered, so
            // the question was never asked over a sidebar full of projects.
            selection = nil
        case .clone(let sourceID):
            windows.setScope(windows.scope(of: sourceID), for: windowID)
            selection = NewWindowOptions.clonedSelection(
                from: windows.selection(of: sourceID),
                projectOfSession: { id in
                    projectStore.sessions.first { $0.id == id }?.projectID
                }
            )
        }
        newWindowOptions = nil
        persistSelection()
        syncOwnership()
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

    /// Which window this is, once it knows. Nil until the window has adopted
    /// an identity, which is a turn or two after the view first appears.
    var windowID: UUID?
    /// Position in the open order. Frames are saved per slot rather than per
    /// id, because ids are minted fresh for hand-opened windows and a name
    /// nothing has ever been saved under restores nothing. Slots are stable:
    /// windows come back in the order they were written down.
    var slot: Int?

    /// One name per slot, so a second window does not land exactly on top of
    /// the first and look like nothing happened.
    static func autosaveName(slot: Int?) -> String {
        guard let slot, slot > 0 else { return autosaveName }
        return "\(autosaveName)-\(slot)"
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ probe: NSView, context: Context) {
        guard let windowID, !context.coordinator.placed else { return }
        context.coordinator.placed = true
        attach(probe, windowID: windowID, retries: 3)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var placed = false
    }

    /// The view is not in a window yet on the first turn of the run loop; a few
    /// attempts cost nothing and beat never restoring the frame at all.
    private func attach(_ probe: NSView, windowID: UUID, retries: Int) {
        DispatchQueue.main.async {
            guard let window = probe.window else {
                if retries > 0 { attach(probe, windowID: windowID, retries: retries - 1) }
                return
            }
            guard window.canBecomeMain else { return }
            // "Show That Window" needs something it can raise.
            WindowRegistry.shared.bind(window, to: windowID)
            let autosaveName = Self.autosaveName(slot: slot)
            let config = LaunchConfig.shared
            if let width = config.windowWidth, let height = config.windowHeight {
                // A UI-test launch is placed exactly, and never remembered.
                window.setFrame(
                    NSRect(x: 80, y: 120, width: width, height: height), display: true
                )
                return
            }
            Self.forgetImplausibleFrame(key: "NSWindow Frame \(autosaveName)")
            // With nothing saved, place it ourselves. `.defaultPosition(.center)`
            // centres the window's *origin* before its content size is known, so
            // the window then grows up and to the right and lands in the corner —
            // which is exactly where every fresh launch was starting.
            if !window.setFrameUsingName(autosaveName, force: true) {
                window.center()
                // A second window centred on the first is indistinguishable
                // from no new window at all.
                if let slot, slot > 0 {
                    let step = CGFloat(slot) * 28
                    window.setFrameOrigin(
                        NSPoint(x: window.frame.origin.x + step, y: window.frame.origin.y - step)
                    )
                }
            }
            window.setFrameAutosaveName(autosaveName)
            window.saveFrame(usingName: autosaveName)
        }
    }

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

/// The window's reactions to things happening elsewhere in the app.
///
/// Lifted out of `MainWindow.body` because as one chain it stopped
/// type-checking in reasonable time. Grouping them is also honest: these are
/// the app talking to a window, rather than the window drawing itself.
private struct MainWindowSignals: ViewModifier {
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    let windowID: UUID?
    let onRoute: (MainSelection) -> Void
    let onAttention: () -> Void
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject private var windows = WindowRegistry.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: projectStore.sessions.count) { _, _ in
                windows.pruneOwnership(sessions: Set(projectStore.sessions.map(\.id)))
            }
            .onChange(of: projectStore.projects.count) { _, _ in
                windows.pruneScopes(projects: Set(projectStore.projects.map(\.id)))
            }
            .onChange(of: sessionStore.statuses) { _, _ in onAttention() }
            .onChange(of: sessionStore.codexAuthentication) { _, _ in onAttention() }
            // A limit falling is a change nothing else announces: no status
            // moves and no session ends, so without this the warning waited
            // for an unrelated event and arrived whenever one happened to
            // come.
            .onChange(of: usage.entries) { _, _ in onAttention() }
            .onReceive(Router.shared.$selectionCounter) { _ in
                guard let requested = Router.shared.requestedSelection else { return }
                // Every window hears this. Exactly one answers it, or a single
                // click from the menu bar would rearrange the whole desktop.
                guard let windowID,
                      windows.routeTarget(for: requested) == windowID else { return }
                selectedSessionIDs.removeAll()
                // "Show me this" means show it: a window asked for something it
                // does not list opens it rather than refusing.
                onRoute(requested)
                selection = requested
                _ = Router.shared.takeSelection()
                windows.reveal(windowID)
            }
    }
}
