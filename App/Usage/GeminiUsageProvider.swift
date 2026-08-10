import Foundation

/// Gemini's quota route: the Code Assist API, using the CLI's own OAuth state.
///
/// One strategy, not three, and that is the honest shape. Gemini has no second
/// route worth having: there is no usage panel in the CLI to read and no
/// cookie-based equivalent, so a fallback here would be a fallback in name.
///
/// The important thing this provider does is fail *specifically*. Google
/// withdrew this route from the consumer tiers on 18 June 2026, and the refusal
/// that produces is not an empty quota — an account with a full allowance can
/// receive it. Reporting that as `0% remaining` would be a lie with
/// consequences, since the number is meant to drive a decision. It is reported
/// as "unavailable for this authentication", with the reason attached.
struct GeminiUsageProvider: UsageProvider {
    var provider: AgentProvider { .gemini }

    var http: UsageHTTPClient = UsageURLSessionClient()
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var locateBinary: (String) -> String? = { AgentAdapterSupport.locateBinary($0) }
    var clock: () -> Date = Date.init

    func strategies(for account: UsageAccountContext) -> [UsageFetchStrategy] {
        [
            GeminiCodeAssistStrategy(
                http: http,
                geminiHome: geminiHome(for: account),
                accountID: account.accountID,
                oauthClient: {
                    GeminiOAuthClient.resolve(
                        environment: environment,
                        binaryPath: locateBinary("gemini")
                    )
                },
                clock: clock
            ),
        ]
    }

    /// Gemini has no verified environment variable for an isolated config root
    /// — `AccountProfile.isolationEnvironmentKey` returns nil for it and says
    /// why — so a named profile falls back to the CLI's own home rather than
    /// pretending to read a directory that would not exist.
    func geminiHome(for account: UsageAccountContext) -> URL {
        account.configDirectory
            ?? homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
    }
}

// MARK: - Authentication mode

/// How the Gemini CLI is configured to authenticate.
///
/// It matters because only one of these can answer for quota. An API key and a
/// Vertex configuration are perfectly working setups that this route cannot
/// read, and saying that plainly is better than showing an empty figure for an
/// account that is fine.
enum GeminiAuthMode: Equatable {
    case oauthPersonal
    case apiKey
    case vertexAI
    case unknown(String)

    static func read(settingsAt url: URL) -> GeminiAuthMode {
        guard let json = try? UsageCredentials.readJSONFile(at: url),
              let root = json.objectValue else { return .oauthPersonal }
        let security = UsageJSON.object(root, ["security"])
        let auth = security.flatMap { UsageJSON.object($0, ["auth"]) }
        guard let raw = UsageJSON.string(auth ?? root, ["selectedType", "selected_type", "authType", "auth_type"])
        else { return .oauthPersonal }

        switch raw.lowercased() {
        case "oauth-personal", "oauth_personal", "login-with-google", "oauth":
            return .oauthPersonal
        case "gemini-api-key", "api-key", "use_gemini", "usegemini":
            return .apiKey
        case "vertex-ai", "vertex_ai", "use_vertex_ai", "usevertexai":
            return .vertexAI
        default:
            return .unknown(raw)
        }
    }
}

// MARK: - OAuth client

/// The client id and secret the installed Gemini CLI itself uses.
///
/// A refresh token is only exchangeable by the client it was issued to, so
/// refreshing the CLI's token requires the CLI's own client configuration.
/// There is no published constant for it; it is a literal in the installed
/// package, and reading it out of the copy already on the machine is the only
/// way that stays correct when the CLI is updated.
///
/// Read-only, and only ever from a file the user already installed. The
/// environment override exists so that a machine where the search fails is a
/// setting away from working rather than a rebuild away.
struct GeminiOAuthClient: Equatable {
    var clientID: String
    var clientSecret: String

    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static func resolve(environment: [String: String], binaryPath: String?) -> GeminiOAuthClient? {
        if let id = environment["UNCOIL_GEMINI_OAUTH_CLIENT_ID"],
           let secret = environment["UNCOIL_GEMINI_OAUTH_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty {
            return GeminiOAuthClient(clientID: id, clientSecret: secret)
        }
        if let explicit = environment["UNCOIL_GEMINI_OAUTH2_PATH"],
           let found = extract(fromFileAt: URL(fileURLWithPath: explicit)) {
            return found
        }
        for url in searchRoots(binaryPath: binaryPath) {
            if let found = search(under: url) { return found }
        }
        return nil
    }

