import AppKit
import SwiftUI

/// Everything the app has to start once, started once.
///
/// This lived in `MainWindow.onAppear`: a SwiftUI view opened the hook socket,
/// the MCP control-plane socket and the extension-secret socket, wired the
/// permission notifications and the child-session launcher, and kicked off the
/// binary resolution and the CLI update check. Three of those were guarded
/// against running twice; the rest were not, so a second window (⌘N) re-ran
/// the image pruning, re-resolved every binary, re-asked every CLI for its
/// version and reassigned the runtime daemon's alive-sessions callback out
/// from under the first window.
///
/// One object, one `start`, and the guard is the object rather than a flag per
/// effect. `MainWindow` is left with selection and layout.
@MainActor
final class AppServices {
    static let shared = AppServices()

    private var hasStarted = false
    /// The stores, once the app has them.
    ///
    /// Read by the menu bar's own commands, which are declared beside the
    /// scenes and so have no environment to take them from — a menu item that
    /// acts on the selected session needs the same stores the window uses, and
    /// this is the object that already owns the app-lifetime wiring.
    private(set) var projectStore: ProjectStore!
    private(set) var sessionStore: SessionStore!
    private(set) var settings: SettingsStore!

    private init() {}

    /// Starts the app's services against the stores. Calling it again — from a
    /// second window, or from the same window appearing twice — does nothing.
    func startIfNeeded(
        projectStore: ProjectStore,
        sessionStore: SessionStore,
        settings: SettingsStore
    ) {
        guard !hasStarted else { return }
        hasStarted = true
        self.projectStore = projectStore
        self.sessionStore = sessionStore
        self.settings = settings
        startServices()
    }

    private func startServices() {
        // Bound once, non-optionally, so the closures below capture the stores
        // rather than an optional that has to be unwrapped at every use.
        guard let projectStore, let sessionStore, let settings else { return }
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
                    projects.noteActivity(id)
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
            let unaccountedFor = sessionStore.reconcile(
                aliveSessionIDs: alive,
                records: projectStore.sessions,
                markEnded: { projectStore.markSessionEnded($0, exitCode: nil) }
            )
            // Sessions the daemon left out of this answer are shown as not yet
            // known, and asked about once more. Only the second silence counts
            // as a death — a daemon that answered mid-restart gets to correct
            // itself before the app closes a running agent on disk.
            guard !unaccountedFor.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                RuntimeClient.shared.requestSessionList()
            }
        }
        startControlPlane()
        // Drop directories whose sessions are gone. Once at start rather than
        // on a timer: the only thing that creates them is a session that no
        // longer exists, and that set does not change while the app runs.
        projectStore.pruneDroppedImages()
        Task {
            await settings.resolveBinaries()
            // Asked once at start so the badge on the settings button means
            // something before anyone opens Settings. It used to be asked only
            // by the Agents screen's own `.task`, which is to say only by
            // people who already suspected there was an update.
            await settings.checkCLIUpdates()
        }
    }

    /// Wires the two notification sources that are not the hook reducer:
    /// attention rows (failing tests, lost logins, finished tasks) and the
    /// repeat-reminder sweep for states nobody has answered.
    private func startNotificationBridges() {
        // Bound once, non-optionally, so the closures below capture the stores
        // rather than an optional that has to be unwrapped at every use.
        guard let projectStore, let sessionStore, let settings else { return }
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

        // Agents an Uncoil Auto conversation is directing report through that
        // conversation; how much they still notify on their own is its
        // setting. A session in no conversation is never touched here.
        sessionStore.directedNotificationFilter = { [weak store] sessionID, event in
            guard let store else { return false }
            let visible: UUID? = if case .session(let id) = Router.shared.currentSelection { id } else { nil }
            return DirectedAgentNotifications.mutes(
                event,
                mode: store.uncoilAuto.notifications,
                directors: UncoilAutoConversationState.conversations(directing: sessionID),
                visibleSessionID: visible,
                appIsActive: NSApp?.isActive ?? false)
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
                if case .session(let id) = Router.shared.currentSelection { return id }
                return nil
            }
        )
    }

    /// Starts the MCP control-plane socket server. Gated off under UI testing
    /// unless -control-plane is passed (mirrors the runtime daemon gating).
    private func startControlPlane() {
        // Bound once, non-optionally, so the closures below capture the stores
        // rather than an optional that has to be unwrapped at every use.
        guard let projectStore, let sessionStore, let settings else { return }
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
        // What a session created through the control plane may ask for is
        // what the new-session sheet offers: the installed CLIs and the
        // options each one documents.
        router.providerInstalled = { [weak settings] provider in
            if settings?.binaryPath(for: provider) != nil { return true }
            guard let name = provider.descriptor.cliBinaryName else { return false }
            return AgentAdapterSupport.locateBinary(name) != nil
        }
        router.launchCapabilities = { [weak settings] provider in
            await AgentLaunchCatalog.detect(
                provider: provider, binaryPath: settings?.binaryPath(for: provider))
        }

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
            SessionPromptDelivery.deliver(
                prompt ?? "", to: record, project: project,
                settings: settings, sessionStore: sessionStore,
                projectStore: projectStore)
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
        guard let sessionStore else { return }
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
