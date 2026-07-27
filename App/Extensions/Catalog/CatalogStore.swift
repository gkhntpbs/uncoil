import Foundation

/// State of one catalog page (MCP or skills): the items loaded so far, the
/// cursor for the next page, and what the last fetch did. One instance per
/// catalog section, owned by the Extensions window so switching sections keeps
/// the loaded state.
///
/// Fetching never blocks the UI: every load runs in a task, and a new query
/// cancels the one in flight.
@MainActor
final class CatalogStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loadingMore
        case loaded
        case failed(String)
    }

    let kind: ExtensionKind

    @Published var searchText = ""
    @Published var view: CatalogView = .popular {
        didSet { if view != oldValue { refresh() } }
    }
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var phase: Phase = .idle
    /// True when the list on screen came from the disk cache because the
    /// network failed — shown as a banner, never silently.
    @Published private(set) var isShowingStaleCache = false
    @Published private(set) var nextCursor: String?
    @Published private(set) var lastLoadedAt: Date?

    private let mcpProvider: McpRegistryProvider
    private let gitHubSkills: GitHubSkillProvider
    let enrichment: GitHubEnrichment
    private var loadTask: Task<Void, Never>?
    private var searchDebounce: Task<Void, Never>?
    /// Detail results are cached per item id so reopening a card is instant.
    /// A skill's detail carries the whole package's file contents (up to a few
    /// MB each), so the cache is bounded: oldest entry out past the cap.
    private var detailCache: [String: CatalogItem] = [:]
    private var detailCacheOrder: [String] = []
    private let detailCacheLimit = 8
    private var repoFactsCache: [String: CatalogRepoFacts] = [:]
    private var versionsCache: [String: [CatalogVersionEntry]] = [:]

    init(kind: ExtensionKind, client: CatalogHTTPClient? = nil) {
        self.kind = kind
        let client = client ?? CatalogHTTPClient(cache: .default())
        mcpProvider = McpRegistryProvider(client: client)
        gitHubSkills = GitHubSkillProvider(client: client)
        enrichment = GitHubEnrichment(client: client)
        view = .featured
    }

    /// The GitHub session the app's Device Authorization flow stores. When it
    /// is present the skill catalog gets authenticated limits automatically;
    /// without it, anonymous limits apply and the UI offers the existing
    /// sign-in flow.
    var isGitHubConnected: Bool {
        KeychainStore.read(key: "github-token") != nil
    }

    /// Supported sections. The MCP registry has no popularity or date search,
    /// so it offers the curated Featured lead-in and the ranked full list.
    var availableViews: [CatalogView] {
        kind == .skill ? CatalogView.allCases : [.featured, .popular]
    }

    // MARK: - Loading

    /// Reload from the first page. Cancels whatever was in flight.
    func refresh() {
        load(reset: true)
    }

    func loadMoreIfNeeded() {
        guard nextCursor != nil, phase == .loaded else { return }
        load(reset: false)
    }

    /// Debounced entry point for the search field.
    func searchChanged() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func load(reset: Bool) {
        loadTask?.cancel()
        let query = CatalogQuery(
            search: searchText,
            view: view,
            cursor: reset ? nil : nextCursor
        )
        phase = reset ? .loading : .loadingMore
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetch(query)
                guard !Task.isCancelled else { return }
                if reset {
                    self.items = page.items
                } else {
                    // Dedup across pages: a moving leaderboard can repeat an
                    // entry at a page boundary.
                    let known = Set(self.items.map(\.id))
                    self.items += page.items.filter { !known.contains($0.id) }
                }
                self.nextCursor = page.nextCursor
                self.isShowingStaleCache = page.isFromCache
                self.phase = .loaded
                self.lastLoadedAt = .now
            } catch is CancellationError {
                // A newer query took over; nothing to show.
            } catch {
                guard !Task.isCancelled else { return }
                if reset { self.items = [] }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func fetch(_ query: CatalogQuery) async throws -> CatalogPage {
        switch kind {
        case .mcpServer: try await mcpProvider.page(query)
        case .skill: try await gitHubSkills.page(query)
        }
    }

    // MARK: - Detail

    /// The full record for one entry: for a skill the repository is resolved
    /// to a pinned commit, its tree is walked for every SKILL.md, and the
    /// chosen skill's files are loaded. For MCP the list item is already
    /// complete. `location` picks one skill out of a multi-skill repository.
    func detail(
        for item: CatalogItem,
        location: SkillCatalogDetails.SkillLocation? = nil
    ) async throws -> CatalogItem {
        let key = "\(item.id)#\(location?.id ?? "-")"
        if let cached = detailCache[key] { return cached }
        var full = item
        if kind == .skill {
            full = try await gitHubSkills.detail(for: item, location: location)
        }
        detailCache[key] = full
        detailCacheOrder.append(key)
        if detailCacheOrder.count > detailCacheLimit {
            detailCache.removeValue(forKey: detailCacheOrder.removeFirst())
        }
        return full
    }

    /// GitHub enrichment, best-effort: nil just means no facts to show.
    func repoFacts(for item: CatalogItem) async -> CatalogRepoFacts? {
        guard let repository = item.repository else { return nil }
        if let cached = repoFactsCache[repository] { return cached }
        guard let facts = await enrichment.facts(for: repository) else { return nil }
        repoFactsCache[repository] = facts
        return facts
    }

    /// MCP release history, best-effort.
    func versions(for item: CatalogItem) async -> [CatalogVersionEntry] {
        guard kind == .mcpServer else { return [] }
        if let cached = versionsCache[item.name] { return cached }
        let versions = (try? await mcpProvider.versions(of: item.name)) ?? []
        versionsCache[item.name] = versions
        return versions
    }

    /// Drops per-item caches so a re-opened detail shows current data.
    func invalidateDetails() {
        detailCache = [:]
        detailCacheOrder = []
        repoFactsCache = [:]
        versionsCache = [:]
    }

    // MARK: - Installed state

    /// How a catalog entry relates to what the registry already tracks.
    /// Matching is by install name: that is the name an installed copy carries
    /// whichever path put it there.
    static func installedState(
        of item: CatalogItem,
        packages: [ExtensionPackage]
    ) -> CatalogInstalledState {
        if item.kind == .mcpServer, item.mcp?.hasInstallableForm != true {
            return .incompatible(String(localized: "No installable package or endpoint"))
        }
        let name = item.skill?.slug ?? item.installName
        guard let installed = packages.first(where: { $0.kind == item.kind && $0.name == name })
        else { return .notInstalled }
        // A catalog-pinned skill is compared against the pin — the commit the
        // provider resolved, or a content hash; anything else that matches by
        // name counts as installed.
        if item.kind == .skill,
           let pin = item.skill?.pinRef,
           let revision = installed.activeRevision,
           revision.id.hasPrefix("catalog/"),
           !revision.id.hasSuffix(shortHash(pin)) {
            return .updateAvailable
        }
        return .installed
    }

    /// The 12 characters of a content hash a revision id carries.
    static func shortHash(_ hash: String) -> String {
        String(hash.prefix(12))
    }
}
