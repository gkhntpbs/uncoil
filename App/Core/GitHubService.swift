import Foundation
import Security

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
