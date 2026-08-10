import Foundation

/// Claude's usage routes, preferred first.
///
/// 1. The OAuth usage endpoint, using the credential Claude Code already holds.
/// 2. The installed CLI's own `/usage` panel, read in a pseudo-terminal.
/// 3. A `claude.ai` session cookie — off unless the user turns it on.
///
/// The order is by how invasive each is, not by how convenient. The first
/// reuses a credential the agent already put on this machine; the second
/// spawns the agent's own binary with everything switched off; the third
/// reaches into a browser's cookie store, which is why it is opt-in and last.
struct ClaudeUsageProvider: UsageProvider {
    var provider: AgentProvider { .claude }

    var http: UsageHTTPClient = UsageURLSessionClient()
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var locateBinary: (String) -> String? = { AgentAdapterSupport.locateBinary($0) }
    var probeDirectory: URL
    var clock: () -> Date = Date.init
    /// Supplies a `claude.ai` session cookie when the user has enabled that
    /// route. Absent by default, which is what keeps the browser out of it.
    var webSessionKey: (() -> String?)?

    init(
        probeDirectory: URL,
        http: UsageHTTPClient = UsageURLSessionClient(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        locateBinary: @escaping (String) -> String? = { AgentAdapterSupport.locateBinary($0) },
        clock: @escaping () -> Date = Date.init,
        webSessionKey: (() -> String?)? = nil
    ) {
        self.probeDirectory = probeDirectory
        self.http = http
        self.homeDirectory = homeDirectory
        self.locateBinary = locateBinary
        self.clock = clock
        self.webSessionKey = webSessionKey
    }

    func strategies(for account: UsageAccountContext) -> [UsageFetchStrategy] {
        let configDirectory = claudeHome(for: account)
        var strategies: [UsageFetchStrategy] = [
            ClaudeOAuthUsageStrategy(
                http: http,
                configDirectory: configDirectory,
                usesDefaultHome: account.configDirectory == nil,
                accountID: account.accountID,
                clock: clock
            ),
            ClaudeCLIUsageStrategy(
                executable: locateBinary("claude"),
                probeDirectory: probeDirectory,
                configDirectory: account.configDirectory,
                accountID: account.accountID,
                clock: clock
            ),
        ]
        if let webSessionKey {
            strategies.append(ClaudeWebSessionUsageStrategy(
                http: http,
                sessionKey: webSessionKey,
                accountID: account.accountID,
                clock: clock
            ))
        }
        return strategies
    }

    func claudeHome(for account: UsageAccountContext) -> URL {
        account.configDirectory
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }
}

// MARK: - Credentials

/// The OAuth state Claude Code keeps, from wherever it keeps it.
struct ClaudeAuth: Equatable {
    var accessToken: String
    var expiry: Date?
    var scopes: [String]

    /// Only a real Claude authorisation counts.
    ///
    /// The Keychain item can hold OAuth state for an MCP server the user
    /// authorised, in the same JSON, under a different key. Accepting any token
    /// found in the file would send an MCP server's token to Anthropic's API,
    /// which fails in a way that reads as "your Claude login is broken".
    static func parse(_ json: JSONValue) throws -> ClaudeAuth {
        guard let root = json.objectValue else {
            throw UsageFetchError(.credentialsMissing, detail: "credentials are not an object")
        }
        guard let oauth = UsageJSON.object(root, ["claudeAiOauth", "claude_ai_oauth"]),
              let token = UsageJSON.string(oauth, ["accessToken", "access_token"]) else {
            throw UsageFetchError(.credentialsMissing, detail: "no Claude OAuth credential")
        }
        let expiry = UsageJSON.double(oauth, ["expiresAt", "expires_at"])
            .map(UsageCredentials.expiryDate(fromEpoch:))
        let scopes = UsageJSON.array(oauth, ["scopes", "scope"])?.compactMap(\.stringValue)
            ?? UsageJSON.string(oauth, ["scope"])?.components(separatedBy: " ")
            ?? []
        return ClaudeAuth(accessToken: token, expiry: expiry, scopes: scopes)
    }

    /// The Keychain first, then the file.
    ///
    /// Claude Code moved its credentials into the Keychain and still writes the
    /// file on some installs, so both are read. The Keychain copy wins because
    /// where both exist the file is the older of the two.
    static func load(configDirectory: URL, usesDefaultHome: Bool) throws -> ClaudeAuth {
        var lastError: UsageFetchError?

        // The Keychain item is not scoped to a config directory, so it can only
        // answer for the default account. Reading it for a named profile would
        // report the default account's usage under another name.
        if usesDefaultHome,
           let raw = UsageCredentials.readKeychainString(service: "Claude Code-credentials"),
           let data = raw.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            do { return try parse(json) } catch let error as UsageFetchError { lastError = error }
        }

        let fileURL = configDirectory.appendingPathComponent(".credentials.json")
        if UsageCredentials.fileExists(at: fileURL) {
            return try parse(try UsageCredentials.readJSONFile(at: fileURL))
        }
        throw lastError ?? UsageFetchError(.credentialsMissing, detail: nil)
    }
}

// MARK: - Strategy 1: the OAuth usage endpoint

struct ClaudeOAuthUsageStrategy: UsageFetchStrategy {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// The header the OAuth-scoped endpoints require; without it they refuse.
    static let betaHeader = ["anthropic-beta": "oauth-2025-04-20"]

    var http: UsageHTTPClient
    var configDirectory: URL
    var usesDefaultHome: Bool
    var accountID: UUID?
    var clock: () -> Date

