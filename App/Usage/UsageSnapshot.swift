import Foundation

// MARK: - Window

/// One usage window a provider reports: a session limit, a weekly limit, a
/// model-scoped limit.
///
/// `usedPercent` is the only quantity stored. Providers disagree about which
/// half they report — Codex and Claude send utilisation, Gemini sends the
/// remainder — and keeping both would let the two drift apart in a type whose
/// whole job is to be trusted. The other half is derived.
///
/// `resetsAt` is an absolute instant, never a rendered phrase. "Resets in 2h
/// 14m" is a thing to say at a particular moment; storing it would freeze a
/// countdown that has to keep counting.
struct UsageWindow: Identifiable, Codable, Equatable {
    /// Stable within a snapshot, so a view can follow one window across
    /// refreshes rather than re-identifying it by position.
    let id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    /// What the provider said about the reset when it did not give an instant —
    /// "Resets 3:00pm", "Resets Nov 5".
    ///
    /// Kept as the provider's own words rather than parsed into a date on a
    /// guess. A phrase like "3:00pm" is missing the day and the year, and the
    /// wrong answer to those is a countdown that runs backwards. Quoting it
    /// keeps the information without claiming to have understood it.
    var resetNote: String?
    /// Length of the window when the provider states it — five hours, seven
    /// days. Absent means the provider did not say, which is not the same as
    /// zero.
    var windowMinutes: Int?
    /// Set when the window is scoped to one model rather than the account.
    var modelID: String?

    init(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        resetNote: String? = nil,
        windowMinutes: Int? = nil,
        modelID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.usedPercent = Self.clamp(usedPercent)
        self.resetsAt = resetsAt
        self.resetNote = resetNote
        self.windowMinutes = windowMinutes
        self.modelID = modelID
    }

    /// Built from a provider that reports what is left rather than what is
    /// used, as a fraction of one.
    static func fromRemainingFraction(
        id: String,
        title: String,
        remainingFraction: Double,
        resetsAt: Date? = nil,
        resetNote: String? = nil,
        windowMinutes: Int? = nil,
        modelID: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            title: title,
            usedPercent: 100 - clamp(remainingFraction * 100),
            resetsAt: resetsAt,
            resetNote: resetNote,
            windowMinutes: windowMinutes,
            modelID: modelID
        )
    }

    var remainingPercent: Double { 100 - usedPercent }

    /// A provider that reports 103% has not given us a percentage; clamping is
    /// the only reading that does not produce a negative remainder downstream,
    /// where the number becomes a decision.
    ///
    /// A value that is not a number at all should never reach here — the JSON
    /// reader drops it and no window is built. This is the backstop, and it
    /// errs towards *exhausted* rather than *plenty*: an early warning about a
    /// limit that is fine costs a glance, while a fabricated "100% remaining"
    /// would let work run into a wall the app said was not there.
    private static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 100 }
        return min(100, max(0, value))
    }
}

// MARK: - Credits

/// Money, not quota. Kept apart deliberately: credits buy usage beyond the
/// subscription window, so adding them to a percentage would answer "how much
/// is left" with two different currencies at once.
struct UsageCredits: Codable, Equatable {
    var balance: Double?
    var currency: String?
    /// Free-form label when the provider describes credits without a number.
    var summary: String?
}

// MARK: - Identity

/// Who the snapshot belongs to, as the provider itself describes it.
///
/// Scoped per provider and account on purpose. One provider's email or plan
/// must never appear beside another's numbers — the whole point of the account
/// dimension is that two of them have separate limits.
struct UsageIdentity: Codable, Equatable {
    var email: String?
    var plan: String?
    var organization: String?
}

// MARK: - Source

/// Which strategy actually produced the data. Recorded because the same
/// provider can answer from several places with different freshness and
/// different reliability, and "where did this come from" is the first question
/// asked when a number looks wrong.
enum UsageSource: String, Codable, Equatable {
    case codexOAuthAPI
    case codexAppServerRPC
    case codexStatusTUI
    case claudeOAuthAPI
    case claudeCLIProbe
    case claudeWebSession
    case geminiCodeAssistAPI
    case cache

    var providerLabel: String {
        switch self {
        case .codexOAuthAPI, .codexAppServerRPC, .codexStatusTUI: "Codex"
        case .claudeOAuthAPI, .claudeCLIProbe, .claudeWebSession: "Claude"
        case .geminiCodeAssistAPI: "Gemini"
        case .cache: "cache"
        }
    }
}

// MARK: - Unavailability

