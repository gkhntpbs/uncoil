import XCTest
@testable import Uncoil

private func snapshot(
    provider: AgentProvider = .claude,
    remaining: Double...,
    limitReached: Bool = false,
    stale: Bool = false,
    resetsAt: Date? = nil,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> UsageSnapshot {
    let windows = remaining.enumerated().map { index, value in
        UsageWindow(
            id: "w\(index)", title: index == 0 ? "session limit" : "weekly limit",
            usedPercent: 100 - value, resetsAt: resetsAt
        )
    }
    var result = UsageSnapshot(
        provider: provider,
        primaryWindow: windows.first,
        secondaryWindow: windows.count > 1 ? windows[1] : nil,
        extraWindows: Array(windows.dropFirst(2)),
        limitReached: limitReached,
        source: .claudeOAuthAPI,
        updatedAt: now
    )
    if stale { result = result.markedStale(error: "timedOut") }
    return result
}

/// The judgement the rest of the feature is built on.
final class UsageAlertTests: XCTestCase {

    func testAComfortableAccountSaysNothing() {
        XCTAssertEqual(UsageAlert.evaluate(snapshot(remaining: 80, 60)).state, .none)
    }

    func testCrossingTheThresholdIsApproaching() {
        XCTAssertEqual(UsageAlert.evaluate(snapshot(remaining: 14)).state, .approaching)
        XCTAssertEqual(UsageAlert.evaluate(snapshot(remaining: 15)).state, .approaching)
        XCTAssertEqual(UsageAlert.evaluate(snapshot(remaining: 16)).state, .none)
    }

    func testTheThresholdIsTheUsers() {
        let account = snapshot(remaining: 30)
        XCTAssertEqual(UsageAlert.evaluate(account, threshold: 15).state, .none)
        XCTAssertEqual(UsageAlert.evaluate(account, threshold: 40).state, .approaching)
    }

    /// There is nothing left to approach.
    func testAnEmptyWindowIsReachedRatherThanApproaching() {
        let evaluation = UsageAlert.evaluate(snapshot(remaining: 0))
        XCTAssertEqual(evaluation.state, .reached)
        XCTAssertEqual(evaluation.remainingPercent, 0)
    }

    /// The account is limited by whichever window binds first, so a full
    /// session block does not excuse an empty week.
    func testTheTightestWindowDecides() {
        let evaluation = UsageAlert.evaluate(snapshot(remaining: 90, 4))
        XCTAssertEqual(evaluation.state, .approaching)
        XCTAssertEqual(evaluation.window?.title, "weekly limit")
        XCTAssertEqual(evaluation.remainingPercent, 4)
    }

    // MARK: - The case a threshold cannot catch

    /// A spend cap or a team policy refuses an account whose windows are not
    /// empty. No percentage would ever have shown it coming, which is exactly
    /// why the provider's own word outranks the arithmetic.
    func testAProviderSayingNoOutranksTheNumbers() {
        let evaluation = UsageAlert.evaluate(snapshot(remaining: 95, limitReached: true))
        XCTAssertEqual(evaluation.state, .reached)
    }

    /// And it still counts when there are no windows at all to reason from.
    func testARefusalWithNoWindowsIsStillReached() {
        var bare = UsageSnapshot(
            provider: .codex, limitReached: true, source: .codexOAuthAPI,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(bare.hasQuota)
        XCTAssertEqual(UsageAlert.evaluate(bare).state, .reached)

        bare.limitReached = false
        XCTAssertEqual(UsageAlert.evaluate(bare).state, .none)
    }

    // MARK: - Silence

    /// A warning drawn from an unknown is a guess wearing a warning's clothes.
    func testAnUnreadableAccountNeverAlerts() {
        let unavailable = UsageSnapshot.unavailable(
            provider: .gemini, reason: .accountTierUnsupported,
            source: .geminiCodeAssistAPI, updatedAt: Date()
        )
        XCTAssertEqual(UsageAlert.evaluate(unavailable).state, .none)
        XCTAssertEqual(UsageAlert.evaluate(nil).state, .none)
    }

    /// Usage only moves one way between resets, so a low reading that could not
    /// be refreshed is not less low now. Going quiet would take the warning
    /// away exactly when it is most likely to be right.
    func testAStaleFigureStillAlerts() {
        XCTAssertEqual(UsageAlert.evaluate(snapshot(remaining: 5, stale: true)).state, .approaching)
    }
}

// MARK: - Rows

@MainActor
final class UsageAttentionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(
        provider: AgentProvider = .claude,
        accountID: UUID? = nil,
        accountName: String? = nil,
        remaining: Double,
        sessions: Int = 1,
        stale: Bool = false,
        limitReached: Bool = false
    ) -> UsageAttentionInput {
        UsageAttentionInput(
            provider: provider,
            accountID: accountID,
            accountName: accountName,
            snapshot: snapshot(
                provider: provider, remaining: remaining,
                limitReached: limitReached, stale: stale,
                resetsAt: now.addingTimeInterval(2 * 3600), now: now
            ),
            sessionID: UUID(),
            projectID: UUID(),
            sessionCount: sessions
        )
    }

    func testAComfortableAccountProducesNoRow() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 70)]), now: now
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testALowAccountProducesOneRow() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(accountName: "Work", remaining: 8, sessions: 3)]),
            now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .usageLow)
        XCTAssertEqual(rows[0].title, "Claude · Work")
        XCTAssertTrue(rows[0].detail?.contains("8% left") ?? false, rows[0].detail ?? "")
        XCTAssertTrue(rows[0].detail?.contains("3 sessions") ?? false, rows[0].detail ?? "")
        XCTAssertTrue(rows[0].detail?.contains("in 2h") ?? false, rows[0].detail ?? "")
    }

    func testAnExhaustedAccountIsADifferentRow() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 0)]), now: now
        )
        XCTAssertEqual(rows[0].kind, .usageExhausted)
        XCTAssertTrue(rows[0].kind.isProblem)
    }

    /// Approaching is not yet a problem — that is the whole point of a warning.
    /// Escalating for it would make the menu-bar icon mean "something needs
    /// you" when nothing does yet.
    func testApproachingIsNotCountedAsAProblem() {
        XCTAssertFalse(AttentionKind.usageLow.isProblem)
        XCTAssertNil(AttentionKind.usageLow.notificationEvent)
        XCTAssertEqual(AttentionKind.usageExhausted.notificationEvent, .problem)
    }

    /// One row per account. Five sessions sharing one login share one problem,
    /// and five identical rows would bury everything else in the panel.
    func testOneAccountProducesOneRowHoweverManySessions() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 5, sessions: 9)]), now: now
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].detail?.contains("9 sessions") ?? false)
    }

    /// Two logins are two limits, so they are two rows with two ids.
    func testTwoAccountsOfOneProviderAreTwoRows() {
        let first = UUID()
        let second = UUID()
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [
                input(accountID: first, accountName: "Personal", remaining: 9),
                input(accountID: second, accountName: "Work", remaining: 3),
            ]),
            now: now
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    /// The switch turns off being told, not knowing: the figures stay.
    func testTurningWarningsOffProducesNoRows() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 2)], isEnabled: false), now: now
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testAStaleFigureSaysSoInTheRow() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 6, stale: true)]), now: now
        )
        XCTAssertTrue(rows[0].detail?.contains("not refreshed") ?? false, rows[0].detail ?? "")
    }

    /// A provider that refuses before any window empties still gets a row, and
    /// it does not pretend to name a window.
    func testARefusalWithoutAnEmptyWindowIsExplained() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(remaining: 88, limitReached: true)]), now: now
        )
        XCTAssertEqual(rows[0].kind, .usageExhausted)
        XCTAssertTrue(rows[0].detail?.contains("used up") ?? false, rows[0].detail ?? "")
    }

    /// A row with no name adds nothing by repeating the provider back.
    func testAnAccountNamedAfterItsProviderIsNotRepeated() {
        let rows = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [input(accountName: "claude", remaining: 4)]), now: now
        )
        XCTAssertEqual(rows[0].title, "Claude")
    }

    /// The row's id is stable, so the same warning does not re-announce itself
    /// on every refresh and can be marked read.
    func testTheRowIdIsStableAcrossRefreshes() {
        let account = input(accountName: "Work", remaining: 7)
        let first = UsageAttentionEngine.items(UsageAttentionSnapshot(accounts: [account]), now: now)
        let second = UsageAttentionEngine.items(
            UsageAttentionSnapshot(accounts: [account]), now: now.addingTimeInterval(600)
        )
        XCTAssertEqual(first[0].id, second[0].id)
    }
}

