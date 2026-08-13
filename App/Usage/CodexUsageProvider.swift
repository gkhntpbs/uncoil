import Foundation

/// Codex's usage routes, preferred first.
///
/// 1. The authenticated usage endpoint, using the OAuth token Codex already
///    holds. Cheapest and freshest: one HTTPS request, no process.
/// 2. `codex app-server`, over JSON-RPC. Costs a process, but works when the
///    endpoint moves or the token shape changes, because it asks Codex itself.
///
/// What is deliberately *not* here is the interactive `/status` TUI. Driving it
/// is the kind of fallback that looks free and is not: it can trigger a login
/// flow and open a browser, which is an unacceptable thing for a background
/// refresh to do on a timer.
struct CodexUsageProvider: UsageProvider {
    var provider: AgentProvider { .codex }

    var http: UsageHTTPClient = UsageURLSessionClient()
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var locateBinary: (String) -> String? = { AgentAdapterSupport.locateBinary($0) }
    var clock: () -> Date = Date.init

    func strategies(
        for account: UsageAccountContext, userInitiated: Bool
    ) -> [UsageFetchStrategy] {
        _ = userInitiated  // Codex's credential file needs no permission.
        let home = codexHome(for: account)
        return [
            CodexOAuthUsageStrategy(
                http: http, codexHome: home, accountID: account.accountID, clock: clock
            ),
            CodexAppServerUsageStrategy(
                codexHome: home,
                accountID: account.accountID,
                executable: locateBinary("codex"),
                clock: clock
            ),
        ]
    }

    /// Which `CODEX_HOME` this account lives in.
    ///
    /// An Uncoil account profile *is* a separate home — that is how the app
    /// isolates two Codex logins at launch — so the same directory has to be
    /// used when asking about usage. Reading the default home for a named
    /// account would put one login's numbers under the other's name, which is
    /// the one mistake in this layer nobody could see was being made.
    func codexHome(for account: UsageAccountContext) -> URL {
        if let directory = account.configDirectory { return directory }
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
}

// MARK: - Credentials

/// What Codex's `auth.json` holds that this layer needs.
struct CodexAuth: Equatable {
    var accessToken: String
    var accountID: String?
    var expiry: Date?

    /// Tokens live under `tokens` in the file Codex writes today, and have been
    /// seen at the top level in older ones. Both are read, because a user who
    /// has not logged in again since an upgrade still has a valid login.
    static func parse(_ json: JSONValue) throws -> CodexAuth {
        guard let root = json.objectValue else {
            throw UsageFetchError(.credentialsMissing, detail: "auth.json is not an object")
        }
        let tokens = UsageJSON.object(root, ["tokens"]) ?? root
        guard let token = UsageJSON.string(tokens, ["access_token", "accessToken"]) else {
            // An API-key-only auth.json is a real configuration, and it is not
            // one this route can answer for: the usage endpoint is tied to the
            // ChatGPT login, not to a key.
            throw UsageFetchError(.credentialsMissing, detail: "no OAuth access token")
        }
        let expiry = UsageJSON.double(tokens, ["expires_at", "expiresAt", "expiry", "expiry_date"])
            .map(UsageCredentials.expiryDate(fromEpoch:))
        return CodexAuth(
            accessToken: token,
            accountID: UsageJSON.string(tokens, ["account_id", "accountId"]),
            expiry: expiry
        )
    }

    static func url(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent("auth.json")
    }
}

// MARK: - Strategy 1: the usage endpoint

struct CodexOAuthUsageStrategy: UsageFetchStrategy {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    var http: UsageHTTPClient
    var codexHome: URL
    var accountID: UUID?
    var clock: () -> Date

    var source: UsageSource { .codexOAuthAPI }

    func isAvailable() -> Bool {
        UsageCredentials.fileExists(at: CodexAuth.url(in: codexHome))
    }

    func fetch() async throws -> UsageSnapshot {
        let auth = try CodexAuth.parse(
            try UsageCredentials.readJSONFile(at: CodexAuth.url(in: codexHome))
        )

        // A token known to be past its expiry is not sent. The request would be
        // refused anyway, and refreshing it here would mean writing to a file
        // Codex owns — which this layer does not do.
        if let expiry = auth.expiry, UsageCredentials.isExpired(expiry, now: clock()) {
            throw UsageFetchError(.credentialsExpired, detail: nil)
        }

        var headers: [String: String] = [:]
        // Sent only when the same file supplies it: it is not invented, and
        // team accounts are scoped by it.
        if let id = auth.accountID { headers["chatgpt-account-id"] = id }

        let response = try await http.send(
            .get(Self.endpoint, bearer: auth.accessToken, headers: headers)
        )
        guard response.isSuccess else { throw response.failure() }

        // The same response carries `email` and `plan_type` beside the limits.
        // Passing nil here threw them away and left the card unable to say
        // whose numbers it was showing — which is the first thing anyone with
        // two logins wants to know.
        let json = try response.json()
        return try CodexUsageParser.snapshot(
            from: json,
            accountID: accountID,
            identity: CodexUsageParser.identity(from: json),
            source: source,
            now: clock()
        )
    }
}

// MARK: - Strategy 2: the app-server

struct CodexAppServerUsageStrategy: UsageFetchStrategy {
    var codexHome: URL
    var accountID: UUID?
    var executable: String?
    var clock: () -> Date

    var source: UsageSource { .codexAppServerRPC }

    func isAvailable() -> Bool {
        guard let executable else { return false }
        return FileManager.default.isExecutableFile(atPath: executable)
    }

    func fetch() async throws -> UsageSnapshot {
        guard let executable else {
            throw UsageFetchError(.notApplicable, detail: nil)
        }
        let home = codexHome
        let now = clock()
        let accountID = accountID
        let source = source

        // Off the calling actor: the probe blocks on pipe reads, and every one
        // of its waits is already bounded, so the only thing left to get wrong
        // is doing it where the UI lives.
        return try await Task.detached(priority: .utility) { () throws -> UsageSnapshot in
            let probe = CodexAppServerProbe(
                configuration: .init(executable: executable, codexHome: home)
            )
            let reply = try probe.run()
            guard let rateLimits = reply.rateLimits else {
                throw UsageFetchError(.malformedResponse, detail: "no rate limits in reply")
            }
            let identity = reply.account.flatMap(CodexUsageParser.identity(from:))
            return try CodexUsageParser.snapshot(
                from: rateLimits,
                accountID: accountID,
                identity: identity,
                source: source,
                now: now
            )
        }.value
    }
}
