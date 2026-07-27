import CryptoKit
import Foundation

enum CatalogError: LocalizedError, Equatable {
    case offline(String)
    case http(Int)
    /// The provider wants a credential the user has not supplied yet.
    case authenticationRequired
    /// The provider is throttling this client; retrying later helps, and a
    /// GitHub-backed provider gets far higher limits once connected.
    case rateLimited
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .offline(let detail):
            String(localized: "The catalog could not be reached: \(detail)")
        case .http(let status):
            String(localized: "The catalog answered with HTTP \(status).")
        case .authenticationRequired:
            String(localized: "The catalog's source rejected the sign-in; reconnect and try again.")
        case .rateLimited:
            String(localized: "The source is rate-limiting requests right now. Try again in a minute — signing in to GitHub raises the limit considerably.")
        case .malformed(let detail):
            String(localized: "The catalog's answer was not in the expected shape: \(detail)")
        }
    }
}

/// Disk cache for catalog responses, keyed by URL. One file per response; the
/// file's modification date is when it was fetched, so there is no envelope to
/// keep consistent.
struct CatalogDiskCache {
    var root: URL

    static func `default`(layout: ExtensionStoreLayout = .default()) -> CatalogDiskCache {
        CatalogDiskCache(root: layout.root.appendingPathComponent("catalog-cache", isDirectory: true))
    }

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(digest).response")
    }

    func read(_ url: URL) -> (data: Data, fetchedAt: Date)? {
        let file = file(for: url)
        guard let data = FileManager.default.contents(atPath: file.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (data, date)
    }

    func write(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: file(for: url), options: .atomic)
    }
}

/// The one HTTP path every catalog provider goes through: cache-first inside
/// the TTL, network after it, and the stale cache as the fallback when the
/// network fails — a catalog that was browsable yesterday stays browsable on a
/// train.
struct CatalogHTTPClient {
    /// Injected so tests never touch the network.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }
    var cache: CatalogDiskCache?
    var now: () -> Date = { .now }

    struct Response: Equatable {
        var data: Data
        /// True when this came from the cache because the network failed —
        /// the caller shows it as possibly stale.
        var isStaleFallback: Bool
    }

    func get(_ url: URL, ttl: TimeInterval, headers: [String: String] = [:]) async throws -> Response {
        if let cached = cache?.read(url),
           now().timeIntervalSince(cached.fetchedAt) < ttl {
            return Response(data: cached.data, isStaleFallback: false)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Uncoil (macOS)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            try Task.checkCancellation()
            let (data, response) = try await send(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // A missing or rejected credential is its own answer; stale
                // cached data would hide exactly the state the user must fix.
                if http.statusCode == 401 { throw CatalogError.authenticationRequired }
                if http.statusCode == 429 || http.statusCode == 403 {
                    // GitHub reports an exhausted limit as 403; both read as
                    // "throttled" here. The stale-cache fallback below still
                    // applies — old results beat none while throttled.
                    throw CatalogError.rateLimited
                }
                throw CatalogError.http(http.statusCode)
            }
            cache?.write(data, for: url)
            return Response(data: data, isStaleFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch CatalogError.authenticationRequired {
            throw CatalogError.authenticationRequired
        } catch {
            // Any cached copy, however old, beats an error screen — marked
            // stale so the UI says so instead of pretending it is current.
            if let cached = cache?.read(url) {
                return Response(data: cached.data, isStaleFallback: true)
            }
            if let catalogError = error as? CatalogError { throw catalogError }
            throw CatalogError.offline(error.localizedDescription)
        }
    }

    func getJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        ttl: TimeInterval,
        headers: [String: String] = [:]
    ) async throws -> (value: T, isStaleFallback: Bool) {
        let response = try await get(url, ttl: ttl, headers: headers)
        do {
            return (try JSONDecoder().decode(type, from: response.data), response.isStaleFallback)
        } catch {
            throw CatalogError.malformed(String(describing: error).prefix(200).description)
        }
    }
}

/// GitHub repository facts as a secondary enrichment source. Unauthenticated
/// and best-effort: a rate-limited or offline answer just means no facts.
struct GitHubEnrichment {
    var client: CatalogHTTPClient

    private struct RepoDTO: Decodable {
        var stargazers_count: Int?
        var forks_count: Int?
        var license: LicenseDTO?
        var pushed_at: String?
        var archived: Bool?
        var default_branch: String?

        struct LicenseDTO: Decodable { var spdx_id: String? }
    }

    /// `repository` is "owner/repo". Cached for a day; nil on any failure.
    func facts(for repository: String) async -> CatalogRepoFacts? {
        guard repository.split(separator: "/").count == 2,
              let url = URL(string: "https://api.github.com/repos/\(repository)") else { return nil }
        guard let (dto, _) = try? await client.getJSON(RepoDTO.self, from: url, ttl: 86_400) else {
            return nil
        }
        return CatalogRepoFacts(
            stars: dto.stargazers_count,
            forks: dto.forks_count,
            license: dto.license?.spdx_id.flatMap { $0 == "NOASSERTION" ? nil : $0 },
            pushedAt: CatalogDates.parse(dto.pushed_at),
            archived: dto.archived,
            defaultBranch: dto.default_branch
        )
    }
}
