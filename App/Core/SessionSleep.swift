import Foundation

/// The two ways a session can stop using the machine.
///
/// They are not degrees of the same thing. Suspending signals a process that is
/// still there; hibernating ends it and rebuilds the session from the provider's
/// own resume. One is free and lossless, the other frees everything and depends
/// on the provider being able to bring the conversation back.
enum SessionSleepMode: String, Codable, Equatable, Sendable {
    /// SIGSTOP. The process stays in memory and resumes mid-thought.
    case suspended
    /// The process is gone. Waking relaunches it with its stored session id.
    case hibernated
}

/// What a session may be asked to do about sleeping, and what it costs.
///
/// Pure, because the interesting part is the refusals: a session with no
/// process cannot be suspended, and a provider that cannot resume must never be
/// offered hibernation — waking it would silently start a new conversation, and
/// calling that "resume" is the one outcome worse than not offering it.
enum SessionSleep {
    /// Reasons an action is unavailable. Shown, not swallowed: "the menu item
    /// is missing" is not an explanation.
    enum Refusal: Error, Equatable {
        /// The provider cannot bring its conversation back.
        case cannotResume
        /// Nothing has been launched, or it already exited.
        case notRunning
        /// Already asleep this way.
        case already(SessionSleepMode)

        var label: String {
            switch self {
            case .cannotResume:
                String(localized: "This agent cannot resume a conversation, so it cannot sleep.")
            case .notRunning:
                String(localized: "The session is not running.")
            case .already(.suspended):
                String(localized: "Already paused.")
            case .already(.hibernated):
                String(localized: "Already asleep.")
            }
        }
    }

    /// Whether a live process exists to signal or to kill.
    static func isRunning(_ status: AgentSessionStatus) -> Bool {
        switch status {
        case .idle, .thinking, .running, .waitingForPermission, .waitingForInput, .completed:
            true
        case .suspended, .hibernated, .terminated:
            false
        }
    }

    /// Suspending only signals a process, so it asks nothing of the provider —
    /// a plain shell suspends as well as an agent does.
    static func canSuspend(status: AgentSessionStatus) -> Result<Void, Refusal> {
        if status == .suspended { return .failure(.already(.suspended)) }
        guard isRunning(status) else { return .failure(.notRunning) }
        return .success(())
    }

    /// Hibernating ends the process, so the conversation has to be
    /// reconstructible: the provider must support resume *and* Uncoil must
    /// already hold the id to resume with.
    ///
    /// A suspended session may be hibernated — that is the natural escalation,
    /// and its process is still there to be ended.
    static func canHibernate(
        status: AgentSessionStatus,
        provider: AgentProvider,
        providerSessionID: String?
    ) -> Result<Void, Refusal> {
        if status == .hibernated { return .failure(.already(.hibernated)) }
        guard provider.resumesConversation else { return .failure(.cannotResume) }
        // Without an id there is nothing to resume with, whatever the provider
        // supports. This is the case for an agent that has not yet reported one.
        guard providerSessionID?.isEmpty == false else { return .failure(.cannotResume) }
        guard isRunning(status) || status == .suspended else { return .failure(.notRunning) }
        return .success(())
    }

    /// Whether a sleeping session can be brought back.
    static func canWake(status: AgentSessionStatus) -> Bool {
        status == .suspended || status == .hibernated
    }

    /// The status a session takes on when it goes to sleep.
    static func status(for mode: SessionSleepMode) -> AgentSessionStatus {
        switch mode {
        case .suspended: .suspended
        case .hibernated: .hibernated
        }
    }

    /// What waking has to do to the terminal.
    ///
    /// A suspended process never stopped owning its screen, so touching it
    /// would destroy exactly the state suspending preserved. A hibernated one
    /// comes back through `--resume`, which redraws the conversation itself —
    /// so the old scrollback has to go, or the user reads the same conversation
    /// twice and cannot tell which half is live.
    static func clearsTerminalOnWake(from mode: SessionSleepMode) -> Bool {
        switch mode {
        case .suspended: false
        case .hibernated: true
        }
    }

    /// Whether waking has to launch a process again, rather than signal one.
    static func relaunchesOnWake(from mode: SessionSleepMode) -> Bool {
        switch mode {
        case .suspended: false
        case .hibernated: true
        }
    }
}
