import XCTest
@testable import Uncoil

/// A provider whose strategies the test supplies.
private struct StubProvider: UsageProvider {
    var provider: AgentProvider
    var make: () -> [UsageFetchStrategy]

    func strategies(for account: UsageAccountContext) -> [UsageFetchStrategy] { make() }
}

private struct ScriptedStrategy: UsageFetchStrategy {
    var source: UsageSource
    var available: Bool = true
    var script: Script

    /// Answers change between calls, which is how a refresh that succeeds and
    /// then fails is expressed.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<UsageSnapshot, UsageFetchError>]
        private(set) var callCount = 0

        init(_ results: [Result<UsageSnapshot, UsageFetchError>]) {
            self.results = results
        }

        func next() throws -> UsageSnapshot {
            lock.lock()
            callCount += 1
            let result = results.isEmpty ? nil : results.removeFirst()
            lock.unlock()
            guard let result else { throw UsageFetchError(.notApplicable) }
            return try result.get()
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return callCount
        }
    }

    func isAvailable() -> Bool { available }
    func fetch() async throws -> UsageSnapshot { try script.next() }
}

private func snapshot(used: Double, at time: TimeInterval) -> UsageSnapshot {
    UsageSnapshot(
        provider: .codex,
        primaryWindow: UsageWindow(id: "p", title: "Session", usedPercent: used),
        source: .codexOAuthAPI,
        updatedAt: Date(timeIntervalSince1970: time)
    )
}

@MainActor
final class UsageStoreTests: XCTestCase {
    private let key = UsageKey(provider: .codex, accountID: nil)
    private var currentTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(_ script: ScriptedStrategy.Script, available: Bool = true) -> UsageStore {
        UsageStore(
            providers: [StubProvider(provider: .codex) {
                [ScriptedStrategy(source: .codexOAuthAPI, available: available, script: script)]
            }],
            clock: { [weak self] in self?.currentTime ?? Date(timeIntervalSince1970: 0) }
        )
    }

    // MARK: - The ordinary path

    func testASuccessfulRefreshIsCached() async {
        let script = ScriptedStrategy.Script([.success(snapshot(used: 20, at: 1_700_000_000))])
        let store = store(script)

        let entry = await store.refresh(key: key, account: .providerDefault, userInitiated: true)

        XCTAssertEqual(entry.snapshot?.primaryWindow?.usedPercent, 20)
        XCTAssertFalse(entry.isStale)
        XCTAssertEqual(entry.lastSuccessfulRefresh, currentTime)
        XCTAssertEqual(store.snapshot(for: key)?.primaryWindow?.usedPercent, 20)
    }

    // MARK: - Stale preservation

    /// The rule the display depends on: a failed refresh never blanks a good
    /// snapshot. Replacing real numbers with nothing makes the figure flicker
    /// on every transient failure, and an absence is indistinguishable from a
    /// limit that has genuinely gone away.
    func testAFailedRefreshKeepsTheOldNumbersAndMarksThemStale() async {
        let script = ScriptedStrategy.Script([
            .success(snapshot(used: 20, at: 1_700_000_000)),
            .failure(UsageFetchError(.timedOut)),
        ])
        let store = store(script)

        await store.refresh(key: key, account: .providerDefault, userInitiated: true)
        currentTime = currentTime.addingTimeInterval(600)
        let entry = await store.refresh(key: key, account: .providerDefault, userInitiated: true)

        XCTAssertEqual(entry.snapshot?.primaryWindow?.usedPercent, 20)
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.error, "timedOut")
        // The numbers are as old as they were; the failed attempt is newer.
        XCTAssertEqual(entry.snapshot?.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(entry.lastAttempt, currentTime)
        XCTAssertNotEqual(entry.lastAttempt, entry.lastSuccessfulRefresh)
    }

    /// Nothing before and nothing now: recorded with a reason, so "never asked"
    /// can be told from "asked and could not find out".
    func testAFirstFailureRecordsAReasonRatherThanAZero() async {
        let script = ScriptedStrategy.Script([.failure(UsageFetchError(.credentialsExpired))])
        let store = store(script)

        let entry = await store.refresh(key: key, account: .providerDefault, userInitiated: true)

        XCTAssertEqual(entry.snapshot?.unavailable, .credentialsRejected)
        XCTAssertFalse(entry.snapshot?.hasQuota ?? true)
        XCTAssertNil(entry.snapshot?.mostConstrainedWindow)
    }

