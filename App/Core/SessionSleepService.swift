import Foundation

/// Carries out what `SessionSleep` decides.
///
/// One place, because putting a session to sleep touches four things that must
/// agree — the daemon or the terminal registry, the persisted record, the live
/// status, and the terminal view — and doing it from each call site is how they
/// drift apart.
@MainActor
enum SessionSleepService {
    /// Puts a session to sleep. Returns the refusal instead of acting when the
    /// state does not allow it, so a caller can say why.
    @discardableResult
    static func sleep(
        _ record: SessionRecord,
        mode: SessionSleepMode,
        projectStore: ProjectStore,
        sessionStore: SessionStore
    ) -> SessionSleep.Refusal? {
        let status = sessionStore.status(of: record.id)
        let allowed: Result<Void, SessionSleep.Refusal> = switch mode {
        case .suspended:
            SessionSleep.canSuspend(status: status)
        case .hibernated:
            SessionSleep.canHibernate(
                status: status,
                provider: record.provider,
                providerSessionID: record.providerSessionID
            )
        }
        if case .failure(let refusal) = allowed { return refusal }

        switch mode {
        case .suspended:
            RuntimeClient.shared.setSuspended(true, sid: record.id)
        case .hibernated:
            TerminalRegistry.shared.hibernateTerminal(for: record.id)
        }
        projectStore.markSessionAsleep(record.id, mode: mode)
        sessionStore.setStatus(SessionSleep.status(for: mode), for: record.id)
        return nil
    }

    /// Brings a sleeping session back.
    ///
    /// A suspended process is signalled and picks up mid-thought. A hibernated
    /// one is relaunched: bumping the restart counter rebuilds the terminal
    /// view, and the launch path already writes the provider's resume flag when
    /// a session id is known — which is both why the old scrollback has to go
    /// and how the conversation comes back.
    static func wake(
        _ record: SessionRecord,
        projectStore: ProjectStore,
        sessionStore: SessionStore
    ) {
        guard let mode = record.sleepMode else { return }
        if SessionSleep.relaunchesOnWake(from: mode) {
            TerminalRegistry.shared.clearHibernating(record.id)
            sessionStore.bumpRestart(record.id)
        } else {
            RuntimeClient.shared.setSuspended(false, sid: record.id)
        }
        projectStore.markSessionAwake(record.id)
        sessionStore.setStatus(.idle, for: record.id)
    }

    /// Restores the status of sessions that were asleep when the app quit.
    ///
    /// A reopened record otherwise starts as `.terminated`, which would show a
    /// session the user deliberately put to sleep as one that died.
    static func restoreStatuses(
        projectStore: ProjectStore,
        sessionStore: SessionStore
    ) {
        for record in projectStore.sessions {
            guard let mode = record.sleepMode, record.endedAt == nil else { continue }
            // A hibernated session has no process to lose, so it survives a
            // quit. A suspended one does not: its stopped process belonged to
            // the daemon, and if the daemon went too there is nothing left to
            // signal — so it is recorded as hibernated, which is what it now is.
            if mode == .suspended, !RuntimeClient.shared.isAlive(sid: record.id) {
                projectStore.markSessionAsleep(record.id, mode: .hibernated)
                sessionStore.setStatus(.hibernated, for: record.id)
                continue
            }
            sessionStore.setStatus(SessionSleep.status(for: mode), for: record.id)
        }
    }
}
