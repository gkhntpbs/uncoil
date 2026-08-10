import Foundation

/// One account of one provider — what a snapshot belongs to.
struct UsageKey: Hashable, Codable {
    var provider: AgentProvider
    var accountID: UUID?
}

/// Everything the app knows about one account's usage, including how it knows.
///
/// The three timestamps are separate on purpose. `snapshot.updatedAt` is how
/// old the *numbers* are; `lastAttempt` is when we last tried; `lastSuccess` is
/// when trying last worked. A UI with only the first cannot tell a figure that
/// is current from one that has been failing to refresh for twenty minutes, and
/// those are the two states most worth telling apart.
struct UsageEntry: Equatable {
    var snapshot: UsageSnapshot?
    var refresh: UsageRefreshState = .init()
    /// The most recent pipeline run, kept for diagnostics.
    var attempts: [UsageAttempt] = []
    var isRefreshing: Bool = false

    var lastAttempt: Date? { refresh.lastAttempt }
    var lastSuccessfulRefresh: Date? { refresh.lastSuccess }
    var source: UsageSource? { snapshot?.source }
    var isStale: Bool { snapshot?.stale ?? false }
    var error: String? { snapshot?.error }
}

/// The usage layer's front door.
///
/// It owns the cache, decides when to refresh, and makes sure two callers
/// asking at once produce one request. What it deliberately does not own is any
/// opinion about what the numbers mean: no thresholds, no warnings, no
/// handoffs. Those are decisions, and a decision made on a number this layer is
/// not yet sure of is the failure mode the whole design is arranged against.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var entries: [UsageKey: UsageEntry] = [:]

    private var providers: [AgentProvider: UsageProvider] = [:]
    private var inFlight: [UsageKey: Task<UsageEntry, Never>] = [:]
    private var clock: () -> Date

    /// Where the Claude CLI probe runs. Fixed rather than temporary, so the
    /// CLI's own per-project history gains one entry instead of one per read.
    static func defaultProbeDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent("Uncoil", isDirectory: true)
            .appendingPathComponent("usage-probe", isDirectory: true)
    }

    init(
        providers: [UsageProvider]? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.clock = clock
        let resolved = providers ?? [
            CodexUsageProvider(),
            ClaudeUsageProvider(probeDirectory: Self.defaultProbeDirectory()),
            GeminiUsageProvider(),
        ]
        for provider in resolved {
            self.providers[provider.provider] = provider
        }
        // Applied as the store is built rather than from a view's `onAppear`,
        // so the fixture is in place before anything can read it.
        if LaunchConfig.shared.usageFixture {
            seed(UsageFixture.snapshot(now: clock()), for: UsageFixture.key)
        }
    }

    // MARK: - Reading

    func entry(for key: UsageKey) -> UsageEntry {
        entries[key] ?? UsageEntry()
    }

    func snapshot(for key: UsageKey) -> UsageSnapshot? {
        entries[key]?.snapshot
    }

    /// Whether Uncoil has any route to this provider at all.
    ///
    /// A plain terminal has no usage and never will, and a provider with no
    /// registered routes is a gap in this layer rather than a problem with the
    /// user's account. Saying which is which keeps "unavailable" meaningful.
    func isSupported(_ provider: AgentProvider) -> Bool {
        providers[provider] != nil
    }

    // MARK: - Refreshing

    /// Refreshes if the policy says it is due; returns the entry either way.
    @discardableResult
    func refreshIfDue(
        key: UsageKey,
        account: UsageAccountContext,
        activity: UsageActivity
    ) async -> UsageEntry {
        let current = entry(for: key)
        guard UsageRefreshPolicy.shouldRefresh(
            state: current.refresh, activity: activity, now: clock()
        ) else { return current }
        return await refresh(key: key, account: account, userInitiated: false)
    }

    /// Refreshes now.
    ///
    /// `userInitiated` clears an authentication block: a person pressing
    /// refresh is telling us something changed, and a button that stays broken
    /// because of an old failure is a button that fails when it is needed.
    @discardableResult
    func refresh(
        key: UsageKey,
        account: UsageAccountContext,
        userInitiated: Bool
    ) async -> UsageEntry {
        // Deduplication is the whole reason this goes through the store rather
        // than each caller running a pipeline: several views asking at once is
        // the ordinary case, and each of them spawning a `codex app-server`
        // would be three processes to answer one question.
        if let existing = inFlight[key] { return await existing.value }

        guard let provider = providers[key.provider] else {
            var entry = self.entry(for: key)
            entry.snapshot = .unavailable(
                provider: key.provider,
                accountID: key.accountID,
                reason: .providerUnsupported,
                source: .cache,
                updatedAt: clock()
            )
            entries[key] = entry
            return entry
        }

        if userInitiated {
            var entry = self.entry(for: key)
            entry.refresh = UsageRefreshPolicy.unblocked(entry.refresh)
            entries[key] = entry
        }

        var starting = entry(for: key)
        starting.isRefreshing = true
        entries[key] = starting

        let strategies = provider.strategies(for: account)
        let providerKind = key.provider
        let accountID = key.accountID
        let clock = self.clock

        let task = Task<UsageEntry, Never> { [weak self] in
            let outcome = await UsageFetchPipeline.run(
                provider: providerKind,
                accountID: accountID,
                strategies: strategies,
                clock: clock
            )
            guard let self else { return UsageEntry() }
            return await self.apply(outcome: outcome, to: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Folds a pipeline result into the cache.
    ///
    /// The rule that shapes this: a failed refresh never blanks a good
    /// snapshot. Replacing real numbers with nothing makes the display flicker
    /// between a figure and an absence on every transient failure, and an
    /// absence is indistinguishable from a limit that has genuinely gone away.
    /// The old numbers stay, marked stale, with the reason attached.
    private func apply(outcome: UsageFetchOutcome, to key: UsageKey) -> UsageEntry {
        var entry = self.entry(for: key)
        let now = clock()

        entry.attempts = outcome.attempts
        entry.refresh = UsageRefreshPolicy.after(state: entry.refresh, outcome: outcome, now: now)
        entry.isRefreshing = false

        if let snapshot = outcome.snapshot {
            entry.snapshot = snapshot
        } else if let previous = entry.snapshot {
            entry.snapshot = previous.markedStale(error: outcome.lastError?.summary)
        } else {
            // Nothing before and nothing now. Recorded as unavailable with the
            // reason rather than left empty, so a caller can tell "never asked"
            // from "asked and could not find out".
            entry.snapshot = .unavailable(
                provider: key.provider,
                accountID: key.accountID,
                reason: unavailability(for: outcome),
                source: outcome.attempts.last?.source ?? .cache,
                updatedAt: now,
                error: outcome.lastError?.summary
            )
        }

        entries[key] = entry
        return entry
    }

    private func unavailability(for outcome: UsageFetchOutcome) -> UsageUnavailability {
        guard let error = outcome.lastError else {
            // Every strategy was skipped: nothing is installed or logged in.
            return .noCredentials
        }
        switch error.kind {
        case .credentialsMissing, .notApplicable: return .noCredentials
        case .credentialsExpired, .unauthorized: return .credentialsRejected
        case .accountTierUnsupported: return .accountTierUnsupported
        case .authenticationTypeUnsupported: return .authenticationTypeUnsupported
        case .planReportsNoQuota: return .planReportsNoQuota
        default: return .allStrategiesFailed
        }
    }

    /// Places a snapshot directly, for a deterministic UI run.
    ///
    /// It records an attempt at the same time, so the entry does not read as
    /// "never asked" while holding numbers — a state no real refresh can
    /// produce, and one the card would describe wrongly.
    func seed(_ snapshot: UsageSnapshot, for key: UsageKey) {
        var entry = self.entry(for: key)
        entry.snapshot = snapshot
        entry.refresh.lastAttempt = snapshot.updatedAt
        entry.refresh.lastSuccess = snapshot.updatedAt
        entries[key] = entry
    }

    // MARK: - Diagnostics

    /// A redacted, human-readable account of the last refresh.
    ///
    /// Built from the attempt records rather than from anything the providers
    /// returned: response bodies here sit next to identity and authentication
    /// data, and the useful part of a diagnostic is which route was tried and
    /// what it said, not what came back in it.
    func diagnostics(for key: UsageKey) -> String {
        let entry = self.entry(for: key)
        var lines: [String] = ["\(key.provider.displayName) usage"]
        if let account = key.accountID { lines.append("account: \(account.uuidString)") }
        for attempt in entry.attempts {
            let state = attempt.skipped ? "skipped"
                : attempt.succeeded ? "ok"
                : (attempt.error?.summary ?? "failed")
            lines.append("  \(attempt.source.rawValue): \(state)")
        }
        if let snapshot = entry.snapshot {
            lines.append("  source: \(snapshot.source.rawValue), stale: \(snapshot.stale)")
            if let reason = snapshot.unavailable {
                lines.append("  unavailable: \(reason.rawValue)")
            }
            for window in snapshot.allWindows {
                lines.append("  \(window.title): \(Int(window.remainingPercent.rounded()))% remaining")
            }
        }
        return UsageCredentials.redacted(lines.joined(separator: "\n"))
    }
}
