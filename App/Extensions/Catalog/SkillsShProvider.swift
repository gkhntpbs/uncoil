import Foundation

/// Client for skills.sh, the agent-skills registry.
///
/// NOT in the default runtime path: skills.sh gates its read API behind a
/// separate bearer token, which Uncoil does not ask the user for. The skill
/// catalog runs on `GitHubSkillProvider`; this client is kept as an optional
/// future provider behind the same `CatalogPage`/`CatalogItem` shapes.
struct SkillsShProvider {
    var client: CatalogHTTPClient
    var baseURL = URL(string: "https://skills.sh")!
    var listTTL: TimeInterval = 15 * 60
    /// skills.sh gates its read API behind a bearer token (Vercel OIDC). The
    /// token is the user's own, kept in the Keychain — never in the app or in
    /// any config file. Nil sends no header; the 401 becomes an
    /// `authenticationRequired` state the UI explains.
    var token: String?

    private var headers: [String: String] {
        token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    // MARK: - Wire shapes

    struct ListResponse: Decodable {
        var data: [SkillDTO]
        var pagination: Pagination?

        struct Pagination: Decodable {
            var page: Int?
            var hasMore: Bool?
        }
    }

    struct SearchResponse: Decodable {
        var data: [SkillDTO]
    }

    struct SkillDTO: Decodable {
        var id: String?
        var slug: String?
        var name: String?
        var source: String?
        var installs: Int?
        var installUrl: String?
        var change: Int?
    }

    struct DetailResponse: Decodable {
        var id: String?
        var source: String?
        var slug: String?
        var name: String?
        var installs: Int?
        var hash: String?
        var files: [FileDTO]?

        struct FileDTO: Decodable {
            var path: String?
            var contents: String?
        }
    }

    struct AuditResponse: Decodable {
        var audits: [AuditDTO]?

        struct AuditDTO: Decodable {
            var provider: String?
            var status: String?
            var summary: String?
            var auditedAt: String?
            var riskLevel: String?
        }
    }

    // MARK: - Requests

    /// Leaderboard or search. skills.sh paginates the leaderboard by page
    /// number; the cursor carries it as text. Search has no pagination.
    func page(_ query: CatalogQuery, perPage: Int = 30) async throws -> CatalogPage {
        let search = query.search.trimmingCharacters(in: .whitespaces)
        if search.count >= 2 {
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/v1/skills/search"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "q", value: search),
                URLQueryItem(name: "limit", value: "100"),
            ]
            let (response, stale) = try await client.getJSON(
                SearchResponse.self, from: components.url!, ttl: listTTL, headers: headers
            )
            return CatalogPage(
                items: response.data.compactMap(Self.item(from:)),
                nextCursor: nil,
                isFromCache: stale
            )
        }
        let page = query.cursor.flatMap(Int.init) ?? 0
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/skills"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "view", value: Self.viewParameter(query.view)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        let (response, stale) = try await client.getJSON(
            ListResponse.self, from: components.url!, ttl: listTTL, headers: headers
        )
        return CatalogPage(
            items: response.data.compactMap(Self.item(from:)),
            nextCursor: (response.pagination?.hasMore ?? false) ? String(page + 1) : nil,
            isFromCache: stale
        )
    }

    /// Full detail with the file contents; the audit list rides along when the
    /// registry has one (404 there simply means "never audited").
    func detail(source: String, slug: String) async throws -> (SkillCatalogDetails, installs: Int?) {
        guard let url = URL(string: "\(baseURL)/api/v1/skills/\(source)/\(slug)") else {
            throw CatalogError.malformed("bad skill reference \(source)/\(slug)")
        }
        let (response, _) = try await client.getJSON(DetailResponse.self, from: url, ttl: 5 * 60, headers: headers)
        return (
            SkillCatalogDetails(
                source: response.source ?? source,
                slug: response.slug ?? slug,
                contentHash: response.hash,
                files: (response.files ?? []).compactMap { file in
                    guard let path = file.path, let contents = file.contents else { return nil }
                    return SkillCatalogFile(path: path, contents: contents)
                }
            ),
            response.installs
        )
    }

    func audits(source: String, slug: String) async -> [CatalogAudit] {
        guard let url = URL(string: "\(baseURL)/api/v1/skills/audit/\(source)/\(slug)"),
              let (response, _) = try? await client.getJSON(
                AuditResponse.self, from: url, ttl: 60 * 60, headers: headers
              ) else { return [] }
        return (response.audits ?? []).compactMap { audit in
            guard let provider = audit.provider, let status = audit.status else { return nil }
            return CatalogAudit(
                provider: provider,
                status: status,
                riskLevel: audit.riskLevel,
                summary: audit.summary,
                auditedAt: CatalogDates.parse(audit.auditedAt)
            )
        }
    }

    // MARK: - Mapping

    /// The catalog's sections onto skills.sh's leaderboard views.
    static func viewParameter(_ view: CatalogView) -> String {
        switch view {
        case .featured, .popular: "all-time"
        case .trending: "trending"
        case .recentlyUpdated, .newest: "hot"
        }
    }

    static func item(from dto: SkillDTO) -> CatalogItem? {
        guard let id = dto.id, let source = dto.source, let slug = dto.slug else { return nil }
        let isGitHub = source.split(separator: "/").count == 2
        return CatalogItem(
            kind: .skill,
            provider: .skillsSh,
            name: id,
            displayName: dto.name ?? slug,
            summary: nil,
            publisher: source.split(separator: "/").first.map(String.init),
            repository: isGitHub ? source : nil,
            repositoryURL: isGitHub ? "https://github.com/\(source)" : dto.installUrl,
            installs: dto.installs,
            trendDelta: dto.change,
            skill: SkillCatalogDetails(source: source, slug: slug)
        )
    }
}