    /// Where the installed package might be, most specific first.
    ///
    /// The binary's *resolved* path leads the list for the same reason it does
    /// in `AgentCLIInstall`: the launcher is a symlink, and the install it
    /// belongs to is only visible at the other end of it. A Node under nvm,
    /// fnm, asdf or Homebrew all answer correctly this way, and none of them
    /// answer correctly from a hard-coded prefix.
    static func searchRoots(binaryPath: String?) -> [URL] {
        var roots: [URL] = []
        if let binaryPath {
            let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
            var directory = resolved.deletingLastPathComponent()
            // Walk up to the node_modules that contains this package.
            for _ in 0..<8 {
                if directory.lastPathComponent == "node_modules" {
                    roots.append(directory.appendingPathComponent("@google", isDirectory: true))
                    break
                }
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@google"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google"),
            home.appendingPathComponent(".npm-global/lib/node_modules/@google"),
        ])
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Finds `oauth2.js` under a package root and reads the pair out of it.
    ///
    /// Depth-limited on purpose: a `node_modules` tree is deep enough that an
    /// unbounded walk is a real cost on a background refresh, and the file has
    /// never been more than a few levels in.
    static func search(under root: URL, maxDepth: Int = 6) -> GeminiOAuthClient? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "oauth2.js" else { continue }
            if let found = extract(fromFileAt: url) { return found }
        }
        return nil
    }

    static func extract(fromFileAt url: URL) -> GeminiOAuthClient? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return extract(from: text)
    }

    /// Pulls the two literals out of the source.
    ///
    /// Written against the shape rather than the exact declaration so that a
    /// `const`, a `let` or a property assignment all match: the CLI's build
    /// output has used more than one of these.
    static func extract(from source: String) -> GeminiOAuthClient? {
        guard let id = capture(#"OAUTH_CLIENT_ID\s*[:=]\s*['"]([^'"]+)['"]"#, in: source),
              let secret = capture(#"OAUTH_CLIENT_SECRET\s*[:=]\s*['"]([^'"]+)['"]"#, in: source)
        else { return nil }
        return GeminiOAuthClient(clientID: id, clientSecret: secret)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Credentials

struct GeminiCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?

    static func url(in geminiHome: URL) -> URL {
        geminiHome.appendingPathComponent("oauth_creds.json")
    }

    static func parse(_ json: JSONValue) throws -> GeminiCredentials {
        guard let root = json.objectValue,
              let token = UsageJSON.string(root, ["access_token", "accessToken"]) else {
            throw UsageFetchError(.credentialsMissing, detail: "no access token")
        }
        return GeminiCredentials(
            accessToken: token,
            refreshToken: UsageJSON.string(root, ["refresh_token", "refreshToken"]),
            expiry: UsageJSON.double(root, ["expiry_date", "expiryDate", "expires_at"])
                .map(UsageCredentials.expiryDate(fromEpoch:))
        )
    }
}

// MARK: - Strategy

struct GeminiCodeAssistStrategy: UsageFetchStrategy {
    static let loadEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    var http: UsageHTTPClient
    var geminiHome: URL
    var accountID: UUID?
    var oauthClient: () -> GeminiOAuthClient?
    var clock: () -> Date

    var source: UsageSource { .geminiCodeAssistAPI }

    func isAvailable() -> Bool {
        UsageCredentials.fileExists(at: GeminiCredentials.url(in: geminiHome))
    }

    func fetch() async throws -> UsageSnapshot {
        let mode = GeminiAuthMode.read(
            settingsAt: geminiHome.appendingPathComponent("settings.json")
        )
        switch mode {
        case .apiKey, .vertexAI:
            // Terminal: another route would give the same answer, and the
            // configuration is not broken — it simply is not the one that can
            // be read.
            throw UsageFetchError(.authenticationTypeUnsupported, detail: nil)
        case .oauthPersonal, .unknown:
            break
        }

        let stored = try GeminiCredentials.parse(
            try UsageCredentials.readJSONFile(at: GeminiCredentials.url(in: geminiHome))
        )
        let token = try await accessToken(stored)

        let account = try await loadCodeAssist(token: token)
        if account.ineligible {
            throw UsageFetchError(.accountTierUnsupported, detail: account.tier)
        }

        var body: [String: JSONValue] = [:]
        // Sent only when there is one. An empty project field is not the same
        // as an absent one, and the API treats it differently.
        if let project = account.projectID { body["project"] = .string(project) }

        let response = try await http.send(.postJSON(
            Self.quotaEndpoint,
            bearer: token,
            body: try JSONEncoder().encode(JSONValue.object(body))
        ))

        guard response.isSuccess else {
            if GeminiUsageParser.indicatesUnsupportedTier(response.body) {
                throw UsageFetchError(.accountTierUnsupported, detail: account.tier)
            }
            throw response.failure()
        }

        return try GeminiUsageParser.snapshot(
            from: try response.json(),
            accountID: accountID,
            identity: account.identity,
            source: source,
            now: clock()
        )
    }

    // MARK: - Token

    /// A live token, refreshing the stored one if it has expired.
    ///
    /// The refreshed token is used and not written back. The CLI owns that
    /// file, and a monitor that rewrote it could, on a bad day, log the user
    /// out of the tool it is monitoring.
    private func accessToken(_ stored: GeminiCredentials) async throws -> String {
        if let expiry = stored.expiry, UsageCredentials.isExpired(expiry, now: clock()) {
            guard let refreshToken = stored.refreshToken else {
                throw UsageFetchError(.credentialsExpired, detail: nil)
            }
            guard let client = oauthClient() else {
                // Without the CLI's own client configuration the refresh cannot
                // be made at all, and saying which piece is missing is the
                // difference between a fixable report and a shrug.
                throw UsageFetchError(
                    .credentialsExpired,
                    detail: "the Gemini CLI's OAuth client could not be located"
                )
            }
            return try await refresh(refreshToken: refreshToken, client: client)
        }
        return stored.accessToken
    }

    private func refresh(refreshToken: String, client: GeminiOAuthClient) async throws -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        let body = Data((components.percentEncodedQuery ?? "").utf8)

        let response = try await http.send(UsageHTTPRequest(
            url: GeminiOAuthClient.tokenEndpoint,
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: body,
            timeout: 10
        ))
        guard response.isSuccess,
              let root = try? response.json().objectValue,
              let token = UsageJSON.string(root, ["access_token"]) else {
            throw UsageFetchError(.credentialsExpired, detail: "refresh was refused")
        }
        return token
    }

    private func loadCodeAssist(token: String) async throws -> GeminiUsageParser.CodeAssistAccount {
        // The metadata identifies the caller as the Gemini CLI's integration,
        // which is what the endpoint expects; it is not a claim to be another
        // product, it is the shape of the request.
        let payload = JSONValue.object([
            "metadata": .object([
                "ideType": .string("IDE_UNSPECIFIED"),
                "platform": .string("PLATFORM_UNSPECIFIED"),
                "pluginType": .string("GEMINI"),
            ]),
        ])
        let response = try await http.send(.postJSON(
            Self.loadEndpoint, bearer: token, body: try JSONEncoder().encode(payload)
        ))
        guard response.isSuccess else {
            if GeminiUsageParser.indicatesUnsupportedTier(response.body) {
                throw UsageFetchError(.accountTierUnsupported, detail: nil)
            }
            throw response.failure()
        }
        return GeminiUsageParser.account(from: try response.json())
    }
}
