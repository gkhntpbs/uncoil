import Foundation

/// One account's usage, as the Attention Center needs to see it.
///
/// Carries a session and a project only so a row can be clicked through to
/// somewhere. The row itself is about the account.
struct UsageAttentionInput: Equatable {
    var provider: AgentProvider
    var accountID: UUID?
    var accountName: String?
    var snapshot: UsageSnapshot
    /// Any live session on this account, for the row's "go there".
    var sessionID: UUID?
    var projectID: UUID?
    /// How many sessions are running on it, which is what makes a low account
    /// urgent rather than merely true.
    var sessionCount: Int = 0
}

/// Usage input for the Attention Center.
struct UsageAttentionSnapshot: Equatable {
    var accounts: [UsageAttentionInput] = []
    /// Below this many percent remaining, an account is worth mentioning.
    var threshold: Double = UsageAlert.defaultThreshold
    /// The user can switch the warnings off without switching off the figures.
    var isEnabled: Bool = true
}

/// Gathers the usage side of the Attention Center's input.
///
/// Separate from the engine so the engine stays pure: this half knows about
/// stores and live sessions, that half knows only the rules.
@MainActor
enum UsageAttentionCollector {
    /// One entry per account that has a snapshot and at least one live session.
    ///
    /// The live-session condition is the point. An account nobody is working on
    /// cannot be interrupted by running out, so warning about it would be
    /// telling the user something they cannot use — and on a machine with
    /// several logins it would fill the panel with rows about accounts that are
    /// merely configured.
    static func snapshot(
        usage: UsageStore,
        sessions: [SessionRecord],
        statuses: [UUID: AgentSessionStatus],
        accounts: [AccountProfile],
        threshold: Double,
        isEnabled: Bool
    ) -> UsageAttentionSnapshot {
        var byKey: [UsageKey: [SessionRecord]] = [:]
        for session in sessions where session.provider.isAgent {
            guard (statuses[session.id] ?? .unknown) != .terminated else { continue }
            byKey[UsageKey(provider: session.provider, accountID: session.accountID), default: []]
                .append(session)
        }

        let names = Dictionary(
            accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
        )
        let inputs = byKey.compactMap { key, live -> UsageAttentionInput? in
            guard let snapshot = usage.snapshot(for: key) else { return nil }
            // Whichever session is furthest along in its turn is the one a
            // click should land on: it is the one the limit will interrupt.
            let target = live.first { statuses[$0.id]?.isWorking == true } ?? live.first
            return UsageAttentionInput(
                provider: key.provider,
                accountID: key.accountID,
                accountName: key.accountID.flatMap { names[$0] },
                snapshot: snapshot,
                sessionID: target?.id,
                projectID: target?.projectID,
                sessionCount: live.count
            )
        }

        return UsageAttentionSnapshot(
            accounts: inputs.sorted { left, right in
                (left.provider.rawValue, left.accountID?.uuidString ?? "")
                    < (right.provider.rawValue, right.accountID?.uuidString ?? "")
            },
            threshold: threshold,
            isEnabled: isEnabled
        )
    }
}

/// Derives Attention Center rows from usage. Pure, so every rule is testable
/// without a network, an account or a running app.
///
/// The rule that shapes all of it: **one row per account, not per session.**
/// A limit belongs to a login, so five sessions sharing one account share one
/// problem, and five identical rows saying so would bury everything else in the
/// panel while adding nothing. The row says how many sessions it affects
/// instead.
enum UsageAttentionEngine {
    static func rowID(provider: AgentProvider, accountID: UUID?) -> String {
        "usage:\(provider.rawValue):\(accountID?.uuidString ?? "default")"
    }

    static func items(_ snapshot: UsageAttentionSnapshot, now: Date = .now) -> [AttentionItem] {
        guard snapshot.isEnabled else { return [] }

        return snapshot.accounts.compactMap { account -> AttentionItem? in
            let evaluation = UsageAlert.evaluate(account.snapshot, threshold: snapshot.threshold)
            guard evaluation.state.isAlerting else { return nil }

            return AttentionItem(
                id: rowID(provider: account.provider, accountID: account.accountID),
                kind: evaluation.state == .reached ? .usageExhausted : .usageLow,
                title: title(for: account),
                detail: detail(for: account, evaluation: evaluation, now: now),
                projectID: account.projectID,
                sessionID: account.sessionID,
                createdAt: now,
                isDerived: true
            )
        }
    }

    /// "Claude · Work", or just the provider when there is nothing to add.
    static func title(for account: UsageAttentionInput) -> String {
        guard let name = account.accountName, !name.isEmpty,
              name.caseInsensitiveCompare(account.provider.displayName) != .orderedSame else {
            return account.provider.displayName
        }
        return "\(account.provider.displayName) · \(name)"
    }

    /// What is left, in which window, and who it affects.
    ///
    /// The window is named because "8% left" is a different piece of news
    /// depending on whether it resets in two hours or in three days, and the
    /// session count is there because an account nothing is running on can wait.
    static func detail(
        for account: UsageAttentionInput,
        evaluation: UsageAlert.Evaluation,
        now: Date
    ) -> String {
        var parts: [String] = []

        if evaluation.state == .reached {
            if let window = evaluation.window {
                parts.append(String(localized: "\(window.title) is used up"))
            } else {
                parts.append(String(localized: "The provider has stopped accepting work"))
            }
        } else if let window = evaluation.window, let remaining = evaluation.remainingPercent {
            parts.append(String(localized: "\(remaining)% left of the \(window.title.lowercased())"))
        }

        if let window = evaluation.window,
           let reset = UsageDisplay.resetLine(window, now: now) {
            parts.append(reset.lowercased())
        }
        if account.sessionCount == 1 {
            parts.append(String(localized: "1 session is on it"))
        } else if account.sessionCount > 1 {
            parts.append(String(localized: "\(account.sessionCount) sessions are on it"))
        }
        // Said plainly rather than left to be inferred from a colour: a warning
        // drawn from a reading that could not be refreshed is still worth
        // having — usage only moves one way between resets — but the user
        // should know which of the two they are looking at.
        if account.snapshot.stale {
            parts.append(String(localized: "figure not refreshed"))
        }

        return parts.joined(separator: " · ")
    }
}
