import Foundation

/// Where the GitHub skill catalog looks. A seed is one way of finding skill
/// repositories; the provider fans out over several and deduplicates, so no
/// single query is the catalog. Seeds can be added, disabled or replaced
/// without touching the UI or the install path.
enum SkillSeedSource: Equatable {
    /// Repositories carrying a GitHub topic ("agent-skills", …).
    case topic(String)
    /// A raw repository-search query ("\"SKILL.md\" in:readme").
    case searchQuery(String)
    /// A specific public repository known to hold skills (or an index of
    /// them). A discovery seed — never a safety claim.
    case curatedRepo(String)

    /// The built-in seed list. Deliberately small; the abstraction is the
    /// point, not the list.
    static let defaults: [SkillSeedSource] = [
        .topic("agent-skills"),
        .topic("claude-skills"),
        .searchQuery("\"SKILL.md\" in:readme"),
        .curatedRepo("anthropics/skills"),
        .curatedRepo("obra/superpowers"),
        .curatedRepo("vercel-labs/agent-skills"),
    ]

    var topicName: String? {
        if case .topic(let name) = self { return name }
        return nil
    }

    var curatedSlug: String? {
        if case .curatedRepo(let slug) = self { return slug }
        return nil
    }
}

/// Skill discovery over the GitHub REST API, using the token the app's
/// existing Device Authorization flow already stores — no extra key, no
/// second sign-in. Unauthenticated reads work too, inside GitHub's smaller
/// anonymous search limit.
///
/// A repository is never assumed to be one skill: the detail pass walks the
/// git tree at a pinned commit and exposes every directory holding a
/// `SKILL.md` as its own installable skill.
struct GitHubSkillProvider {
    var client: CatalogHTTPClient
    var apiBase = URL(string: "https://api.github.com")!
    /// Read per request, so signing in (or out) takes effect immediately.
    var token: () -> String? = { KeychainStore.read(key: "github-token") }
    var seeds: [SkillSeedSource] = SkillSeedSource.defaults
    /// Injected so the date windows in queries are testable.
    var now: () -> Date = { .now }
    var listTTL: TimeInterval = 15 * 60

    /// Caps on what a detail fetch will pull. A skill is text and a few
    /// assets; anything past these limits is reported, not downloaded.
    static let maxFileBytes = 400_000
    static let maxFiles = 100
    static let maxTotalBytes = 5_000_000

