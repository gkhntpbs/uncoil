import Foundation
import Security
import AppKit

/// Open pull requests for the dashboard. Public repos work without a token;
/// a personal access token (stored only in the Keychain) unlocks private
/// repos and higher rate limits.
enum GitHubService {
    struct PullRequest: Identifiable, Equatable {
        let id: Int
        let number: Int
        let title: String
        let author: String
        let isDraft: Bool
        let htmlURL: URL?
    }

    enum FetchError: LocalizedError {
        case notGitHub
        case http(Int)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notGitHub: "Origin GitHub deposu değil."
            case .http(let code):
                code == 404
                    ? "Depo bulunamadı — özel depo için ayarlardan token ekle."
                    : "GitHub \(code) döndürdü."
            case .network(let message): message
            }
        }
    }

    /// "git@github.com:owner/repo.git" or "https://github.com/owner/repo(.git)"
    static func repoSlug(fromRemoteURL remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var slug: Substring?
        if trimmed.hasPrefix("git@github.com:") {
            slug = trimmed.dropFirst("git@github.com:".count)[...]
        } else if let range = trimmed.range(of: "github.com/") {
            slug = trimmed[range.upperBound...]
        }
        guard var result = slug else { return nil }
        if result.hasSuffix(".git") { result = result.dropLast(4) }
        let parts = result.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    static func openPullRequests(slug: String) async -> Result<[PullRequest], FetchError> {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(slug)/pulls?state=open&per_page=15")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = KeychainStore.read(key: "github-token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(.http(status)) }
            let items = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            return .success(parsePullRequests(items))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    static func parsePullRequests(_ items: [[String: Any]]) -> [PullRequest] {
        items.compactMap { item in
            guard
                let id = item["id"] as? Int,
                let number = item["number"] as? Int,
                let title = item["title"] as? String
            else { return nil }
            return PullRequest(
                id: id,
                number: number,
                title: title,
                author: (item["user"] as? [String: Any])?["login"] as? String ?? "?",
                isDraft: item["draft"] as? Bool ?? false,
                htmlURL: (item["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
    }
}

// MARK: - Browser login (OAuth device flow)

/// GitHub device-flow login: the user authorizes in the browser with a short
/// code; the resulting token goes straight to the Keychain. No secrets in
/// the app bundle — the device flow needs only a public client id.
enum GitHubAuthService {
    /// GitHub CLI's public device-flow client id (shipped openly in `gh`).
    static let clientID = "178c6fc778ccc68e1d6a"

    struct DeviceCode: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: TimeInterval
        let expiresIn: TimeInterval
    }

    enum AuthError: LocalizedError {
        case network(String)
        case denied
        case expired
        case malformed

        var errorDescription: String? {
            switch self {
            case .network(let message): message
            case .denied: "Giriş reddedildi."
            case .expired: "Kod süresi doldu — yeniden dene."
            case .malformed: "GitHub beklenmedik bir yanıt döndürdü."
            }
        }
    }

    static func requestDeviceCode() async -> Result<DeviceCode, AuthError> {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("client_id=\(clientID)&scope=repo%20read:org".utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let code = parseDeviceCode(data) else { return .failure(.malformed) }
            return .success(code)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    static func parseDeviceCode(_ data: Data) -> DeviceCode? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = object["device_code"] as? String,
            let userCode = object["user_code"] as? String,
            let uri = object["verification_uri"] as? String,
            let url = URL(string: uri)
        else { return nil }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            interval: TimeInterval(object["interval"] as? Int ?? 5),
            expiresIn: TimeInterval(object["expires_in"] as? Int ?? 900)
        )
    }

    /// Polls until the user authorizes in the browser. Returns the token.
    static func pollForToken(_ code: DeviceCode) async -> Result<String, AuthError> {
        let deadline = Date().addingTimeInterval(code.expiresIn)
        var interval = max(5, code.interval)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return .failure(.denied) }

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "client_id=\(clientID)&device_code=\(code.deviceCode)"
                + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            request.httpBody = Data(body.utf8)
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let token = object["access_token"] as? String {
                return .success(token)
            }
            switch object["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                return .failure(.denied)
            case "expired_token":
                return .failure(.expired)
            default:
                continue
            }
        }
        return .failure(.expired)
    }

    /// Logged-in account's username, for display in settings.
    static func fetchUsername(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["login"] as? String
    }
}

// MARK: - Browsers

/// Browsers offered when opening the login URL.
enum BrowserApp: String, CaseIterable, Identifiable {
    case safari
    case chrome
    case arc
    case firefox
    case edge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .firefox: "Firefox"
        case .edge: "Edge"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        case .edge: "com.microsoft.edgemac"
        }
    }

    static var installed: [BrowserApp] {
        allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    func open(_ url: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Minimal Keychain wrapper — secrets never land in settings.json.
enum KeychainStore {
    private static let service = "com.gkhntpbs.uncoil"

    static func save(key: String, value: String) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
