import Foundation

/// Which of an agent's sessions a restart would actually touch.
///
/// Kept apart from the restarting itself so the count offered in the interface
/// — "restart 3 Claude sessions" — is produced by the same rule that decides
/// what gets restarted, and is testable without a terminal.
enum AgentProcessRestart {
    /// Sessions belonging to `provider` that have a process to restart.
    ///
    /// A session that is asleep is skipped rather than woken: hibernation
    /// already killed its process, so it will come back on the new version the
    /// next time it is opened, and waking every sleeping session to restart it
    /// would undo the thing the user asked for when they put it to sleep.
    static func targets(
        sessions: [SessionRecord],
        provider: AgentProvider,
        isLive: (UUID) -> Bool,
        isAsleep: (UUID) -> Bool
    ) -> [UUID] {
        sessions
            .filter { $0.provider == provider && !isAsleep($0.id) && isLive($0.id) }
            .map(\.id)
    }

    /// What to say on the button, or nil when there is nothing to restart.
    static func offer(count: Int, provider: AgentProvider) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return String(localized: "Restart the running \(provider.displayName) session")
        }
        return String(localized: "Restart \(count) running \(provider.displayName) sessions")
    }
}
