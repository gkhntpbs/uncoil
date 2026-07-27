import SwiftUI

/// One catalog page inside the Extensions window: a searchable, paginated grid
/// over a remote source (the official MCP Registry, or GitHub for skills), in the
/// window's own visual language. Fetching never blocks the UI; failures show a
/// retry, and a stale cache is shown as stale rather than hidden.
struct CatalogScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @ObservedObject var catalog: CatalogStore
    let scans: BumblebeeScanCoordinator
    @Binding var message: String?

    @State private var selectedItem: CatalogItem?
    /// Mirrors the Keychain state so the grid refreshes the moment the
    /// existing GitHub device-flow sign-in completes. Starts optimistic and is
    /// verified in `.task` — a Keychain query is a `securityd` round-trip, too
    /// slow for a `@State` initializer that runs on every parent render.
    @State private var gitHubConnected = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controls
            if catalog.kind == .skill, !gitHubConnected {
                gitHubConnectCard
            }
            if catalog.isShowingStaleCache {
                staleBanner
            }
            content
        }
        .onChange(of: gitHubConnected) {
            if gitHubConnected { catalog.refresh() }
        }
        .task {
            gitHubConnected = KeychainStore.read(key: "github-token") != nil
            if catalog.items.isEmpty, catalog.phase == .idle {
                catalog.refresh()
            }
        }
        .sheet(item: $selectedItem) { item in
            CatalogDetailSheet(
                item: item,
                registry: registry,
                catalog: catalog,
                scans: scans,
                message: $message
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TablerIcon(name: "search", size: 11, color: Theme.textFaint)
                TextField(
                    catalog.kind == .skill ? "Search skills" : "Search MCP servers",
                    text: $catalog.searchText
                )
                .textFieldStyle(.plain)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.text)
                .onChange(of: catalog.searchText) { catalog.searchChanged() }
                .accessibilityIdentifier("extensions.catalog.search")
                if !catalog.searchText.isEmpty {
                    Button {
                        catalog.searchText = ""
                        catalog.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.border, lineWidth: 1))
            .frame(maxWidth: 320)

            if catalog.availableViews.count > 1 {
                Picker("", selection: $catalog.view) {
                    ForEach(catalog.availableViews) { view in
                        Text(view.label).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityIdentifier("extensions.catalog.view")
            }

            Spacer()

            Button {
                catalog.refresh()
            } label: {
                HStack(spacing: 5) {
                    TablerIcon(name: "refresh", size: 11, color: Theme.textDim)
                    Text("Refresh")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("extensions.catalog.refresh")
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            TablerIcon(name: "wifi-off", size: 12, color: Theme.warn)
            Text("The registry could not be reached; showing the last cached results.")
                .font(Theme.ui(.small))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Retry") { catalog.refresh() }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.warnSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .accessibilityIdentifier("extensions.catalog.staleBanner")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch catalog.phase {
        case .idle, .loading:
            grid(items: [], showSkeletons: true)
        case .failed(let reason) where catalog.items.isEmpty:
            errorCard(reason)
        case .loaded where catalog.items.isEmpty:
            VStack(alignment: .leading, spacing: 0) {
                Text(catalog.searchText.isEmpty
                    ? "The catalog returned nothing."
                    : "Nothing matches “\(catalog.searchText)”.")
                    .font(Theme.ui(.body))
                    .foregroundStyle(Theme.textFaint)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        default:
            grid(items: catalog.items, showSkeletons: false)
        }
    }

    /// The catalog browses public repositories anonymously, but GitHub's
    /// anonymous search limit is small; the app's existing device-flow
    /// sign-in raises it. The same login view Settings uses is embedded here
    /// — no new secret screen, no manual token.
    private var gitHubConnectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                TablerIcon(name: "brand-github", size: 13, color: Theme.textDim)
                Text("Connect GitHub for full browsing")
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            Text("Skills are discovered on GitHub. Without a connection the catalog still works inside GitHub's small anonymous limit; signing in with the browser removes that ceiling. The token stays in your Keychain.")
                .font(Theme.ui(.small))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            GitHubLoginView(loggedIn: $gitHubConnected)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityIdentifier("extensions.catalog.githubConnect")
    }

    private func errorCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TablerIcon(name: "cloud-off", size: 13, color: Theme.danger)
                Text("The catalog could not be loaded")
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(reason)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
            Button("Try again") { catalog.refresh() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("extensions.catalog.retry")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func grid(items: [CatalogItem], showSkeletons: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250, maximum: 400), spacing: 12)],
                spacing: 12
            ) {
                if showSkeletons {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonBlock()
                            .frame(height: CatalogCard.height)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
                    }
                } else {
                    ForEach(items) { item in
                        CatalogCard(
                            item: item,
                            state: CatalogStore.installedState(of: item, packages: registry.packages)
                        ) {
                            selectedItem = item
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extensions.catalog.grid")

            if catalog.nextCursor != nil, !showSkeletons {
                HStack {
                    Spacer()
                    Button {
                        catalog.loadMoreIfNeeded()
                    } label: {
                        HStack(spacing: 6) {
                            if catalog.phase == .loadingMore {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(catalog.phase == .loadingMore ? "Loading…" : "Load more")
                                .font(Theme.mono(.body, .medium))
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(catalog.phase == .loadingMore)
                    .accessibilityIdentifier("extensions.catalog.loadMore")
                    // Scrolling to the end keeps loading without the click.
                    .onAppear { catalog.loadMoreIfNeeded() }
                    Spacer()
                }
            }

            if case .failed(let reason) = catalog.phase, !catalog.items.isEmpty {
                Text("More could not be loaded: \(reason)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.warn)
            }
        }
    }
}

// MARK: - Card

/// One catalog entry in the grid: what it is, who publishes it, how alive it
/// is, and how it relates to what is already installed.
struct CatalogCard: View {
    let item: CatalogItem
    let state: CatalogInstalledState
    let open: () -> Void

    static let height: CGFloat = 128

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 7) {
                    TablerIcon(
                        name: item.kind == .skill ? "sparkles" : "server",
                        size: 13,
                        color: Theme.textDim
                    )
                    Text(item.displayName)
                        .font(Theme.mono(.body, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                }
                if let publisher = item.publisher {
                    Text(publisher)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                Text(item.summary ?? item.name)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2, reservesSpace: true)
                Spacer(minLength: 0)
                footer
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.height)
            .panel()
            // A grid of cards that are entirely clickable and answer the pointer
            // with nothing reads as a picture of a catalogue. The card picks up
            // the accent edge and lifts a little; the shadow is what makes the
            // lift legible on a dark background, where a 2pt rise alone is not.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(hovering ? Theme.highlightBorder : .clear, lineWidth: 1)
            )
            .elevated(hovering ? .low : nil)
            .offset(y: hovering ? -2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.quick, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("extensions.catalog.card.\(item.id)")
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if item.isDeprecated {
                CatalogBadge(text: String(localized: "Deprecated"), tint: Theme.warn)
            } else if item.isOfficial {
                CatalogBadge(text: String(localized: "Official"), tint: Theme.info)
            } else if item.isCurated {
                CatalogBadge(text: String(localized: "Curated"), tint: Theme.info)
            }
            if let audit = item.audits.first {
                CatalogBadge(
                    text: audit.isFailing ? String(localized: "Audit failed") : String(localized: "Reviewed"),
                    tint: audit.isFailing ? Theme.danger : Theme.ok
                )
            }
            switch state {
            case .installed:
                CatalogBadge(text: String(localized: "Installed"), tint: Theme.ok)
            case .updateAvailable:
                CatalogBadge(text: String(localized: "Update"), tint: Theme.highlight)
            case .incompatible:
                CatalogBadge(text: String(localized: "Incompatible"), tint: Theme.textFaint)
            case .notInstalled:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let version = item.version {
                Text("v\(version)")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textDim)
            }
            // Installs and stars are different facts and carry different
            // icons; a star count is never dressed up as an install count.
            if let installs = item.installs {
                HStack(spacing: 3) {
                    TablerIcon(name: "download", size: 9, color: Theme.textFaint)
                    Text(Self.compact(installs))
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                }
                .help(Text("Installs"))
            }
            if let stars = item.stars {
                HStack(spacing: 3) {
                    TablerIcon(name: "star", size: 9, color: Theme.textFaint)
                    Text(Self.compact(stars))
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                }
                .help(Text("GitHub stars"))
            }
            if let delta = item.trendDelta, delta != 0 {
                Text(delta > 0 ? "+\(delta)" : "\(delta)")
                    .font(Theme.mono(.micro, .semibold))
                    .foregroundStyle(delta > 0 ? Theme.ok : Theme.danger)
            }
            Spacer()
            if let updated = item.updatedAt {
                Text(RelativeClock.short(since: updated))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// 24 531 → "24.5k": the card has room for a size, not a number.
    static func compact(_ count: Int) -> String {
        switch count {
        case ..<1000: "\(count)"
        case ..<1_000_000: String(format: "%.1fk", Double(count) / 1000)
        default: String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

struct CatalogBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Theme.mono(.micro, .semibold))
            .foregroundStyle(tint)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}