    private var headers: [String: String] {
        var headers = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if let token = token() { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    // MARK: - Wire shapes

    struct SearchResponse: Decodable {
        var total_count: Int?
        var items: [RepoDTO]
    }

    struct RepoDTO: Decodable {
        var full_name: String?
        var name: String?
        var owner: OwnerDTO?
        var description: String?
        var stargazers_count: Int?
        var forks_count: Int?
        var license: LicenseDTO?
        var topics: [String]?
        var archived: Bool?
        var fork: Bool?
        var created_at: String?
        var pushed_at: String?
        var default_branch: String?

        struct OwnerDTO: Decodable { var login: String? }
        struct LicenseDTO: Decodable { var spdx_id: String? }
    }

    struct CommitDTO: Decodable {
        var sha: String?
    }

    struct TreeResponse: Decodable {
        var tree: [Entry]
        var truncated: Bool?

        struct Entry: Decodable {
            var path: String?
            var type: String?
            var sha: String?
            var size: Int?
        }
    }

    struct BlobDTO: Decodable {
        var content: String?
        var encoding: String?
    }

    // MARK: - Listing

    func page(_ query: CatalogQuery, perPage: Int = 20) async throws -> CatalogPage {
        let page = query.cursor.flatMap(Int.init) ?? 0
        let search = query.search.trimmingCharacters(in: .whitespaces)
        let queries = searchQueries(view: query.view, search: search)

        var items: [CatalogItem] = []
        var seen = Set<String>()
        var anyFull = false
        var anyStale = false

        // Curated repositories lead the Featured section's first page. They
        // are fetched directly — a curated repo does not need to win a search.
        if page == 0, search.isEmpty, query.view == .featured {
            for slug in seeds.compactMap(\.curatedSlug) {
                guard let item = try? await curatedItem(slug: slug) else { continue }
                if seen.insert(item.id).inserted { items.append(item) }
            }
        }

        for q in queries {
            let (response, stale) = try await client.getJSON(
                SearchResponse.self,
                from: searchURL(q: q.query, sort: q.sort, page: page, perPage: perPage),
                ttl: listTTL,
                headers: headers
            )
            anyStale = anyStale || stale
            if response.items.count == perPage { anyFull = true }
            for dto in response.items {
                guard var item = Self.item(from: dto) else { continue }
                item.isCurated = seeds.compactMap(\.curatedSlug).contains(item.name)
                guard item.isCurated || Self.passesQualityGate(item, isSearch: !search.isEmpty)
                else { continue }
                if seen.insert(item.id).inserted { items.append(item) }
            }
        }

        return CatalogPage(
            items: rank(items, view: query.view, isSearch: !search.isEmpty),
            nextCursor: anyFull ? String(page + 1) : nil,
            isFromCache: anyStale
        )
    }

    struct SearchQuery: Equatable {
        var query: String
        var sort: String?
    }

    /// The GitHub search queries one page load runs. GitHub's repo search has
    /// no OR across qualifiers, so each seed is its own query and the results
    /// are merged. Kept to at most three requests per load.
    func searchQueries(view: CatalogView, search: String) -> [SearchQuery] {
        let base = "fork:false archived:false"
        if !search.isEmpty {
            // Search fans over two signals: the term near a SKILL.md mention,
            // and the term inside the primary topic.
            return [
                SearchQuery(query: "\(search) \"SKILL.md\" in:name,description,readme \(base)", sort: nil),
                SearchQuery(query: "\(search) topic:agent-skills \(base)", sort: nil),
            ]
        }
        let topics = seeds.compactMap(\.topicName).prefix(2)
        let extra = seeds.compactMap { seed -> String? in
            if case .searchQuery(let q) = seed { return q }
            return nil
        }.prefix(1)
        let window: String
        let sort: String
        switch view {
        case .featured, .popular:
            window = ""
            sort = "stars"
        case .trending:
            window = "pushed:>=\(Self.dateParameter(daysAgo: 30, now: now()))"
            sort = "stars"
        case .recentlyUpdated:
            window = ""
            sort = "updated"
        case .newest:
            window = "created:>=\(Self.dateParameter(daysAgo: 180, now: now()))"
            sort = "updated"
        }
        var queries = topics.map { topic in
            SearchQuery(
                query: ["topic:\(topic)", base, window].filter { !$0.isEmpty }.joined(separator: " "),
                sort: sort
            )
        }
        queries += extra.map { q in
            SearchQuery(
                query: [q, base, window].filter { !$0.isEmpty }.joined(separator: " "),
                sort: sort
            )
        }
        return queries
    }

    static func dateParameter(daysAgo: Int, now: Date) -> String {
        let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func searchURL(q: String, sort: String?, page: Int, perPage: Int) -> URL {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("search/repositories"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page + 1)),
        ]
        if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
        components.queryItems = items
        return components.url!
    }

    private func curatedItem(slug: String) async throws -> CatalogItem? {
        let (dto, _) = try await client.getJSON(
            RepoDTO.self,
            from: apiBase.appendingPathComponent("repos/\(slug)"),
            ttl: listTTL,
            headers: headers
        )
        guard var item = Self.item(from: dto) else { return nil }
        item.isCurated = true
        return item
    }

    /// The transparent local ordering. GitHub has no install ranking, so what
    /// is shown is derivable from what is on the card: stars, weighted toward
    /// recent activity for the sections that promise it. Deliberately simple
    /// and replaceable by a better provider later.
    func rank(_ items: [CatalogItem], view: CatalogView, isSearch: Bool) -> [CatalogItem] {
        guard !isSearch else { return items.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) } }
        switch view {
        case .featured:
            // Curated first (in seed order — already prepended), the rest by stars.
            let curated = items.filter(\.isCurated)
            let rest = items.filter { !$0.isCurated }.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) }
            return curated + rest
        case .popular:
            return items.sorted { ($0.stars ?? 0) > ($1.stars ?? 0) }
        case .trending:
            // Stars discounted by how long ago the last push was: a busy
            // medium repo outranks a dormant giant.
            let reference = now()
            func score(_ item: CatalogItem) -> Double {
                let stars = Double(item.stars ?? 0)
                let days = max(1, reference.timeIntervalSince(item.updatedAt ?? .distantPast) / 86_400)
                return stars / days
            }
            return items.sorted { score($0) > score($1) }
        case .recentlyUpdated:
            return items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .newest:
            return items.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        }
    }

    // MARK: - Quality

    /// Topic search casts a wide net, and a topic is self-assigned — plenty
    /// of repositories carry `agent-skills` without being one. The gate keeps
    /// the browse views to repositories that look like something an
    /// English-reading user of this app could actually install and read:
    ///
    /// - a description exists (an empty repo card says nothing about safety)
    /// - the name or text mentions skills, or a skill topic is set
    /// - not an "awesome-…" index (a list of things is not an installable thing)
    /// - a few stars, so brand-new empty repos don't flood the grid
    /// - not predominantly CJK text, which this UI cannot present usefully
    ///
    /// Search is gated more loosely (no star floor): whoever typed a name
    /// gets to find it. Curated entries bypass the gate entirely — and none
    /// of this is a safety judgment; the scanner still runs on install.
    static func passesQualityGate(_ item: CatalogItem, isSearch: Bool) -> Bool {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return false }
        let haystack = "\(item.displayName) \(summary) \(item.topics.joined(separator: " "))"
            .lowercased()
        guard haystack.contains("skill") else { return false }
        guard !item.displayName.lowercased().hasPrefix("awesome-") else { return false }
        guard cjkRatio(of: "\(item.displayName) \(summary)") < 0.25 else { return false }
        if !isSearch, (item.stars ?? 0) < 3 { return false }
        return true
    }

    /// Share of CJK characters among the letters of a string.
    static func cjkRatio(of text: String) -> Double {
        let counts = cjkCounts(of: text)
        guard counts.letters > 0 else { return 0 }
        return Double(counts.cjk) / Double(counts.letters)
    }

    /// Absolute number of CJK letters — a name carrying a CJK word keeps a
    /// low *ratio* when the rest is long English, so the count is checked too.
    static func cjkCount(of text: String) -> Int {
        cjkCounts(of: text).cjk
    }

    private static func cjkCounts(of text: String) -> (letters: Int, cjk: Int) {
        var letters = 0
        var cjk = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x2E80...0x9FFF,      // CJK radicals, ideographs
                 0x3040...0x30FF,      // kana (inside the range above; harmless)
                 0xAC00...0xD7AF,      // hangul syllables
                 0xF900...0xFAFF,      // CJK compatibility ideographs
                 0x20000...0x2FA1F:    // ideograph extensions
                cjk += 1
            default:
                break
            }
        }
        return (letters, cjk)
    }

    // MARK: - Mapping

    static func item(from dto: RepoDTO) -> CatalogItem? {
        guard let fullName = dto.full_name, let repoName = dto.name else { return nil }
        // Archived repositories and forks are not offered for install; the
        // queries exclude them, and a curated fetch re-checks here.
        guard dto.archived != true, dto.fork != true else { return nil }
        return CatalogItem(
            kind: .skill,
            provider: .gitHub,
            name: fullName,
            displayName: repoName,
            summary: dto.description,
            publisher: dto.owner?.login ?? fullName.split(separator: "/").first.map(String.init),
            repository: fullName,
            repositoryURL: "https://github.com/\(fullName)",
            publishedAt: CatalogDates.parse(dto.created_at),
            updatedAt: CatalogDates.parse(dto.pushed_at),
            stars: dto.stargazers_count,
            license: dto.license?.spdx_id.flatMap { $0 == "NOASSERTION" ? nil : $0 },
            topics: dto.topics ?? [],
            skill: SkillCatalogDetails(
                source: fullName,
                slug: repoName.lowercased(),
                defaultBranch: dto.default_branch
            )
        )
    }

    // MARK: - Detail

    /// Resolves the repository to a pinned commit, finds every skill in its
    /// tree, and loads the files of one of them (the first, unless a location
    /// is named). Everything downstream — staging, scanning, install — works
    /// on exactly this commit.
    func detail(
        for item: CatalogItem,
        location: SkillCatalogDetails.SkillLocation? = nil
    ) async throws -> CatalogItem {
        guard let slug = item.repository else {
            throw CatalogError.malformed("The entry names no repository.")
        }
        let (repo, _) = try await client.getJSON(
            RepoDTO.self,
            from: apiBase.appendingPathComponent("repos/\(slug)"),
            ttl: 5 * 60,
            headers: headers
        )
        guard repo.archived != true else {
            throw CatalogError.malformed(String(localized: "The repository is archived; it is listed read-only."))
        }
        let branch = repo.default_branch ?? "main"
        let (commit, _) = try await client.getJSON(
            CommitDTO.self,
            from: apiBase.appendingPathComponent("repos/\(slug)/commits/\(branch)"),
            ttl: 5 * 60,
            headers: headers
        )
        guard let sha = commit.sha else {
            throw CatalogError.malformed("The head commit could not be resolved.")
        }
        // The tree of a specific commit never changes; cache it long.
        let (tree, _) = try await client.getJSON(
            TreeResponse.self,
            from: URL(string: "\(apiBase)/repos/\(slug)/git/trees/\(sha)?recursive=1")!,
            ttl: 7 * 86_400,
            headers: headers
        )

        let locations = Self.skillLocations(in: tree, repoName: repo.name ?? slug)
        guard !locations.isEmpty else {
            throw CatalogError.malformed(String(
                localized: "No SKILL.md was found in this repository — there is nothing to install."
            ))
        }
        let chosen = location.flatMap { picked in locations.first { $0.id == picked.id } }
            ?? locations[0]
        let files = try await files(in: tree, under: chosen.directory, repo: slug)

        var full = item
        var details = SkillCatalogDetails(
            source: slug,
            slug: chosen.slug,
            commitSHA: sha,
            directory: chosen.directory,
            defaultBranch: branch,
            availableSkills: locations,
            files: files
        )
        // The front matter is the skill's own word on what it is; it refines
        // the card's repo-level description on the detail page.
        if let manifest = files.first(where: { $0.path == "SKILL.md" }) {
            let claims = Self.frontMatter(of: manifest.contents)
            if let name = claims["name"], !name.isEmpty { full.displayName = name }
            if let description = claims["description"], !description.isEmpty {
                full.summary = description
            }
        }
        details.contentHash = nil
        full.skill = details
        full.stars = repo.stargazers_count ?? item.stars
        full.license = repo.license?.spdx_id ?? item.license
        return full
    }

    /// Every directory in the tree that holds a `SKILL.md` — the repository
    /// root included. Hidden and dependency directories are not skills.
    static func skillLocations(
        in tree: TreeResponse,
        repoName: String
    ) -> [SkillCatalogDetails.SkillLocation] {
        var locations: [SkillCatalogDetails.SkillLocation] = []
        for entry in tree.tree where entry.type == "blob" {
            guard let path = entry.path else { continue }
            if path == "SKILL.md" {
                locations.append(.init(directory: "", slug: repoName.lowercased()))
                continue
            }
            guard path.hasSuffix("/SKILL.md") else { continue }
            let directory = String(path.dropLast("/SKILL.md".count))
            let parts = directory.split(separator: "/").map(String.init)
            guard !parts.contains(where: { $0.hasPrefix(".") }),
                  !parts.contains("node_modules") else { continue }
            guard let slug = parts.last else { continue }
            locations.append(.init(directory: directory, slug: slug.lowercased()))
        }
        return locations.sorted { $0.directory < $1.directory }
    }

    /// Loads the blobs of one skill directory, inside the size caps. Files
    /// over the caps are skipped — visible in the file list as absent, and
    /// the staging step re-checks structure anyway.
    private func files(
        in tree: TreeResponse,
        under directory: String,
        repo slug: String
    ) async throws -> [SkillCatalogFile] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var entries = tree.tree.filter { entry in
            guard entry.type == "blob", let path = entry.path else { return false }
            guard path.hasPrefix(prefix) else { return false }
            return (entry.size ?? 0) <= Self.maxFileBytes
        }
        // SKILL.md first, then whatever fits the caps.
        entries.sort { ($0.path == prefix + "SKILL.md" ? 0 : 1, $0.path ?? "")
            < ($1.path == prefix + "SKILL.md" ? 0 : 1, $1.path ?? "") }

        var files: [SkillCatalogFile] = []
        var total = 0
        for entry in entries.prefix(Self.maxFiles) {
            guard let path = entry.path, let blobSHA = entry.sha else { continue }
            guard total + (entry.size ?? 0) <= Self.maxTotalBytes else { break }
            let (blob, _) = try await client.getJSON(
                BlobDTO.self,
                from: apiBase.appendingPathComponent("repos/\(slug)/git/blobs/\(blobSHA)"),
                ttl: 7 * 86_400,
                headers: headers
            )
            guard let data = Self.decode(blob) else { continue }
            total += data.count
            let relative = String(path.dropFirst(prefix.count))
            if let text = String(data: data, encoding: .utf8) {
                files.append(SkillCatalogFile(path: relative, contents: text))
            } else {
                files.append(SkillCatalogFile(path: relative, contents: "", binaryContents: data))
            }
        }
        return files
    }

    static func decode(_ blob: BlobDTO) -> Data? {
        guard let content = blob.content else { return nil }
        if blob.encoding == "base64" {
            return Data(base64Encoded: content, options: .ignoreUnknownCharacters)
        }
        return Data(content.utf8)
    }

    /// Scalar front-matter values of a SKILL.md ("name:", "description:").
    static func frontMatter(of text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if values[key] == nil, !value.isEmpty { values[key] = value }
        }
        return values
    }
}