    func testEveryStrategySkippedReadsAsNoCredentials() async {
        let script = ScriptedStrategy.Script([])
        let store = store(script, available: false)

        let entry = await store.refresh(key: key, account: .providerDefault, userInitiated: true)

        XCTAssertEqual(entry.snapshot?.unavailable, .noCredentials)
        XCTAssertEqual(script.calls, 0)
    }

    // MARK: - Scheduling

    func testRefreshIfDueDoesNothingWhenItIsNotDue() async {
        let script = ScriptedStrategy.Script([
            .success(snapshot(used: 20, at: 1_700_000_000)),
            .success(snapshot(used: 40, at: 1_700_000_000)),
        ])
        let store = store(script)

        await store.refreshIfDue(key: key, account: .providerDefault, activity: .active)
        XCTAssertEqual(script.calls, 1)

        // A minute later, well inside the active interval.
        currentTime = currentTime.addingTimeInterval(60)
        await store.refreshIfDue(key: key, account: .providerDefault, activity: .active)
        XCTAssertEqual(script.calls, 1)

        currentTime = currentTime.addingTimeInterval(UsageRefreshPolicy.activeInterval)
        await store.refreshIfDue(key: key, account: .providerDefault, activity: .active)
        XCTAssertEqual(script.calls, 2)
    }

    /// Several views asking at once is the ordinary case, and each of them
    /// spawning its own probe would be three processes to answer one question.
    func testConcurrentRefreshesCollapseIntoOne() async {
        let script = ScriptedStrategy.Script([
            .success(snapshot(used: 20, at: 1_700_000_000)),
            .success(snapshot(used: 99, at: 1_700_000_000)),
        ])
        let store = store(script)

        async let first = store.refresh(key: key, account: .providerDefault, userInitiated: false)
        async let second = store.refresh(key: key, account: .providerDefault, userInitiated: false)
        async let third = store.refresh(key: key, account: .providerDefault, userInitiated: false)
        let entries = await [first, second, third]

        XCTAssertEqual(script.calls, 1)
        XCTAssertEqual(Set(entries.map { $0.snapshot?.primaryWindow?.usedPercent }), [20])
    }

    // MARK: - Unsupported providers

    /// A plain terminal has no usage and never will. That is a gap in this
    /// layer rather than a problem with the account, and saying which is which
    /// keeps "unavailable" meaningful.
    func testAProviderWithNoRoutesSaysSo() async {
        let store = UsageStore(providers: [], clock: { self.currentTime })
        let terminalKey = UsageKey(provider: .terminal, accountID: nil)

        XCTAssertFalse(store.isSupported(.terminal))
        let entry = await store.refresh(key: terminalKey, account: .providerDefault, userInitiated: true)
        XCTAssertEqual(entry.snapshot?.unavailable, .providerUnsupported)
    }

    // MARK: - Accounts

    /// Two profiles of one provider have separate limits; that is the entire
    /// reason the account dimension exists. Sharing a snapshot between them
    /// would attach one login's numbers to the other's name.
    func testTwoAccountsOfOneProviderAreCachedSeparately() async {
        let first = UUID()
        let second = UUID()
        let script = ScriptedStrategy.Script([
            .success(snapshot(used: 10, at: 1_700_000_000)),
            .success(snapshot(used: 90, at: 1_700_000_000)),
        ])
        let store = store(script)

        await store.refresh(
            key: UsageKey(provider: .codex, accountID: first),
            account: UsageAccountContext(accountID: first), userInitiated: true
        )
        await store.refresh(
            key: UsageKey(provider: .codex, accountID: second),
            account: UsageAccountContext(accountID: second), userInitiated: true
        )

        XCTAssertEqual(
            store.snapshot(for: UsageKey(provider: .codex, accountID: first))?.primaryWindow?.usedPercent, 10
        )
        XCTAssertEqual(
            store.snapshot(for: UsageKey(provider: .codex, accountID: second))?.primaryWindow?.usedPercent, 90
        )
    }

    // MARK: - Diagnostics

    func testDiagnosticsNameTheRoutesAndCarryNoSecrets() async {
        let script = ScriptedStrategy.Script([.success(snapshot(used: 20, at: 1_700_000_000))])
        let store = store(script)
        await store.refresh(key: key, account: .providerDefault, userInitiated: true)

        let text = store.diagnostics(for: key)
        XCTAssertTrue(text.contains("codexOAuthAPI"))
        XCTAssertTrue(text.contains("80% remaining"))
        XCTAssertFalse(text.lowercased().contains("bearer"))
    }
}

