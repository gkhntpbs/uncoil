import Foundation

/// What changing a session's account actually does.
///
/// The account is not a setting the agent reads as it runs: it is a config
/// directory handed to the process in its environment (`CLAUDE_CONFIG_DIR`,
/// `CODEX_HOME`) at the moment it starts. So a running session cannot change
/// which login it is using, and a picker that silently pretended otherwise
/// would be the worst version of this feature — the user would believe they
/// had switched, and the agent would go on acting as the other account.
///
/// Pure so the honest answer is a test rather than something to notice later.
enum SessionAccountChange: Equatable {
    /// Nothing to do — same account.
    case unchanged
    /// Recorded; it takes effect the next time the session starts.
    case recorded
    /// Recorded, but the process is running under the old account and has to
    /// be restarted before the change means anything.
    case needsRestart

    /// - Parameters:
    ///   - current: the account the record carries now.
    ///   - chosen: what the user just picked.
    ///   - isRunning: whether the session's process is alive.
    static func classify(
        current: UUID?,
        chosen: UUID?,
        isRunning: Bool
    ) -> SessionAccountChange {
        guard current != chosen else { return .unchanged }
        return isRunning ? .needsRestart : .recorded
    }

    /// What the user is told. `nil` when there is nothing worth saying.
    var note: String? {
        switch self {
        case .unchanged: nil
        case .recorded: String(localized: "The session will start under this account.")
        case .needsRestart:
            String(
                localized: "Saved. The running agent keeps the account it started with — restart the session to switch it."
            )
        }
    }
}
