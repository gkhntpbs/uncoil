import Foundation

extension UncoilAutoEnvironment {
    /// The environment of an Uncoil Auto session in the running app: the
    /// project's own sessions, started and typed into the way the rest of the
    /// app starts and types into them.
    static func live(
        sessionID: UUID,
        projectID: UUID,
        projects: ProjectStore,
        sessions: SessionStore,
        settings: SettingsStore
    ) -> UncoilAutoEnvironment {
        func project() -> Project? { projects.projects.first { $0.id == projectID } }
        func record(_ id: UUID) -> SessionRecord? { projects.sessions.first { $0.id == id } }
        func roster() -> [UncoilAutoRoster.Entry] {
            UncoilAutoRoster.entries(
                sessions: projects.sessions.filter { $0.projectID == projectID },
                installed: settings.installedProviders)
        }
        func ensureRunning(_ id: UUID) {
            guard let record = record(id), let project = project() else { return }
            TerminalRegistry.shared.ensureSession(
                for: record, project: project, account: settings.account(id: record.accountID),
                settings: settings, sessionStore: sessions, projectStore: projects)
        }
        return UncoilAutoEnvironment(
            roster: roster,
            startSession: { provider in
                guard let project = project() else { return nil }
                let record = SessionLauncher(projects: projects, settings: settings)
                    .launch(SessionLaunchRequest(project: project, provider: provider))
                ensureRunning(record.id)
                return roster().first { $0.sessionID == record.id }
            },
            ensureRunning: ensureRunning,
            deliver: { text, id, provider in
                await TerminalRegistry.shared.submitText(text, for: id, provider: provider)
            },
            deliverQuietly: { text, id, provider in
                await TerminalRegistry.shared.submitText(text, for: id, provider: provider, namesTheSession: false)
            },
            allows: { [weak settings] provider in
                guard let settings else { return false }
                return UncoilAutoConversationState.for(sessionID).allows(provider, settings: settings.uncoilAuto)
            },
            autoSettings: { [weak settings] in settings?.uncoilAuto.harness ?? AutoHarnessSettings() },
            quotaScore: { entry in
                QuotaMonitor.shared.routingScore(for: entry, records: projects.sessions, settings: settings)
            },
            harness: { main, deliver in
                AutoHarnessEnvironment.live(
                    projectID: projectID, projects: projects, sessions: sessions, settings: settings,
                    main: main, deliver: deliver)
            },
            interrupt: { TerminalRegistry.shared.interrupt($0) },
            isWorking: { sessions.status(of: $0).isWorking },
            follow: { id in
                NativeSessionObservers.shared.retain(
                    id, locate: NativeTranscriptLocation.locator(for: id, projects: projects, settings: settings))
            },
            unfollow: { NativeSessionObservers.shared.release($0) },
            position: { NativeSessionObservers.shared.position(for: $0) },
            catchUp: { id, position in
                guard let location = NativeTranscriptLocation.locator(
                    for: id, projects: projects, settings: settings)() else { return nil }
                return NativeTranscriptWatcher.read(location, from: position)
            },
            pollTranscripts: { NativeSessionObservers.shared.pollNow() }
        )
    }
}

extension NativeTranscriptLocation {
    /// Looks the session up afresh on every call: the conversation it is
    /// bound to can arrive, or change, after following began.
    @MainActor
    static func locator(
        for sessionID: UUID, projects: ProjectStore, settings: SettingsStore
    ) -> () -> NativeTranscriptLocation? {
        { [weak projects, weak settings] in
            guard let projects, let settings,
                  let record = projects.sessions.first(where: { $0.id == sessionID }),
                  let project = projects.projects.first(where: { $0.id == record.projectID }) else { return nil }
            return resolve(
                record: record, project: project,
                account: settings.account(id: record.accountID),
                profilesRoot: settings.profilesRootURL)
        }
    }
}
