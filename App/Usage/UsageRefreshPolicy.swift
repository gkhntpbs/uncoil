import Foundation

/// How busy the account is, which is the only thing that should decide how
/// often it is asked about.
///
/// A limit only moves when the agent is working. Polling an idle account on the
/// same schedule as a working one spends requests to re-read a number that
/// cannot have changed — and against a rate-limited endpoint, the monitor
/// becomes part of what it is monitoring.
enum UsageActivity: String, Equatable {
    /// An agent for this account is running right now.
    case active
    /// The app is open, the account has a session, nothing is running.
    case idle
    /// Nothing is using this account, or the app is not in front.
    case background
}

/// What the store knows about one account between refreshes.
struct UsageRefreshState: Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// Refreshes that have failed in a row. Reset by any success.
    var consecutiveFailures: Int = 0
    /// Set when the failure was about credentials. Retrying on a timer cannot
    /// fix it and every attempt is another chance to trip a lockout.
    var authenticationBlocked: Bool = false
    /// When the earliest window is due to reset, if any is known.
    var nextReset: Date?
}

/// Decides when the next refresh is due.
///
/// A pure function of state and time, kept separate from the store so the
/// behaviour that matters — backing off, not hammering a rejected credential,
/// waking just after a reset — can be tested without a network, a timer or a
/// clock that has to actually pass.
enum UsageRefreshPolicy {
    static let activeInterval: TimeInterval = 5 * 60
    static let idleInterval: TimeInterval = 20 * 60
    static let backgroundInterval: TimeInterval = 60 * 60

    /// First backoff step; doubles per consecutive failure.
    static let backoffBase: TimeInterval = 60
    static let backoffCeiling: TimeInterval = 30 * 60

    /// A reset makes the numbers change on their own, so it is worth one look
    /// shortly afterwards — but not at the instant, because the provider's
    /// clock and ours are not the same clock.
    static let postResetDelay: TimeInterval = 30

    static func interval(for activity: UsageActivity) -> TimeInterval {
        switch activity {
        case .active: activeInterval
        case .idle: idleInterval
        case .background: backgroundInterval
        }
    }

    /// When the next automatic refresh should happen, or `nil` if none should.
    ///
    /// `nil` is a real answer and the one that matters most: a rejected
    /// credential has no schedule. It is fixed by the user logging in again,
    /// and until then every timed attempt is noise that can only make things
    /// worse.
    static func nextRefresh(
        state: UsageRefreshState,
        activity: UsageActivity
    ) -> Date? {
        if state.authenticationBlocked { return nil }
        guard let lastAttempt = state.lastAttempt else { return .distantPast }

        if state.consecutiveFailures > 0 {
            let exponent = min(state.consecutiveFailures - 1, 8)
            let delay = min(backoffBase * pow(2, Double(exponent)), backoffCeiling)
            return lastAttempt.addingTimeInterval(delay)
        }

        let scheduled = lastAttempt.addingTimeInterval(interval(for: activity))
        // A reset that lands before the next scheduled poll is worth waiting
        // for instead: it is the one moment the numbers are known to move.
        if let reset = state.nextReset, reset > lastAttempt {
            let afterReset = reset.addingTimeInterval(postResetDelay)
            if afterReset < scheduled { return afterReset }
        }
        return scheduled
    }

    static func shouldRefresh(
        state: UsageRefreshState,
        activity: UsageActivity,
        now: Date
    ) -> Bool {
        guard let next = nextRefresh(state: state, activity: activity) else { return false }
        return now >= next
    }

    /// The state after an attempt.
    ///
    /// A refusal of the credential sets the block; anything else counts as a
    /// failure that will be retried more slowly. Success clears both, including
    /// the block — which is how a user who logs in again is picked up without
    /// having to tell the app they did.
    static func after(
        state: UsageRefreshState,
        outcome: UsageFetchOutcome,
        now: Date
    ) -> UsageRefreshState {
        var updated = state
        updated.lastAttempt = now

        if let snapshot = outcome.snapshot {
            updated.lastSuccess = now
            updated.consecutiveFailures = 0
            updated.authenticationBlocked = false
            updated.nextReset = snapshot.allWindows.compactMap(\.resetsAt).min()
            return updated
        }

        updated.consecutiveFailures += 1
        if let error = outcome.lastError,
           error.kind == .credentialsExpired || error.kind == .unauthorized
            || error.kind == .credentialsMissing {
            updated.authenticationBlocked = true
        }
        return updated
    }

    /// Clears the authentication block so a user-driven retry is always
    /// allowed. Asking for a refresh by hand is the user saying something has
    /// changed; refusing it because of an earlier failure would make the button
    /// stop working exactly when it is needed.
    static func unblocked(_ state: UsageRefreshState) -> UsageRefreshState {
        var updated = state
        updated.authenticationBlocked = false
        updated.consecutiveFailures = 0
        return updated
    }
}