// MARK: - Collection

@MainActor
final class UsageAttentionCollectorTests: XCTestCase {
    private let projectID = UUID()

    private func session(
        _ provider: AgentProvider, account: UUID? = nil
    ) -> SessionRecord {
        SessionRecord(
            projectID: projectID, provider: provider, accountID: account, title: "s"
        )
    }

    private func store(_ pairs: [(UsageKey, UsageSnapshot)]) -> UsageStore {
        let store = UsageStore(providers: [])
        for (key, snapshot) in pairs { store.seed(snapshot, for: key) }
        return store
    }

    /// An account nobody is working on cannot be interrupted by running out, so
    /// warning about it tells the user something they cannot use.
    func testAnAccountWithNoLiveSessionIsNotCollected() {
        let key = UsageKey(provider: .claude, accountID: nil)
        let collected = UsageAttentionCollector.snapshot(
            usage: store([(key, snapshot(remaining: 3))]),
            sessions: [], statuses: [:], accounts: [],
            threshold: 15, isEnabled: true
        )
        XCTAssertTrue(collected.accounts.isEmpty)
    }

    func testATerminatedSessionDoesNotCount() {
        let live = session(.claude)
        let key = UsageKey(provider: .claude, accountID: nil)
        let collected = UsageAttentionCollector.snapshot(
            usage: store([(key, snapshot(remaining: 3))]),
            sessions: [live], statuses: [live.id: .terminated], accounts: [],
            threshold: 15, isEnabled: true
        )
        XCTAssertTrue(collected.accounts.isEmpty)
    }