    var source: UsageSource { .claudeOAuthAPI }

    func isAvailable() -> Bool {
        if usesDefaultHome,
           UsageCredentials.readKeychainString(service: "Claude Code-credentials") != nil {
            return true
        }
        return UsageCredentials.fileExists(
            at: configDirectory.appendingPathComponent(".credentials.json")
        )
    }

    func fetch() async throws -> UsageSnapshot {
        let auth = try ClaudeAuth.load(
            configDirectory: configDirectory, usesDefaultHome: usesDefaultHome
        )
        if let expiry = auth.expiry, UsageCredentials.isExpired(expiry, now: clock()) {
            throw UsageFetchError(.credentialsExpired, detail: nil)
        }

        let response = try await http.send(
            .get(Self.usageEndpoint, bearer: auth.accessToken, headers: Self.betaHeader)
        )
        guard response.isSuccess else { throw response.failure() }

        // Identity is a second request and is allowed to fail on its own: a
        // profile that cannot be read is a missing label, not a missing number.
        let identity = await profile(token: auth.accessToken)

        return try ClaudeUsageParser.snapshot(
            from: try response.json(),
            accountID: accountID,
            identity: identity,
            source: source,
            now: clock()
        )
    }

    private func profile(token: String) async -> UsageIdentity? {
        guard let response = try? await http.send(
            .get(Self.profileEndpoint, bearer: token, headers: Self.betaHeader, timeout: 6)
        ), response.isSuccess, let json = try? response.json() else { return nil }
        return ClaudeUsageParser.identity(from: json)
    }
}

// MARK: - Strategy 2: the CLI panel

struct ClaudeCLIUsageStrategy: UsageFetchStrategy {
    var executable: String?
    var probeDirectory: URL
    var configDirectory: URL?
    var accountID: UUID?
    var clock: () -> Date

    var source: UsageSource { .claudeCLIProbe }

    func isAvailable() -> Bool {
        guard let executable else { return false }
        return FileManager.default.isExecutableFile(atPath: executable)
    }

    func fetch() async throws -> UsageSnapshot {
        guard let executable else { throw UsageFetchError(.notApplicable, detail: nil) }
        let configuration = ClaudeUsageProbe.Configuration(
            executable: executable,
            workingDirectory: probeDirectory,
            configDirectory: configDirectory
        )
        let now = clock()
        let accountID = accountID
        let source = source

        return try await Task.detached(priority: .utility) { () throws -> UsageSnapshot in
            let raw = try ClaudeUsageProbe(configuration: configuration).run()
            let parsed = ClaudeUsagePanelParser.parse(raw)
            if let failure = parsed.failure { throw failure }

            let windows = [parsed.session, parsed.week].compactMap { $0 } + parsed.extras
            guard !windows.isEmpty else {
                // The panel was drawn and held no number this parser could
                // read. Reported as a failure of the route, so the next one is
                // tried, rather than as an account with no quota — which is a
                // claim about the user's plan we have no grounds for.
                throw UsageFetchError(.malformedResponse, detail: "no usage figures in the panel")
            }
            return UsageSnapshot(
                provider: .claude,
                accountID: accountID,
                identity: parsed.identity,
                primaryWindow: parsed.session,
                secondaryWindow: parsed.week,
                extraWindows: parsed.extras,
                source: source,
                updatedAt: now
            )
        }.value
    }
}

// MARK: - Strategy 3: the web session

/// Last resort, and off unless the user switches it on.
///
/// It works from a `claude.ai` session cookie, which is a credential for the
/// whole account rather than a scoped token — so it is never reached for
/// automatically, and the cookie is never discovered by this type. Something
/// else supplies it, and the user has to have said yes to that.
struct ClaudeWebSessionUsageStrategy: UsageFetchStrategy {
    static let organizationsEndpoint = URL(string: "https://claude.ai/api/organizations")!

    var http: UsageHTTPClient
    var sessionKey: () -> String?
    var accountID: UUID?
    var clock: () -> Date

    var source: UsageSource { .claudeWebSession }

    func isAvailable() -> Bool {
        guard let key = sessionKey() else { return false }
        return !key.isEmpty
    }

    func fetch() async throws -> UsageSnapshot {
        guard let key = sessionKey(), !key.isEmpty else {
            throw UsageFetchError(.notApplicable, detail: nil)
        }
        let headers = ["Cookie": "sessionKey=\(key)", "Accept": "application/json"]

        let organizations = try await request(Self.organizationsEndpoint, headers: headers)
        guard let first = organizations.arrayValue?.first?.objectValue,
              let organizationID = UsageJSON.string(first, ["uuid", "id"]) else {
            throw UsageFetchError(.malformedResponse, detail: "no organization in the response")
        }
        guard let usageURL = URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage") else {
            throw UsageFetchError(.malformedResponse, detail: "organization id is not usable in a URL")
        }

        let usage = try await request(usageURL, headers: headers)
        let identity = UsageIdentity(
            email: nil,
            plan: UsageJSON.string(first, ["billing_type", "billingType"]),
            organization: UsageJSON.string(first, ["name"])
        )
        return try ClaudeUsageParser.snapshot(
            from: usage,
            accountID: accountID,
            identity: identity,
            source: source,
            now: clock()
        )
    }

    private func request(_ url: URL, headers: [String: String]) async throws -> JSONValue {
        let response = try await http.send(
            UsageHTTPRequest(url: url, method: .get, headers: headers, timeout: 10)
        )
        guard response.isSuccess else { throw response.failure() }
        return try response.json()
    }
}