/// Why a provider has no numbers for this account.
///
/// This exists so that "we cannot know" has a value of its own. Without it the
/// only ways to say it are a zero and a hundred, and both are answers to a
/// different question — one of which will eventually be used to decide whether
/// to hand work to another agent.
enum UsageUnavailability: String, Codable, Equatable {
    /// Nothing on disk or in the Keychain to authenticate with.
    case noCredentials
    /// Credentials found, but the provider rejected them.
    case credentialsRejected
    /// The account authenticates fine and the provider states it reports no
    /// quota for it — some organisation and education plans.
    case planReportsNoQuota
    /// The provider withdrew this route for this class of account. Gemini's
    /// consumer tiers as of 18 June 2026.
    case accountTierUnsupported
    /// The authentication in use is not the one this route reads — an API key
    /// or Vertex configuration rather than the CLI's OAuth state.
    case authenticationTypeUnsupported
    /// Uncoil has no route to this provider's usage at all.
    case providerUnsupported
    /// Every strategy failed for a reason that may not last.
    case allStrategiesFailed
}

// MARK: - Snapshot

/// What one account's usage looks like, normalised across providers.
///
/// A snapshot always says three things beyond the numbers: where it came from,
/// when it was taken, and whether it is still believed to be current. A caller
/// that cannot tell fresh data from an eighteen-minute-old copy will show the
/// old one as though it were now.
struct UsageSnapshot: Codable, Equatable {
    var provider: AgentProvider
    /// Uncoil's own account id, so two profiles of the same provider never
    /// share a snapshot.
    var accountID: UUID?
    var identity: UsageIdentity?

    /// The short-term window — a session, a five-hour block.
    var primaryWindow: UsageWindow?
    /// The long-term window — weekly, monthly.
    var secondaryWindow: UsageWindow?
    /// Model-scoped and additional windows, kept raw rather than folded into
    /// the two above: a provider that adds a model next year should not need
    /// this type redesigned.
    var extraWindows: [UsageWindow]

    var credits: UsageCredits?

    var source: UsageSource
    var updatedAt: Date
    /// True when this is a retained earlier snapshot rather than the result of
    /// the refresh that just ran.
    var stale: Bool
    /// Set when the provider has no numbers for this account, and why.
    var unavailable: UsageUnavailability?
    /// Why the most recent refresh failed, when a stale snapshot is being kept.
    var error: String?

    init(
        provider: AgentProvider,
        accountID: UUID? = nil,
        identity: UsageIdentity? = nil,
        primaryWindow: UsageWindow? = nil,
        secondaryWindow: UsageWindow? = nil,
        extraWindows: [UsageWindow] = [],
        credits: UsageCredits? = nil,
        source: UsageSource,
        updatedAt: Date,
        stale: Bool = false,
        unavailable: UsageUnavailability? = nil,
        error: String? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.identity = identity
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.extraWindows = extraWindows
        self.credits = credits
        self.source = source
        self.updatedAt = updatedAt
        self.stale = stale
        self.unavailable = unavailable
        self.error = error
    }

    /// A provider that authenticates but reports nothing. Carries a reason
    /// rather than a number, which is the entire reason this initialiser is
    /// separate from the one above.
    static func unavailable(
        provider: AgentProvider,
        accountID: UUID? = nil,
        identity: UsageIdentity? = nil,
        reason: UsageUnavailability,
        source: UsageSource,
        updatedAt: Date,
        error: String? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            accountID: accountID,
            identity: identity,
            source: source,
            updatedAt: updatedAt,
            unavailable: reason,
            error: error
        )
    }

    /// Every window, in the order a reader would want them.
    var allWindows: [UsageWindow] {
        [primaryWindow, secondaryWindow].compactMap { $0 } + extraWindows
    }

    /// True when there is at least one real number to show. A snapshot can be
    /// successful, recent and still have nothing in it.
    var hasQuota: Bool { !allWindows.isEmpty }

    /// The window closest to running out — what an "8% remaining" line should
    /// be drawn from, since the account is limited by whichever binds first.
    var mostConstrainedWindow: UsageWindow? {
        allWindows.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The same snapshot, marked as a retained copy with the reason the latest
    /// refresh failed. Keeping the old numbers beats replacing them with
    /// zeroes; saying they are old is what makes that honest.
    func markedStale(error: String?) -> UsageSnapshot {
        var copy = self
        copy.stale = true
        copy.error = error
        return copy
    }

    /// How old the numbers are, regardless of when we last tried to refresh.
    func age(now: Date) -> TimeInterval { now.timeIntervalSince(updatedAt) }
}