    /// A plain terminal has no account and no limit.
    func testTerminalSessionsAreIgnored() {
        let shell = session(.terminal)
        let collected = UsageAttentionCollector.snapshot(
            usage: store([]), sessions: [shell], statuses: [shell.id: .idle],
            accounts: [], threshold: 15, isEnabled: true
        )
        XCTAssertTrue(collected.accounts.isEmpty)
    }

    func testSessionsAreGroupedByAccount() {
        let first = UUID()
        let a = session(.claude, account: first)
        let b = session(.claude, account: first)
        let c = session(.codex)
        let collected = UsageAttentionCollector.snapshot(
            usage: store([
                (UsageKey(provider: .claude, accountID: first), snapshot(remaining: 4)),
                (UsageKey(provider: .codex, accountID: nil), snapshot(provider: .codex, remaining: 9)),
            ]),
            sessions: [a, b, c],
            statuses: [a.id: .idle, b.id: .running, c.id: .idle],
            accounts: [AccountProfile(id: first, provider: .claude, name: "Work")],
            threshold: 15, isEnabled: true
        )

        XCTAssertEqual(collected.accounts.count, 2)
        let claude = try? XCTUnwrap(collected.accounts.first { $0.provider == .claude })
        XCTAssertEqual(claude?.sessionCount, 2)
        XCTAssertEqual(claude?.accountName, "Work")
        // The working session is the one a click should land on: it is the one
        // the limit will interrupt.
        XCTAssertEqual(claude?.sessionID, b.id)
    }

    /// An account with sessions but no reading is not an account with a
    /// problem; it is one we know nothing about.
    func testAnAccountWithNoSnapshotIsNotCollected() {
        let live = session(.claude)
        let collected = UsageAttentionCollector.snapshot(
            usage: store([]), sessions: [live], statuses: [live.id: .idle],
            accounts: [], threshold: 15, isEnabled: true
        )
        XCTAssertTrue(collected.accounts.isEmpty)
    }

    /// The defect that made the warning invisible for an afternoon, and the
    /// reason the refresher holds this snapshot rather than taking it.
    ///
    /// `refresh` is called from several places — a status change, the
    /// twenty-second conflict scan, the task scan — and most of them have no
    /// usage store to hand. When the usage side was a parameter, every one of
    /// those rebuilt the whole snapshot without it and wiped the row a moment
    /// after it appeared.
    func testARefreshFromElsewhereDoesNotEraseUsageRows() {
        let live = session(.claude)
        let refresher = AttentionRefresher.shared
        let projects = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-usage-\(UUID().uuidString)", isDirectory: true))
        let sessions = SessionStore()

        refresher.setUsage(UsageAttentionSnapshot(accounts: [
            UsageAttentionInput(
                provider: .claude, accountID: nil, accountName: nil,
                snapshot: snapshot(remaining: 4), sessionID: live.id,
                projectID: projectID, sessionCount: 1
            ),
        ]))

        // A refresh that knows nothing about usage, exactly as the scans do.
        let rebuilt = refresher.snapshot(projectStore: projects, sessionStore: sessions)
        XCTAssertEqual(rebuilt.usage.accounts.count, 1)
        XCTAssertFalse(AttentionEngine.items(rebuilt).filter { $0.kind == .usageLow }.isEmpty)
    }
}
