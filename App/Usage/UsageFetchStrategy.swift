import Foundation

// MARK: - Errors

/// Why one strategy did not produce a snapshot, and whether the pipeline should
/// keep going.
///
/// The `continuesToFallback` flag is the important half. Some failures are
/// about the route — a missing credential file, a timeout — and another route
/// may well answer. Others are about the account itself: a tier the provider
/// has withdrawn quota from will give the same answer down every route, and
/// trying the next one only spends time and, in the CLI's case, spawns a
/// process to be told the same thing.
struct UsageFetchError: Error, Equatable {
    enum Kind: String, Equatable {
        /// The strategy does not apply here at all — binary absent, feature off.
        case notApplicable
        case credentialsMissing
        case credentialsExpired
        case unauthorized
        case timedOut
        case transport
        case malformedResponse
        case processFailed
        /// The provider answered, and the answer was "not for this account".
        case accountTierUnsupported
        case authenticationTypeUnsupported
        case planReportsNoQuota
        case cancelled
    }

    var kind: Kind
    var detail: String?
    var continuesToFallback: Bool

    init(_ kind: Kind, detail: String? = nil, continuesToFallback: Bool? = nil) {
        self.kind = kind
        self.detail = detail
        self.continuesToFallback = continuesToFallback ?? Self.defaultContinues(kind)
    }

    /// A failure of the route continues; a verdict about the account stops.
    private static func defaultContinues(_ kind: Kind) -> Bool {
        switch kind {
        case .notApplicable, .credentialsMissing, .credentialsExpired,
             .unauthorized, .timedOut, .transport, .malformedResponse,
             .processFailed:
            true
        case .accountTierUnsupported, .authenticationTypeUnsupported,
             .planReportsNoQuota, .cancelled:
            false
        }
    }

    /// How a stopping verdict is recorded on the snapshot handed back.
    var terminalUnavailability: UsageUnavailability? {
        switch kind {
        case .accountTierUnsupported: .accountTierUnsupported
        case .authenticationTypeUnsupported: .authenticationTypeUnsupported
        case .planReportsNoQuota: .planReportsNoQuota
        default: nil
        }
    }

    /// Never interpolate a response body here: several of these are produced
    /// next to identity and authentication data.
    var summary: String {
        guard let detail, !detail.isEmpty else { return kind.rawValue }
        return "\(kind.rawValue): \(detail)"
    }
}

// MARK: - Strategy

/// One way of getting usage out of one provider.
///
/// Strategies are ordered and tried in turn. Each is expected to be cheap to
/// dismiss — `isAvailable` should answer from disk, not from the network — so
/// that an inapplicable route costs nothing.
protocol UsageFetchStrategy {
    var source: UsageSource { get }

    /// Whether this route could work right now: the credential file exists,
    /// the binary is installed, the feature is switched on. A false here is not
    /// a failure and is not reported as one.
    func isAvailable() -> Bool

    /// Bounded by the strategy's own timeout. Throws `UsageFetchError`.
    func fetch() async throws -> UsageSnapshot
}

// MARK: - Diagnostics

/// What one strategy did, kept whether it worked or not.
///
/// Retained for the whole pipeline because the useful diagnostic is almost
/// never the last error — it is that the preferred route was skipped for a
/// missing credential and the fallback then answered from something older.
struct UsageAttempt: Equatable {
    var source: UsageSource
    var skipped: Bool
    var succeeded: Bool
    var error: UsageFetchError?
    var duration: TimeInterval
}

/// The result of running a provider's whole pipeline.
struct UsageFetchOutcome {
    var snapshot: UsageSnapshot?
    var attempts: [UsageAttempt]

    /// The error worth showing: the last one that was not a skip.
    var lastError: UsageFetchError? {
        attempts.reversed().first { !$0.skipped }?.error
    }
}

// MARK: - Pipeline

/// Runs a provider's strategies in order and stops at the first one that
/// answers.
///
/// Two rules it enforces, both learned from the shape of the problem rather
/// than from the code:
///
/// - A strategy that says something definitive about the account stops the
///   pipeline and that verdict becomes the result. Falling through would turn
///   "this plan reports no quota" into "everything failed", which reads as a
///   transient problem and invites a retry loop against an answer that will
///   not change.
/// - A strategy that returns a snapshot with no windows at all is treated as
///   having answered, not as having failed. That is a real state — an
///   authenticated account the provider reports nothing for — and the reason
///   travels with it.
enum UsageFetchPipeline {
    static func run(
        provider: AgentProvider,
        accountID: UUID?,
        strategies: [UsageFetchStrategy],
        clock: @escaping () -> Date = Date.init
    ) async -> UsageFetchOutcome {
        var attempts: [UsageAttempt] = []

        for strategy in strategies {
            let started = clock()

            guard strategy.isAvailable() else {
                attempts.append(UsageAttempt(
                    source: strategy.source,
                    skipped: true,
                    succeeded: false,
                    error: UsageFetchError(.notApplicable),
                    duration: 0
                ))
                continue
            }

            do {
                let snapshot = try await strategy.fetch()
                attempts.append(UsageAttempt(
                    source: strategy.source,
                    skipped: false,
                    succeeded: true,
                    error: nil,
                    duration: clock().timeIntervalSince(started)
                ))
                return UsageFetchOutcome(snapshot: snapshot, attempts: attempts)
            } catch {
                let fetchError = (error as? UsageFetchError)
                    ?? UsageFetchError(.transport, detail: nil)
                attempts.append(UsageAttempt(
                    source: strategy.source,
                    skipped: false,
                    succeeded: false,
                    error: fetchError,
                    duration: clock().timeIntervalSince(started)
                ))

                if let reason = fetchError.terminalUnavailability {
                    return UsageFetchOutcome(
                        snapshot: .unavailable(
                            provider: provider,
                            accountID: accountID,
                            reason: reason,
                            source: strategy.source,
                            updatedAt: clock(),
                            error: fetchError.summary
                        ),
                        attempts: attempts
                    )
                }
                if !fetchError.continuesToFallback { break }
            }
        }

        return UsageFetchOutcome(snapshot: nil, attempts: attempts)
    }
}

// MARK: - Provider

/// A provider's ordered strategies, named once so the store does not have to
/// know which routes exist for whom.
protocol UsageProvider {
    var provider: AgentProvider { get }
    /// Ordered, preferred first.
    func strategies(for account: UsageAccountContext) -> [UsageFetchStrategy]
}

/// Everything a strategy needs to know about which account it is asking for.
///
/// The isolated config directory is the whole of it for Codex and Claude: a
/// second account is a second `CODEX_HOME`/`CLAUDE_CONFIG_DIR`, holding its own
/// credentials. Mixing the two would attach one account's numbers to the
/// other's name.
struct UsageAccountContext: Equatable {
    var accountID: UUID?
    var label: String?
    /// `nil` means the provider's own default home.
    var configDirectory: URL?

    init(accountID: UUID? = nil, label: String? = nil, configDirectory: URL? = nil) {
        self.accountID = accountID
        self.label = label
        self.configDirectory = configDirectory
    }

    static let providerDefault = UsageAccountContext()
}
