import Foundation

/// Client for the official MCP Registry (registry.modelcontextprotocol.io).
///
/// Read-only and unauthenticated: listing uses `/v0/servers` with cursor
/// pagination and `version=latest` so each server appears once, not once per
/// published version.
struct McpRegistryProvider {
    var client: CatalogHTTPClient
    var baseURL = URL(string: "https://registry.modelcontextprotocol.io")!
    /// Lists change often; details of a pinned version do not.
    var listTTL: TimeInterval = 15 * 60
    /// Widely used servers, verified to exist in the registry, that lead the
    /// Featured section. A discovery seed, not a safety claim.
    var curated: [String] = [
        "io.github.github/github-mcp-server",
        "io.github.ChromeDevTools/chrome-devtools-mcp",
        "io.github.upstash/context7",
        "io.github.getsentry/sentry-mcp",
        "io.github.firecrawl/firecrawl-mcp-server",
        "com.notion/mcp",
        "com.stripe/mcp",
        "com.supabase/mcp",
        "app.linear/linear",
    ]

    // MARK: - Wire shapes

    struct ListResponse: Decodable {
        var servers: [Entry]
        var metadata: Metadata?

        struct Metadata: Decodable {
            var nextCursor: String?
        }
    }

    struct Entry: Decodable {
        var server: Server
        var official: OfficialMeta?

        private enum CodingKeys: String, CodingKey {
            case server
            case meta = "_meta"
        }

