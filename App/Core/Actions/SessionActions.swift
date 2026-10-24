import Foundation

/// The verbs that act on a session, written once.
///
/// Restart existed in five places and had already drifted: the palette and the
/// group view bumped the restart counter every store watches, while the session
/// screen bumped a `@State` counter of its own — so restarting from the header
/// rebuilt one terminal view and left every other copy of the session showing
/// the dead one. Closing a session existed three times, deleting one three
/// more, and each copy decided for itself whether the process was killed first.
///
/// A struct over the two stores rather than a singleton: a view already has
/// both in its environment, and the tests construct them directly.
@MainActor
struct SessionActions {
    let projects: ProjectStore
    let sessions: SessionStore

    /// Kills the process and starts it again in place, keeping the record.
    ///
    /// The counter is what every view watching this session rebuilds on, so a
    /// restart from anywhere reaches the split pane, the popout and the header
    /// alike.
    func restart(_ id: UUID) {
        TerminalRegistry.shared.closeTerminal(for: id)
        projects.updateSession(id) { $0.lastActivityAt = .now }
        // Codex holds its thread's lock until the old process has exited, and
        // a relaunch that looks before then reads the thread as taken and
        // starts fresh. So the relaunch waits for the lock — briefly, off the
        // main thread — and only then rebuilds the terminal.
        if let lock = codexThreadLock(of: id) {
            let sessions = sessions
            Task { @MainActor in
                await CodexSessionStore.waitUntilReleased(codexHome: lock.home, threadID: lock.threadID)
                sessions.bumpRestart(id)
            }
        } else {
            sessions.bumpRestart(id)
        }
    }

    private func codexThreadLock(of id: UUID) -> (home: URL, threadID: String)? {
        guard let record = projects.sessions.first(where: { $0.id == id }),
              record.provider == .codex,
              let threadID = record.providerSessionID, !threadID.isEmpty
        else { return nil }
        let settings: SettingsStore? = AppServices.shared.settings
        let home = settings.flatMap { settings in
            settings.account(id: record.accountID)?
                .configDirectory(profilesRoot: settings.profilesRootURL)
        } ?? CodexSessionStore.defaultHome()
        return (home, threadID)
    }

    func restart(_ ids: some Sequence<UUID>) {
        for id in ids { restart(id) }
    }

    /// Ends the session but keeps its record, so it stays in the history.
    func close(_ id: UUID) {
        TerminalRegistry.shared.closeTerminal(for: id)
        sessions.setStatus(.terminated, for: id)
        projects.markSessionEnded(id, exitCode: nil)
    }

    /// Ends the session and forgets it. The process is closed first: removing
    /// the record while the process runs leaves a terminal nothing owns.
    func delete(_ id: UUID) {
        TerminalRegistry.shared.closeTerminal(for: id)
        projects.removeSession(id)
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids { TerminalRegistry.shared.closeTerminal(for: id) }
        projects.removeSessions(ids)
    }
}
