import Foundation

/// Turning a snapshot into words and a colour band.
///
/// Separate from the model on purpose. The model keeps absolute instants and a
/// single percentage; "Resets in 2h 14m" is a thing that is only true at a
/// particular moment, and freezing it into the data would stop a countdown that
/// has to keep counting. Everything here is a pure function of a snapshot and a
/// clock, so what the user reads can be tested without a view.
enum UsageDisplay {
    static func windowTitle(_ title: String) -> String {
        let prefix = "Weekly limit · "
        if title.hasPrefix(prefix) {
            let model = String(title.dropFirst(prefix.count))
            return String(localized: "Weekly limit · \(model)")
        }
        return NSLocalizedString(title, comment: "")
    }

    static func refreshFailure(_ error: String) -> String {
        if error.hasPrefix("credentialsExpired") || error.hasPrefix("unauthorized") {
            return String(localized: "The saved login expired or was rejected. Sign in again with the agent CLI, then refresh here. You do not need to add a separate Uncoil account. Previous usage is shown until a new reading succeeds.")
        }
        return String(localized: "Last refresh failed (\(error)); showing the previous reading.")
    }


    // MARK: - Severity

    /// How close a window is to running out, in the three bands a colour can
    /// actually carry.
    ///
    /// Deliberately coarse. A gradient over a hundred values says nothing a
    /// glance can use, and the only question the chip has to answer at a glance
    /// is whether the work in front of you is about to stop.
    enum Severity: String, Equatable {
        case healthy
        case low
        case critical
        /// No number at all — not a band, and never drawn as one.
        case unknown

        /// The default threshold for `.critical`, and the number the handoff
        /// feature will eventually take its cue from.
        static let criticalPercent: Double = 15
        static let lowPercent: Double = 40

        /// `critical` is the user's own threshold, so the colour in the header
        /// and the row in the Attention Center agree about what "low" means.
        /// Two definitions of the same word would have the chip go red while
        /// nothing was reported, or the other way round.
        static func forRemaining(_ percent: Double?, threshold: Double = criticalPercent) -> Severity {
            guard let percent else { return .unknown }
            if percent <= threshold { return .critical }
            if percent <= max(threshold, lowPercent) { return .low }
            return .healthy
        }
    }

    /// The band a whole snapshot sits in: whichever window binds first.
    static func severity(
        of snapshot: UsageSnapshot?, threshold: Double = Severity.criticalPercent
    ) -> Severity {
        guard let snapshot, let window = snapshot.mostConstrainedWindow else { return .unknown }
        // A provider that has refused the account is red whatever is left in
        // the windows — the numbers are no longer what decides.
        if snapshot.limitReached { return .critical }
        return .forRemaining(window.remainingPercent, threshold: threshold)
    }

    /// The number the chip shows, or nil when there is none to show.
    static func headlineRemaining(_ snapshot: UsageSnapshot?) -> Int? {
        guard let window = snapshot?.mostConstrainedWindow else { return nil }
        // Rounded down, so 8.9% reads as 8. A limit is not a place to be
        // generous with rounding: the number is there to warn.
        return Int(window.remainingPercent.rounded(.down))
    }

    // MARK: - Time

    /// "in 2h 14m", "in 3d", "now".
    ///
    /// Coarse by design: a window that resets in three days does not need
    /// minutes, and a countdown accurate to the second would redraw for no
    /// reason. A reset already in the past reads as due rather than negative —
    /// the provider's clock and ours are not the same clock, and a "-4s" would
    /// be reporting that difference as news.
    static func relativeReset(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 30 else { return String(localized: "now") }
        return String(localized: "in \(duration(seconds))")
    }