        private enum MetaKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            server = try container.decode(Server.self, forKey: .server)
            let meta = try? container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            official = try? meta?.decodeIfPresent(OfficialMeta.self, forKey: .official)
        }
    }

    struct OfficialMeta: Decodable {
        var status: String?
        var publishedAt: String?
        var updatedAt: String?
        var isLatest: Bool?
    }

    struct Server: Decodable {
        var name: String
        var title: String?
        var description: String?
        var version: String?
        var repository: Repository?
        var packages: [Package]?
        var remotes: [Remote]?

        struct Repository: Decodable {
            var url: String?
            var source: String?
            var subfolder: String?
        }

        struct Package: Decodable {
            var registryType: String?
            var identifier: String?
            var version: String?
            var runtimeHint: String?
            var transport: Transport?
            var runtimeArguments: [Argument]?
            var packageArguments: [Argument]?
            var environmentVariables: [EnvVar]?

            struct Transport: Decodable { var type: String? }

            struct Argument: Decodable {
                var value: String?
                var name: String?

                /// Named arguments render as "--name value"; positional ones
                /// as the value alone.
                var rendered: [String] {
                    switch (name, value) {
                    case (let name?, let value?): [name, value]
                    case (let name?, nil): [name]
                    case (nil, let value?): [value]
                    case (nil, nil): []
                    }
                }
            }

            struct EnvVar: Decodable {
                var name: String?
                var description: String?
                var isRequired: Bool?
                var isSecret: Bool?
                var `default`: String?
            }
        }

        struct Remote: Decodable {
            var type: String?
            var url: String?
        }
    }

    struct VersionsResponse: Decodable {
        var servers: [Entry]
    }

    // MARK: - Requests

    /// One page. The registry's own order is alphabetical by name, which puts
    /// noise first — so the page is over-fetched, quality-filtered and ranked
    /// locally before it reaches the grid.
    func page(_ query: CatalogQuery, limit: Int = 60) async throws -> CatalogPage {
        let search = query.search.trimmingCharacters(in: .whitespaces)

        var items: [CatalogItem] = []
        var seen = Set<String>()
        // The Featured section leads with the curated set; the ranked
        // registry list follows underneath.
        if query.view == .featured, query.cursor == nil, search.isEmpty {
            // Fetched concurrently — nine sequential round-trips would hold
            // the whole first page hostage.
            let fetched = await withTaskGroup(of: (Int, CatalogItem?).self) { group in
                for (index, name) in curated.enumerated() {
                    group.addTask { (index, try? await exactItem(named: name)) }
                }
                var results: [(Int, CatalogItem?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            for item in fetched {
                var curatedItem = item
                curatedItem.isCurated = true
                if seen.insert(curatedItem.id).inserted { items.append(curatedItem) }
            }
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("v0/servers"), resolvingAgainstBaseURL: false
        )!
        var parameters = [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !search.isEmpty { parameters.append(URLQueryItem(name: "search", value: search)) }
        if let cursor = query.cursor { parameters.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = parameters
        let (response, stale) = try await client.getJSON(
            ListResponse.self, from: components.url!, ttl: listTTL
        )
        let mapped = response.servers.compactMap(Self.item(from:))
        // A search shows everything it matched (ranked); browsing hides what
        // nobody can install or read.
        let filtered = search.isEmpty ? mapped.filter(Self.isPresentable) : mapped
        for item in Self.ranked(filtered) where seen.insert(item.id).inserted {
            items.append(item)
        }
        return CatalogPage(
            items: items,
            nextCursor: response.metadata?.nextCursor,
            isFromCache: stale
        )
    }

    /// One server fetched by its exact name, via the search endpoint.
    private func exactItem(named name: String) async throws -> CatalogItem? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v0/servers"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "search", value: name),
        ]
        let (response, _) = try await client.getJSON(
            ListResponse.self, from: components.url!, ttl: listTTL
        )
        return response.servers
            .compactMap(Self.item(from:))
            .first { $0.name == name }
    }

    /// Whether a browsing list should show the entry at all: something a
    /// person can read and Uncoil can install, and the registry still stands
    /// behind. Deprecated/deleted entries stay reachable through search.
    static func isPresentable(_ item: CatalogItem) -> Bool {
        guard !item.isDeprecated else { return false }
        guard item.mcp?.hasInstallableForm == true else { return false }
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard summary.count >= 12 else { return false }
        // Same language gate as the skill catalog: this UI cannot present a
        // predominantly CJK entry usefully. Search still finds everything.
        guard GitHubSkillProvider.cjkRatio(of: item.displayName) < 0.2,
              GitHubSkillProvider.cjkCount(of: item.displayName) < 3,
              GitHubSkillProvider.cjkRatio(of: summary) < 0.25 else { return false }
        return true
    }

    /// Local ordering for a registry that has no popularity data: entries
    /// with a repository, a real description and recent activity first. The
    /// inputs are all on the card, so the order is explainable.
    static func ranked(_ items: [CatalogItem]) -> [CatalogItem] {
        func score(_ item: CatalogItem) -> Double {
            var score = 0.0
            if item.repository != nil { score += 3 }
            if item.mcp?.remotes.isEmpty == false { score += 1 }
            score += Double(min(item.summary?.count ?? 0, 120)) / 40
            if let updated = item.updatedAt {
                let days = max(1, Date.now.timeIntervalSince(updated) / 86_400)
                score += max(0, 3 - log10(days) * 2)
            }
            return score
        }
        return items.sorted { score($0) > score($1) }
    }

    /// Release history of one server, newest first.
    func versions(of name: String) async throws -> [CatalogVersionEntry] {
        // The "/" inside a server name must travel encoded; the rest of the
        // name is ordinary path material.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(baseURL)/v0/servers/\(encoded)/versions") else {
            return []
        }
        let (response, _) = try await client.getJSON(VersionsResponse.self, from: url, ttl: 60 * 60)
        return response.servers
            .compactMap { entry -> CatalogVersionEntry? in
                guard let version = entry.server.version else { return nil }
                return CatalogVersionEntry(
                    version: version,
                    publishedAt: CatalogDates.parse(entry.official?.publishedAt),
                    isLatest: entry.official?.isLatest ?? false,
                    status: entry.official?.status
                )
            }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    // MARK: - Mapping

    /// Pure, so the tests can feed it decoded fixtures.
    static func item(from entry: Entry) -> CatalogItem? {
        let server = entry.server
        let repository = server.repository?.url.flatMap(ownerRepo(fromURL:))
        return CatalogItem(
            kind: .mcpServer,
            provider: .mcpRegistry,
            name: server.name,
            displayName: server.title ?? server.name
                .split(separator: "/").last.map(String.init) ?? server.name,
            summary: server.description,
            publisher: server.name.split(separator: "/").first.map(String.init),
            repository: repository,
            repositoryURL: server.repository?.url,
            version: server.version,
            publishedAt: CatalogDates.parse(entry.official?.publishedAt),
            updatedAt: CatalogDates.parse(entry.official?.updatedAt),
            isOfficial: entry.official != nil,
            registryStatus: entry.official?.status,
            mcp: MCPCatalogDetails(
                packages: (server.packages ?? []).compactMap { package in
                    guard let identifier = package.identifier,
                          let registryType = package.registryType else { return nil }
                    return MCPCatalogPackage(
                        registryType: registryType,
                        identifier: identifier,
                        version: package.version,
                        runtimeHint: package.runtimeHint,
                        transportType: package.transport?.type,
                        runtimeArguments: (package.runtimeArguments ?? []).flatMap(\.rendered),
                        packageArguments: (package.packageArguments ?? []).flatMap(\.rendered),
                        environmentVariables: (package.environmentVariables ?? []).compactMap { env in
                            guard let name = env.name else { return nil }
                            return CatalogEnvVar(
                                name: name,
                                summary: env.description,
                                isRequired: env.isRequired ?? false,
                                isSecret: env.isSecret ?? false,
                                defaultValue: env.default
                            )
                        }
                    )
                },
                remotes: (server.remotes ?? []).compactMap { remote in
                    guard let type = remote.type, let url = remote.url else { return nil }
                    return MCPCatalogRemote(type: type, url: url)
                }
            )
        )
    }

    /// "owner/repo" out of a GitHub URL, or nil for anything else.
    static func ownerRepo(fromURL url: String) -> String? {
        guard let components = URL(string: url), components.host == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
    }
}