// MARK: - Account isolation

/// Which config directory each provider asks about.
final class UsageAccountIsolationTests: XCTestCase {

    /// An Uncoil account profile *is* a separate `CODEX_HOME` — that is how the
    /// app isolates two logins at launch — so usage has to be read from the
    /// same directory. The default home would put one login's numbers under the
    /// other's name, which is the one mistake here nobody could see being made.
    func testANamedCodexAccountReadsItsOwnHome() {
        let provider = CodexUsageProvider(
            homeDirectory: URL(fileURLWithPath: "/Users/x"), environment: [:]
        )
        let isolated = URL(fileURLWithPath: "/Users/x/profiles/codex/work")
        XCTAssertEqual(
            provider.codexHome(for: UsageAccountContext(configDirectory: isolated)), isolated
        )
        XCTAssertEqual(
            provider.codexHome(for: .providerDefault).path, "/Users/x/.codex"
        )
    }

    func testTheCodexHomeEnvironmentOverrideIsHonoured() {
        let provider = CodexUsageProvider(
            homeDirectory: URL(fileURLWithPath: "/Users/x"),
            environment: ["CODEX_HOME": "/elsewhere/codex"]
        )
        XCTAssertEqual(provider.codexHome(for: .providerDefault).path, "/elsewhere/codex")
    }

    func testANamedClaudeAccountReadsItsOwnConfigDirectory() {
        let provider = ClaudeUsageProvider(
            probeDirectory: URL(fileURLWithPath: "/tmp/probe"),
            homeDirectory: URL(fileURLWithPath: "/Users/x")
        )
        let isolated = URL(fileURLWithPath: "/Users/x/profiles/claude/work")
        XCTAssertEqual(
            provider.claudeHome(for: UsageAccountContext(configDirectory: isolated)), isolated
        )
        XCTAssertEqual(provider.claudeHome(for: .providerDefault).path, "/Users/x/.claude")
    }

    /// The web-session route is absent unless something supplies a cookie, so
    /// the browser is never reached for on its own.
    func testTheClaudeWebRouteIsAbsentUnlessACookieIsSupplied() {
        let without = ClaudeUsageProvider(probeDirectory: URL(fileURLWithPath: "/tmp/probe"))
        XCTAssertFalse(
            without.strategies(for: .providerDefault).contains { $0.source == .claudeWebSession }
        )

        let with = ClaudeUsageProvider(
            probeDirectory: URL(fileURLWithPath: "/tmp/probe"),
            webSessionKey: { "cookie" }
        )
        XCTAssertTrue(
            with.strategies(for: .providerDefault).contains { $0.source == .claudeWebSession }
        )
    }

    /// The Keychain item is not scoped to a config directory, so it can only
    /// answer for the default account. Reading it for a named profile would
    /// report the default account's usage under another name.
    func testTheKeychainIsOnlyConsultedForTheDefaultAccount() {
        let provider = ClaudeUsageProvider(
            probeDirectory: URL(fileURLWithPath: "/tmp/probe"),
            homeDirectory: URL(fileURLWithPath: "/Users/x")
        )
        let named = provider.strategies(
            for: UsageAccountContext(configDirectory: URL(fileURLWithPath: "/Users/x/profiles/claude/work"))
        )
        let oauth = named.compactMap { $0 as? ClaudeOAuthUsageStrategy }.first
        XCTAssertEqual(oauth?.usesDefaultHome, false)

        let standard = provider.strategies(for: .providerDefault)
            .compactMap { $0 as? ClaudeOAuthUsageStrategy }.first
        XCTAssertEqual(standard?.usesDefaultHome, true)
    }

    /// The allowlist is the point: a usage monitor that can be pointed at an
    /// arbitrary Keychain service is a credential reader with a friendly name.
    func testOnlyAllowlistedKeychainServicesCanBeRead() {
        XCTAssertNil(UsageCredentials.readKeychainString(service: "login"))
        XCTAssertNil(UsageCredentials.readKeychainString(service: "com.apple.something"))
        XCTAssertTrue(UsageCredentials.allowedKeychainServices.contains("Claude Code-credentials"))
    }
}