    /// "2 min ago", "just now".
    static func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds > 45 else { return String(localized: "just now") }
        return String(localized: "\(duration(seconds)) ago")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 3600 { return String(localized: "\(max(1, total / 60))m") }
        if total < 86_400 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? String(localized: "\(hours)h") : String(localized: "\(hours)h \(minutes)m")
        }
        return String(localized: "\(total / 86_400)d")
    }

    /// What a window's reset line says, from whichever of the two forms the
    /// provider gave. An instant is preferred; a phrase is quoted as it came.
    static func resetLine(_ window: UsageWindow, now: Date) -> String? {
        if let date = window.resetsAt {
            return String(localized: "Resets \(relativeReset(date, now: now))")
        }
        return window.resetNote
    }

    // MARK: - Provenance

    /// Where the figure came from, in words rather than an enum case.
    ///
    /// Shown because the same provider answers from more than one place with
    /// different reliability, and "where did this come from" is the first
    /// question asked when a number looks wrong.
    static func sourceLabel(_ source: UsageSource) -> String {
        switch source {
        case .codexOAuthAPI: String(localized: "from your Codex account")
        case .codexAppServerRPC: String(localized: "from the Codex app-server")
        case .codexStatusTUI: String(localized: "from Codex's status panel")
        case .claudeOAuthAPI: String(localized: "from your Claude account")
        case .claudeCLIProbe: String(localized: "from the Claude CLI")
        case .claudeWebSession: String(localized: "from your claude.ai session")
        case .geminiCodeAssistAPI: String(localized: "from Gemini Code Assist")
        case .cache: String(localized: "from Uncoil's last reading")
        }
    }

    /// The footer line: which account, where it came from, and how old it is.
    ///
    /// The account is named because "your Codex account" is not an answer when
    /// there is more than one of them, and this line is the one place that says
    /// where a figure came from. Named only when the name adds something —
    /// repeating the provider back at the reader would be noise.
    ///
    /// A snapshot with nothing in it gets the last part only. "From your Claude
    /// account · 1m ago" under the words "No usage figures" claims a reading
    /// that was never made; what happened is that we looked, and that is what
    /// it should say.
    static func provenance(_ snapshot: UsageSnapshot, accountName: String?, now: Date) -> String {
        let age = relativeAge(snapshot.updatedAt, now: now)
        guard snapshot.unavailable == nil else {
            return String(localized: "Checked \(age)")
        }
        var source = sourceLabel(snapshot.source)
        if let accountName, !accountName.isEmpty,
           accountName.caseInsensitiveCompare(snapshot.provider.displayName) != .orderedSame {
            source += " (\(accountName))"
        }
        return "\(source) · \(age)"
    }

    // MARK: - Unavailability

    /// Why there is no number, in a sentence that says what to do about it.
    ///
    /// Each of these is a different situation and only two of them are the
    /// user's to fix. Collapsing them into "usage unavailable" would send
    /// someone to check a login that is working perfectly well.
    static func explanation(_ reason: UsageUnavailability, provider: AgentProvider) -> String {
        switch reason {
        case .noCredentials:
            provider == .claude
                ? String(localized: "Claude Code's saved login could not be read. If you are already signed in to the CLI, refresh here and allow the macOS Keychain request. A separate Uncoil profile is not required.")
                : String(localized: "Not signed in to \(provider.displayName) on this Mac.")
        case .credentialsRejected:
            String(localized: "\(provider.displayName) refused the saved login. Signing in again will fix it.")
        case .planReportsNoQuota:
            String(localized: "This plan reports no usage limits. Nothing is wrong — there is simply no figure to show.")
        case .accountTierUnsupported:
            String(localized: "\(provider.displayName) no longer reports usage for this kind of account. Your allowance is unaffected; it just cannot be read from here.")
        case .authenticationTypeUnsupported:
            String(localized: "Usage can only be read from a signed-in \(provider.displayName) account, not from an API key or a Vertex AI project.")
        case .providerUnsupported:
            String(localized: "Uncoil has no way to read usage for \(provider.displayName).")
        case .allStrategiesFailed:
            String(localized: "Could not reach \(provider.displayName) to read usage.")
        }
    }

    /// One short line for the chip's tooltip, where a sentence is too much.
    static func shortReason(_ reason: UsageUnavailability) -> String {
        switch reason {
        case .noCredentials: String(localized: "Not signed in")
        case .credentialsRejected: String(localized: "Sign in again")
        case .planReportsNoQuota: String(localized: "No limits on this plan")
        case .accountTierUnsupported: String(localized: "Not reported for this account")
        case .authenticationTypeUnsupported: String(localized: "Not reported for this sign-in")
        case .providerUnsupported: String(localized: "Not supported")
        case .allStrategiesFailed: String(localized: "Could not be read")
        }
    }

    /// The chip's tooltip: enough to act on without opening the card.
    static func chipHelp(_ snapshot: UsageSnapshot?, now: Date) -> String {
        guard let snapshot else { return String(localized: "Usage has not been read yet.") }
        if let reason = snapshot.unavailable {
            return "\(String(localized: "Usage unavailable")) — \(shortReason(reason))"
        }
        guard let window = snapshot.mostConstrainedWindow else {
            return String(localized: "No usage figures.")
        }
        let title = windowTitle(window.title)
        let remaining = Int(window.remainingPercent.rounded(.down))
        var line = String(localized: "\(title): \(remaining)% left")
        if let reset = resetLine(window, now: now) { line += " · \(reset)" }
        if snapshot.stale {
            line += " · " + String(localized: "not refreshed, \(relativeAge(snapshot.updatedAt, now: now))")
        }
        return line
    }
}
