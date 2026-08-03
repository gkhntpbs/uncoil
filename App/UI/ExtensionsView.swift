import AppKit
import SwiftUI

struct ExtensionsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview
        case agents
        case skills
        case mcpServers
        case mcpCatalog
        case skillCatalog
        case assignments
        case sources
        case security
        case updates
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .agents: String(localized: "Agents")
            case .skills: String(localized: "Skills")
            case .mcpServers: String(localized: "MCP Servers")
            case .mcpCatalog: String(localized: "MCP Catalog")
            case .skillCatalog: String(localized: "Skill Catalog")
            case .assignments: String(localized: "Assignments")
            case .sources: String(localized: "Sources")
            case .security: String(localized: "Security")
            case .updates: String(localized: "Updates")
            case .activity: String(localized: "Activity")
            }
        }

        var iconName: String {
            switch self {
            case .overview: "layout-dashboard"
            case .agents: "robot"
            case .skills: "sparkles"
            case .mcpServers: "server"
            case .mcpCatalog: "world-search"
            case .skillCatalog: "book-download"
            case .assignments: "arrows-exchange"
            case .sources: "database"
            case .security: "shield-lock"
            case .updates: "refresh"
            case .activity: "activity"
            }
        }

        /// Extra words the sidebar search matches, so "security" finds Security.
        var keywords: [String] {
            switch self {
            // Search terms, never displayed. Both languages are listed on
            // purpose: the box has to find a section whichever language the
            // person is thinking in, regardless of the interface language.
            case .overview: ["general", "genel", "status", "durum", "summary", "özet", "health"]
            case .agents: ["agent", "claude", "codex", "gemini", "cursor", "amp", "install", "kurulum"]
            case .skills: ["skill", "yetenek", "trigger", "prompt"]
            case .mcpServers: ["mcp", "server", "sunucu", "stdio", "http"]
            case .mcpCatalog: [
                "catalog", "katalog", "registry", "discover", "keşfet", "browse",
                "install", "kur", "mcp", "store", "mağaza",
            ]
            case .skillCatalog: [
                "catalog", "katalog", "skill", "yetenek", "discover", "keşfet",
                "browse", "install", "kur", "github", "trending", "store", "mağaza",
            ]
            case .assignments: ["assignment", "atama", "project", "proje", "matrix", "matris"]
            case .sources: ["source", "kaynak", "github", "repo", "mirror"]
            case .security: [
                "security", "güvenlik", "bumblebee", "scan", "tarama",
                "quarantine", "karantina", "finding", "bulgu",
            ]
            case .updates: ["update", "güncelleme", "rollback", "commit"]
            case .activity: ["activity", "etkinlik", "log", "history", "geçmiş", "audit"]
            }
        }

        var description: String {
            switch self {
            case .overview: "The overall state of the agent extension system"
            case .agents: "Installed agents and their profiles"
            case .skills: "Available skill packages"
            case .mcpServers: "MCP server definitions and their states"
            case .mcpCatalog: "Discover and install MCP servers from the official registry"
            case .skillCatalog: "Discover and install skills from GitHub"
            case .assignments: "Agent and project assignments"
            case .sources: "Extension sources"
            case .security: "Security findings and quarantine"
            case .updates: "Package updates"
            case .activity: "Extension activity history"
            }
        }
    }

    @EnvironmentObject private var projectStore: ProjectStore
    // The shared lock file lives in the user's home; a test-made registry never
    // gets one, which is why `skillLockHome` is set in `init` rather than
    // defaulted.
    @StateObject private var registry: ExtensionRegistry
    @State private var selection: Section = .overview
    @State private var selectedPackageID: String?
    @StateObject private var notices = ExtensionNoticeCenter()
    /// True while a health check is running, so the button can say so.
    @State private var isCheckingHealth = false
    /// Window-wide search: filters the sidebar and, while it has text, replaces
    /// the screen with what it found across every section.
    @State private var query = ""
    /// One coordinator for the whole window: the Security screen and the
    /// Extensions menu's quick scan have to be the same scan, not two.
    @StateObject private var scans: BumblebeeScanCoordinator
    @ObservedObject private var commands = ExtensionsCommandBus.shared
    // One store per catalog page, owned by the window: switching sections
    // keeps what was already loaded instead of refetching.
    @StateObject private var mcpCatalog = CatalogStore(kind: .mcpServer)
    @StateObject private var skillCatalog = CatalogStore(kind: .skill)

    init() {
        let registry = ExtensionRegistry()
        registry.skillLockHome = LaunchConfig.shared.isUITesting
            ? nil
            : FileManager.default.homeDirectoryForCurrentUser
        _registry = StateObject(wrappedValue: registry)
        _scans = StateObject(wrappedValue: BumblebeeScanCoordinator(registry: registry))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
            content
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .background(ExtensionsWindowFrame())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.container")
        .task {
            // Deferred so the first view update never mutates a published store.
            await Task.yield()
            registry.discover()
            if query.isEmpty, let seeded = LaunchConfig.shared.extensionsQuery {
                query = seeded
            }
            if selectedPackageID == nil {
                selectedPackageID = LaunchConfig.shared.extensionsExpand
            }
            if let action = LaunchConfig.shared.extensionsAction
                .flatMap(ExtensionsCommandBus.QuickAction.init(rawValue:)) {
                commands.request = action
            }
            applyPendingCommands()
        }
        .onChange(of: commands.route) { applyPendingCommands() }
        .onChange(of: commands.request) { applyPendingCommands() }
    }

    /// Runs whatever the Extensions menu asked for. Each request is consumed, so
    /// re-opening the window later does not repeat it.
    private func applyPendingCommands() {
        if let route = commands.route {
            selection = route
            commands.route = nil
        }
        guard let request = commands.request else { return }
        commands.request = nil
        switch request {
        case .rediscover:
            registry.discover()
            notices.post(discoverySummary(), level: .success)
        case .healthCheck:
            runHealthCheck()
        case .bumblebeeScan:
            selection = .security
            notices.post("Bumblebee scan started…", level: .info)
            Task {
                let outcome = await scans.scanManually()
                notices.post(
                    outcome.message,
                    level: outcome.didRun ? .success : .warning
                )
            }
        }
    }

    /// Runs discovery and the health checks, then says what came out of it. The
    /// button that starts it stays busy until it is done, and the result lands on
    /// the Overview screen where the checks are listed.
    private func runHealthCheck() {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        selection = .overview
        query = ""
        Task {
            // Yielding first so the button shows its running state before the
            // synchronous discovery pass takes the main thread.
            await Task.yield()
            registry.discover()
            let results = registry.health
            let failures = results.filter { $0.outcome == .failure }
            let warnings = results.filter { $0.outcome == .warning }
            isCheckingHealth = false
            let summary = String(localized: "Health check: \(results.count) checks · \(results.filter { $0.outcome == .ok }.count) healthy")
                + (warnings.isEmpty ? "" : ", \(warnings.count) warnings")
                + (failures.isEmpty ? "" : ", \(failures.count) errors")
            notices.post(
                summary,
                level: failures.isEmpty ? (warnings.isEmpty ? .success : .warning) : .failure,
                detail: results.isEmpty ? nil : results.map {
                    "\($0.outcome.label.uppercased()) · \($0.name): \($0.detail)"
                        + ($0.remedy.map { remedy in " → \(remedy)" } ?? "")
                }.joined(separator: "\n")
            )
        }
    }

    /// What a rediscovery found, in one line.
    private func discoverySummary() -> String {
        let overview = registry.overview
        return "Tarama bitti: \(registry.installations.count) agent · "
            + "\(registry.skills.count) skill · \(overview.mcpServers) MCP server"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 42)
            Text("EXTENSIONS")
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                TablerIcon(name: "search", size: 11, color: Theme.textFaint)
                TextField("Search everywhere", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("extensions.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("extensions.search.clear")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 8)

            ForEach(visibleSections) { section in
                SectionNavRow(
                    section: section,
                    isSelected: selection == section,
                    badge: badge(for: section)
                ) {
                    selection = section
                }
            }

            Spacer()

            Button(action: runHealthCheck) {
                HStack(spacing: 7) {
                    if isCheckingHealth {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        TablerIcon(name: "stethoscope", size: 12, color: Theme.text)
                    }
                    Text(isCheckingHealth ? "Checking…" : "Run Health Check")
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
            .buttonStyle(.pressable)
            .disabled(isCheckingHealth)
            .padding(.bottom, 12)
            .accessibilityIdentifier("extensions.runHealthCheck")
        }
        .padding(.horizontal, 8)
        .frame(width: 196)
        .background(Theme.panel.opacity(0.35))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Sections the sidebar shows: everything, or the ones the query names. A
    /// query that names no section still leaves the list alone — the results are
    /// what matters then, not the navigation.
    private var visibleSections: [Section] {
        let value = trimmedQuery.lowercased()
        guard !value.isEmpty else { return Section.allCases }
        let matches = Section.allCases.filter {
            $0.title.lowercased().contains(value)
                || $0.keywords.contains { $0.contains(value) }
        }
        return matches.isEmpty ? Section.allCases : matches
    }

    private func badge(for section: Section) -> (count: Int, color: Color)? {
        switch section {
        case .updates:
            registry.updateCandidates.isEmpty ? nil : (registry.updateCandidates.count, Theme.highlight)
        case .security:
            registry.openFindings.isEmpty ? nil : (registry.openFindings.count, Theme.danger)
        default:
            nil
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 28)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isSearching ? "Search" : selection.title)
                        .font(Theme.ui(.title, .bold))
                        .foregroundStyle(Theme.text)
                    Text(
                        isSearching
                            ? "Results across every section for “\(trimmedQuery)”"
                            : selection.description
                    )
                    .font(Theme.ui(.body))
                    .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if let lastDiscoveryAt = registry.lastDiscoveryAt {
                    Text("Last scan \(RelativeClock.short(since: lastDiscoveryAt))")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            if !notices.notices.isEmpty {
                ExtensionNoticeStack(center: notices)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            ScrollView {
                screen
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Inside the content, not on the ScrollView: the styler finds
                    // its scroll view by looking upwards from where it sits.
                    .uncoilScrollers()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.content.\(selection.rawValue)")
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    @ViewBuilder
    private var screen: some View {
        if isSearching {
            ExtensionSearchResults(
                registry: registry,
                query: trimmedQuery,
                open: { section, packageID in
                    selection = section
                    selectedPackageID = packageID
                    query = ""
                }
            )
        } else {
            sectionScreen
        }
    }

    @ViewBuilder
    private var sectionScreen: some View {
        switch selection {
        case .overview:
            OverviewScreen(registry: registry)
        case .agents:
            AgentsScreen(registry: registry, message: notices.messageBinding)
        case .skills:
            PackagesScreen(
                registry: registry, kind: .skill,
                selectedPackageID: $selectedPackageID, message: notices.messageBinding
            )
        case .mcpServers:
            PackagesScreen(
                registry: registry, kind: .mcpServer,
                selectedPackageID: $selectedPackageID, message: notices.messageBinding
            )
        case .mcpCatalog:
            CatalogScreen(
                registry: registry, catalog: mcpCatalog, scans: scans,
                message: notices.messageBinding
            )
        case .skillCatalog:
            CatalogScreen(
                registry: registry, catalog: skillCatalog, scans: scans,
                message: notices.messageBinding
            )
        case .assignments:
            AssignmentsScreen(registry: registry)
        case .sources:
            SourcesScreen(registry: registry, message: notices.messageBinding)
        case .security:
            SecurityScreen(registry: registry, scans: scans, message: notices.messageBinding)
        case .updates:
            UpdatesScreen(registry: registry, message: notices.messageBinding)
        case .activity:
            ActivityScreen(registry: registry, message: notices.messageBinding)
        }
    }
}

// MARK: - Shared pieces

/// A row in the Extensions window's own navigator.
///
/// Extracted from the list it used to be written inline in, because a row that
/// tracks the pointer needs state and a `ForEach` body cannot hold any. Until
/// now the only section that reacted to anything was the selected one: moving
/// the cursor down the list changed nothing at all.
private struct SectionNavRow: View {
    let section: ExtensionsView.Section
    let isSelected: Bool
    let badge: (count: Int, color: Color)?
    let action: () -> Void

    @State private var hovering = false

    private var foreground: Color {
        isSelected || hovering ? Theme.text : Theme.textDim
    }

    private var fill: Color {
        if isSelected { return Theme.panelActive }
        return hovering ? Theme.panelHover : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                TablerIcon(name: section.iconName, size: 13, color: foreground)
                Text(section.title)
                    .font(Theme.mono(.body, isSelected ? .semibold : .regular))
                    .foregroundStyle(foreground)
                Spacer()
                if let badge {
                    Text("\(badge.count)")
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.quick, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("extensions.section.\(section.rawValue)")
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var tint: Color?
    var detail: String?

    /// Every tile is the same height whether or not it has a detail line, so the
    /// grid stays a grid instead of a row of differently-sized cards.
    static let height: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.mono(.display, .bold))
                .foregroundStyle(tint ?? Theme.text)
                .lineLimit(1)
            Text(label)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            // Reserved even when empty: the label of a tile without a detail
            // still has to sit where the others' labels do.
            Text(detail ?? " ")
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height)
        .panel()
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .panel()
        }
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var tint: Color?
    var isMonospacedValue = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(isMonospacedValue ? Theme.mono(.body) : Theme.mono(.body, .medium))
                .foregroundStyle(tint ?? Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct HealthRow: View {
    let result: HealthCheckResult

    private var color: Color {
        switch result.outcome {
        case .ok: Theme.ok
        case .warning: Theme.warn
        case .failure: Theme.danger
        case .notApplicable: Theme.textFaint
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
                Text(result.detail)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textDim)
                if let remedy = result.remedy {
                    Text(remedy)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            Text(result.outcome.label)
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityIdentifier("extensions.health.\(result.id)")
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(.body))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }
}

private struct SourceBadge: View {
    let source: ExtensionSource

    private var tint: Color {
        source.isManaged ? Theme.highlight : (source.isOwnedByUncoil ? Theme.ok : Theme.textFaint)
    }

    /// Each source class says what it is: "Bundled" for everything Uncoil owns
    /// would call an adopted extension something it is not.
    private var label: String {
        switch source {
        case .managedGitHub: String(localized: "Managed")
        case .bundled: String(localized: "Bundled")
        case .adopted: String(localized: "Adopted")
        case .local: String(localized: "Local")
        case .detectedExternal: String(localized: "Unmanaged")
        case .remoteMCP: String(localized: "Remote")
        }
    }

    var body: some View {
        Text(label)
            .font(Theme.mono(.micro, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Overview

private struct OverviewScreen: View {
    @ObservedObject var registry: ExtensionRegistry

    var body: some View {
        let overview = registry.overview
        VStack(alignment: .leading, spacing: 18) {
            // Adaptive rather than three fixed columns: on a wide window the
            // tiles stay a readable width and gain a column instead of each one
            // stretching to a different shape.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)],
                spacing: 12
            ) {
                StatTile(
                    label: String(localized: "Installed agents"),
                    value: "\(overview.agents.count)",
                    detail: overview.agents.isEmpty ? String(localized: "Not found") : overview.agents.joined(separator: ", ")
                )
                StatTile(label: String(localized: "Managed skill"), value: "\(overview.managedSkills)")
                StatTile(
                    label: String(localized: "Unmanaged skill"),
                    value: "\(overview.unmanagedSkills)",
                    detail: String(localized: "Installed outside Uncoil")
                )
                StatTile(label: String(localized: "MCP server"), value: "\(overview.mcpServers)")
                StatTile(
                    label: String(localized: "Update pending"),
                    value: "\(overview.pendingUpdates)",
                    tint: overview.pendingUpdates > 0 ? Theme.highlight : nil
                )
                StatTile(
                    label: String(localized: "Broken extensions"),
                    value: "\(overview.brokenExtensions)",
                    tint: overview.brokenExtensions > 0 ? Theme.danger : nil
                )
                StatTile(
                    label: String(localized: "Security finding"),
                    value: "\(overview.openFindings)",
                    tint: overview.openFindings > 0 ? Theme.danger : nil
                )
                StatTile(
                    label: String(localized: "Config drift"),
                    value: "\(overview.configDrift)",
                    tint: overview.configDrift > 0 ? Theme.warn : nil
                )
                StatTile(
                    label: String(localized: "Last Bumblebee scan"),
                    value: overview.lastBumblebeeScan
                        .map { RelativeClock.short(since: $0) } ?? "—",
                    detail: overview.bumblebeeSummary ?? String(localized: "Never run")
                )
            }
            .accessibilityIdentifier("extensions.overview.tiles")

            SectionCard(title: String(localized: "Health check")) {
                if registry.health.isEmpty {
                    EmptyRow(text: String(localized: "Has not run yet."))
                } else {
                    ForEach(Array(registry.health.enumerated()), id: \.element.id) { index, result in
                        HealthRow(result: result)
                        if index != registry.health.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
            }

            if !registry.configurationIssues.isEmpty {
                SectionCard(
                    title: String(localized: "Agent config warnings"),
                    detail: String(localized: "Uncoil changes these files only through plan → apply.")
                ) {
                    ForEach(registry.configurationIssues) { issue in
                        HStack(alignment: .top, spacing: 9) {
                            TablerIcon(
                                name: issue.severity == .error ? "alert-triangle" : "info-circle",
                                size: 12,
                                color: issue.severity == .error ? Theme.danger : Theme.warn
                            )
                            .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.message)
                                    .font(Theme.ui(.body))
                                    .foregroundStyle(Theme.text)
                                if let remedy = issue.remedy {
                                    Text(remedy)
                                        .font(Theme.mono(.small))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

// MARK: - Agents

private struct AgentsScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?
    @EnvironmentObject private var settings: SettingsStore
    @State private var versions: [ExtensionAgentID: String] = [:]
    /// A planned config change awaiting the user's word, with the changes it was
    /// built from so a stale config can be re-planned on top of the user's edit.
    @State private var plan: (
        transaction: ConfigurationTransaction,
        changes: [ConfigurationChange],
        installation: AgentInstallation,
        summary: String,
        issues: [ConfigurationIssue]
    )?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if registry.installations.isEmpty {
                SectionCard(title: String(localized: "Agent not found")) {
                    EmptyRow(text: String(localized: "Neither Claude Code nor Codex is installed."))
                }
            }

            ForEach(registry.installations) { installation in
                let configuration = registry.configurations.first {
                    $0.installation.id == installation.id
                }
                SectionCard(
                    title: installation.agent.displayName,
                    detail: capabilitySummary(installation.agent)
                ) {
                    KeyValueRow(key: "Install path", value: installation.binaryPath)
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Binary version",
                        value: installation.version
                            ?? versions[installation.agent]
                            ?? "not asked"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Aktif profil", value: activeProfile(installation.agent))
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Update durumu",
                        value: updateStatus(installation.agent),
                        tint: registry.updateCandidates.isEmpty ? nil : Theme.highlight
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Login durumu",
                        value: installation.isAuthenticated
                            .map { $0 ? "Signed in" : "Login required" } ?? "unknown",
                        tint: installation.isAuthenticated == false ? Theme.warn : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Config dizini", value: installation.configDirectory)
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "MCP config",
                        value: installation.mcpConfigPath ?? "none"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Skill dizini",
                        value: installation.skillsDirectory ?? "none"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Last verified",
                        value: registry.lastDiscoveryAt
                            .map { RelativeClock.short(since: $0) } ?? "—"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Declared MCP",
                        value: "\(configuration?.mcpServers.count ?? 0)"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Visible skill",
                        value: configuration?.skillNames.joined(separator: ", ") ?? "—"
                    )

                    Divider().overlay(Theme.border)
                    FlowRow(spacing: 9) {
                        Button("Validate") {
                            registry.discover()
                            let issues = registry.configurationIssues.count
                            message = issues == 0
                                ? "\(installation.agent.displayName)'s config is valid."
                                : "\(issues) warnings found; they are listed in Overview."
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.validate.\(installation.agent.rawValue)")

                        Button("Repair") {
                            message = repairLinks(installation)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.repair.\(installation.agent.rawValue)")

                        Button("Export Setup") {
                            message = exportSetup(installation)
                        }
                        .buttonStyle(GhostButtonStyle())

                        Button("Import Setup") {
                            importSetup(installation)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.import.\(installation.agent.rawValue)")

                        Button("Show Config") {
                            guard let path = installation.mcpConfigPath else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: path),
                            ])
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if let configuration, !configuration.mcpServers.isEmpty {
                        Divider().overlay(Theme.border)
                        ForEach(configuration.mcpServers) { server in
                            HStack(spacing: 8) {
                                TablerIcon(
                                    name: server.isEnabled ? "server" : "server-off",
                                    size: 11,
                                    color: server.isEnabled ? Theme.highlight : Theme.textFaint
                                )
                                Text(server.name)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.text)
                                Text(server.transport.rawValue)
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textFaint)
                                Spacer()
                                Button(server.isEnabled ? "Close" : "Open") {
                                    planChange(
                                        [.setMCPServerEnabled(
                                            name: server.name, isEnabled: !server.isEnabled
                                        )],
                                        installation: installation,
                                        summary: server.isEnabled
                                            ? String(localized: "Stopping \(server.name)")
                                            : String(localized: "Starting \(server.name)")
                                    )
                                }
                                .buttonStyle(GhostButtonStyle())
                                .font(Theme.mono(.micro))
                                .accessibilityIdentifier(
                                    "extensions.mcp.toggle.\(installation.agent.rawValue).\(server.name)"
                                )
                                Button("Remove") {
                                    planChange(
                                        [.removeMCPServer(name: server.name)],
                                        installation: installation,
                                        summary: String(localized: "Removing \(server.name)")
                                    )
                                }
                                .buttonStyle(GhostButtonStyle())
                                .font(Theme.mono(.micro))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    }

                    if let candidate = registry.rollbackCandidate(for: installation.agent) {
                        Divider().overlay(Theme.border)
                        HStack(spacing: 8) {
                            TablerIcon(name: "history", size: 11, color: Theme.warn)
                            Text(
                                "Last changed "
                                    + (candidate.appliedAt.map {
                                        RelativeClock.short(since: $0)
                                    } ?? "unknown")
                            )
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textDim)
                            Spacer()
                            Button("Back to the Previous Config") {
                                message = rollback(candidate, installation: installation)
                            }
                            .buttonStyle(GhostButtonStyle())
                            .font(Theme.mono(.micro))
                            .accessibilityIdentifier(
                                "extensions.config.rollback.\(installation.agent.rawValue)"
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }

            let unmanagedAgents = AgentAdapterRegistry().unmanagedAgents
            if !unmanagedAgents.isEmpty {
                SectionCard(
                    title: String(localized: "Agents not managed yet"),
                    detail: String(localized: "They will show up here once an adapter exists.")
                ) {
                    ForEach(unmanagedAgents) { agent in
                        KeyValueRow(key: agent.displayName, value: "no adapter")
                    }
                }
            }
        }
        .task { loadVersions() }
        .sheet(
            isPresented: Binding(
                get: { plan != nil },
                set: { if !$0 { plan = nil } }
            )
        ) {
            if let pending = plan {
                ConfigPlanSheet(
                    transaction: pending.transaction,
                    summary: pending.summary,
                    issues: pending.issues,
                    onApply: { applyPlan(pending) },
                    onCancel: { plan = nil }
                )
            }
        }
    }

    /// CLI versions, asked once per appearance and off the main thread.
    private func loadVersions() {
        for installation in registry.installations where versions[installation.agent] == nil {
            let path = installation.binaryPath
            Task {
                let version = await Task.detached(priority: .utility) {
                    CLIToolService.version(binaryPath: path)
                }.value
                versions[installation.agent] = version ?? "could not be read"
            }
        }
    }

    /// The preset Uncoil would launch this agent with. "Profile" is that preset
    /// plus the permission mode it carries.
    private func activeProfile(_ agent: ExtensionAgentID) -> String {
        guard let provider = agent.provider else { return "Uncoil does not launch this agent" }
        guard let preset = settings.presets.first(where: { $0.provider == provider }) else {
            return "no preset"
        }
        return "\(preset.name) · \(preset.grantedCapabilities.count) grants"
    }

    /// What Uncoil knows about updates for this agent: its extensions, not the
    /// CLI itself — Uncoil does not update someone else's binary.
    private func updateStatus(_ agent: ExtensionAgentID) -> String {
        let ids = Set(
            registry.agentBindings
                .filter { $0.agent == agent && $0.isEnabled }
                .map(\.extensionID)
        )
        let pending = registry.updateCandidates.filter { ids.contains($0.extensionID) }
        if pending.isEmpty {
            return registry.lastDiscoveryAt == nil
                ? "kontrol edilmedi"
                : "extensions are up to date"
        }
        return "\(pending.count) extensions can be updated"
    }

    /// Reads a setup export and proposes it as a plan. Nothing is applied here:
    /// an import is a config change like any other.
    private func importSetup(_ installation: AgentInstallation) {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.json]
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url,
              let data = FileManager.default.contents(atPath: url.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            message = String(localized: "The setup file could not be read.")
            return
        }
        guard let servers = root["mcp_servers"] as? [[String: String]], !servers.isEmpty else {
            message = String(localized: "The setup file has no MCP server.")
            return
        }
        let changes: [ConfigurationChange] = servers.compactMap { entry in
            guard let name = entry["name"], let transport = entry["transport"],
                  let target = entry["target"] else { return nil }
            let isHTTP = transport == MCPTransport.http.rawValue
            return .addMCPServer(MCPServerDefinition(
                id: "\(installation.agent.rawValue):\(name)",
                name: name,
                transport: isHTTP ? .http : .stdio,
                command: isHTTP ? nil : target,
                url: isHTTP ? target : nil,
                // Secret VALUES are not in an export; only their names travel, and
                // the launcher fills them from the Keychain at start-up.
                environmentKeys: (entry["secret_keys"] ?? "")
                    .split(separator: ",")
                    .map(String.init)
                    .filter { !$0.isEmpty }
            ))
        }
        guard !changes.isEmpty else {
            message = String(localized: "The servers in the setup file could not be read.")
            return
        }
        planChange(
            changes, installation: installation,
            summary: String(localized: "Importing \(changes.count) MCP servers")
        )
    }

    /// Builds the plan and shows it. Nothing is written until the sheet's Apply.
    private func planChange(
        _ changes: [ConfigurationChange],
        installation: AgentInstallation,
        summary: String
    ) {
        let service = ConfigurationTransactionService(registry: AgentAdapterRegistry())
        do {
            let planned = try service.plan(
                changes, agent: installation.agent, installation: installation
            )
            plan = (
                planned.transaction, changes, installation, summary,
                AgentAdapterRegistry().adapter(for: installation.agent)?
                    .validate(planned.configuration) ?? []
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func applyPlan(
        _ pending: (
            transaction: ConfigurationTransaction,
            changes: [ConfigurationChange],
            installation: AgentInstallation,
            summary: String,
            issues: [ConfigurationIssue]
        )
    ) {
        let service = ConfigurationTransactionService(registry: AgentAdapterRegistry())
        plan = nil
        do {
            let outcome = try service.apply(
                pending.transaction, changes: pending.changes, installation: pending.installation
            )
            registry.recordConfigTransaction(outcome.transaction)
            registry.record(
                ConfigurationTransactionService.auditEvent(for: outcome, extensionID: nil)
            )
            registry.discover()
            if let replanned = outcome.replanned {
                // The file moved under us: the user's edit stays and the change
                // is re-proposed on top of it.
                plan = (
                    replanned, pending.changes, pending.installation,
                    pending.summary + " (config changed on disk, replanned)",
                    outcome.issues
                )
                message = String(localized: "The config changed on disk; the plan was recalculated.")
                return
            }
            message = outcome.didApply
                ? "\(pending.summary): applied."
                : (outcome.transaction.failureReason ?? "The change could not be applied.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func rollback(
        _ transaction: ConfigurationTransaction,
        installation: AgentInstallation
    ) -> String {
        let service = ConfigurationTransactionService(registry: AgentAdapterRegistry())
        do {
            let outcome = try service.rollback(transaction, installation: installation)
            registry.recordConfigTransaction(outcome.transaction)
            registry.record(
                ConfigurationTransactionService.auditEvent(for: outcome, extensionID: nil)
            )
            registry.discover()
            guard outcome.transaction.status == .rolledBack else {
                return outcome.transaction.failureReason ?? "Could not be undone."
            }
            let errors = outcome.issues.filter { $0.severity == .error }
            return errors.isEmpty
                ? "The previous config was restored."
                : "Config restored, but with \(errors.count) errors: \(errors[0].message)"
        } catch {
            return error.localizedDescription
        }
    }

    private func capabilitySummary(_ agent: ExtensionAgentID) -> String {
        guard let capabilities = AgentAdapterRegistry().adapter(for: agent)?.capabilities else {
            return "no adapter"
        }
        var parts: [String] = []
        if capabilities.supportsPerSkillSymlinks { parts.append("one symlink per skill") }
        if capabilities.supportsStdioMCP { parts.append("STDIO MCP") }
        if capabilities.supportsHTTPMCP { parts.append("HTTP MCP") }
        if capabilities.supportsProjectScopedMCP { parts.append("per-project MCP") }
        parts.append(
            capabilities.reloadsConfigWithoutRestart
                ? "reads its config live"
                : "needs a restart for config"
        )
        if capabilities.reportsAuthenticationState { parts.append("reports the login state") }
        return parts.joined(separator: " · ")
    }

    private func repairLinks(_ installation: AgentInstallation) -> String {
        guard let directory = installation.skillsDirectory.map({ URL(fileURLWithPath: $0) }) else {
            return "\(installation.agent.displayName) has no skill directory."
        }
        let store = SkillStore(layout: registry.layout)
        var repaired: [String] = []
        var skipped: [String] = []
        // Only the skills this agent was actually given: repairing would
        // otherwise hand it every skill in the store.
        for package in registry.skills
        where package.source.isOwnedByUncoil
            && registry.agents(for: package.id).contains(installation.agent) {
            let status = store.status(name: package.name, inAgentDirectory: directory)
            guard status.needsRepair else { continue }
            guard status.isRepairable else {
                skipped.append(package.name)
                continue
            }
            if (try? store.repair(name: package.name, inAgentDirectory: directory)) == .linked {
                repaired.append(package.name)
            }
        }
        registry.discover()
        if repaired.isEmpty && skipped.isEmpty { return "No link to repair." }
        var text = repaired.isEmpty ? "" : "Repaired: \(repaired.joined(separator: ", "))."
        if !skipped.isEmpty {
            text += " Untouched (your own file): \(skipped.joined(separator: ", "))."
        }
        return text
    }

    private func exportSetup(_ installation: AgentInstallation) -> String {
        // Secrets are deliberately excluded: an export carries names, never values.
        let configuration = registry.configurations.first { $0.installation.id == installation.id }
        let servers = configuration?.mcpServers.map { server in
            [
                "name": server.name,
                "transport": server.transport.rawValue,
                "target": server.displayTarget,
                "secret_keys": server.environmentKeys.joined(separator: ","),
            ]
        } ?? []
        let payload: [String: Any] = [
            "agent": installation.agent.rawValue,
            "config_directory": installation.configDirectory,
            "skills": configuration?.skillNames ?? [],
            "mcp_servers": servers,
            "secrets_included": false,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return "The export could not be prepared." }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-\(installation.agent.rawValue)-setup.json")
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Export written (secret values were left out): \(url.lastPathComponent)"
    }
}

// MARK: - Skills and MCP servers

private struct PackagesScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    let kind: ExtensionKind
    @Binding var selectedPackageID: String?
    @Binding var message: String?
    @State private var confirmsAdoptAll = false
    @State private var isCreatingSkill = false

    private var packages: [ExtensionPackage] {
        registry.packages.filter { $0.kind == kind }
    }

    /// The ones an "adopt everything" pass would actually touch. A skill needs
    /// files on disk to collect; an MCP server needs a definition in some agent's
    /// config to take over. Anything else is not counted, so the button never
    /// promises what it cannot do.
    private var adoptable: [ExtensionPackage] {
        packages.filter { package in
            guard package.source.capabilities.canAdopt,
                  case .detectedExternal(let path) = package.source else { return false }
            return package.kind == .mcpServer
                ? registry.definition(named: package.name) != nil
                : FileManager.default.fileExists(atPath: path)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            toolbar

            if kind == .skill {
                TriggerTesterCard(registry: registry)
            }

            if packages.isEmpty {
                SectionCard(title: String(localized: "No \(kind.label) found")) {
                    EmptyRow(
                        text: kind == .skill
                            ? String(localized: "Nothing shows up in the agents' skill directories.")
                            : String(localized: "No MCP server is defined in the agent configs.")
                    )
                }
            }

            ForEach(packages) { package in
                PackageCard(
                    registry: registry,
                    package: package,
                    isExpanded: selectedPackageID == package.id,
                    toggle: {
                        selectedPackageID = selectedPackageID == package.id ? nil : package.id
                    },
                    message: $message
                )
            }
        }
        .sheet(isPresented: $isCreatingSkill) {
            SkillCreateSheet(
                registry: registry,
                onFinish: { text in
                    isCreatingSkill = false
                    if let text { message = text }
                }
            )
        }
        .confirmationDialog(
            "Bring \(adoptable.count) \(kind.label.lowercased()) into Uncoil?",
            isPresented: $confirmsAdoptAll,
            titleVisibility: .visible
        ) {
            Button("Adopt All", role: .destructive) { adoptAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The files are copied into Uncoil's own store, backed up first, and"
                    + " source folders are left alone. Packages with a blocking security"
                    + " finding are skipped."
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            if kind == .skill {
                Button("New Skill…") { isCreatingSkill = true }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("extensions.skills.create")

                Button("Add from Folder…") { importFolder() }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.skills.import")
            }

            Button("Adopt All (\(adoptable.count))") { confirmsAdoptAll = true }
                .buttonStyle(kind == .skill ? AnyButtonStyle(GhostButtonStyle()) : AnyButtonStyle(AccentButtonStyle()))
                .disabled(adoptable.isEmpty)
                .accessibilityIdentifier("extensions.\(kind.rawValue).adoptAll")

            Spacer()
            Text("\(packages.count) records")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
        }
    }

    /// Adopts every unmanaged package of this kind, one plan at a time, and says
    /// exactly what was skipped instead of reporting a clean sweep.
    private func adoptAll() {
        let service = ExtensionAdoptionService(layout: registry.layout)
        var adopted: [String] = []
        var failures: [String] = []
        for package in adoptable {
            guard case .detectedExternal(let path) = package.source else {
                failures.append("\(package.name) (not an external install)")
                continue
            }
            do {
                let plan = try adoptionPlan(for: package, service: service, path: path)
                let result = try service.adopt(plan)
                // The old detected entry is replaced, not left beside the adopted
                // one: they describe the same files.
                registry.remove(packageID: package.id)
                registry.upsert(result)
                for copy in plan.agentCopies {
                    registry.setAgentBinding(true, packageID: result.id, agent: copy.agent)
                }
                registry.record(AuditEvent(
                    kind: package.kind == .skill ? .skillInstalled : .mcpEnabled,
                    extensionID: result.id,
                    detail: String(localized: "bulk adoption: \(plan.summary), backup \(plan.backupPath ?? "-")")
                ))
                adopted.append(package.name)
            } catch {
                failures.append("\(package.name) (\(error.localizedDescription))")
            }
        }
        registry.discover()
        var parts: [String] = []
        if !adopted.isEmpty {
            parts.append("\(adopted.count) paket sahiplenildi: \(adopted.joined(separator: ", "))")
        }
        if !failures.isEmpty {
            parts.append("could not be done: \(failures.joined(separator: ", "))")
        }
        message = parts.isEmpty ? "No package to adopt." : parts.joined(separator: " · ")
    }

    /// The plan for one package, whichever kind it is: a skill's files, or an MCP
    /// server's definition as the agent configs declare it.
    private func adoptionPlan(
        for package: ExtensionPackage,
        service: ExtensionAdoptionService,
        path: String
    ) throws -> ExtensionAdoptionService.Plan {
        let findings = registry.findings.filter { $0.extensionID == package.id }
        if package.kind == .mcpServer {
            guard let definition = registry.definition(named: package.name) else {
                throw AgentAdapterError.unsupportedChange(
                    "\(package.name) is not declared in any agent config."
                )
            }
            return try service.planDefinition(
                definition,
                agents: registry.agents(declaring: package.name),
                findings: findings
            )
        }
        return try service.plan(
            name: package.name, kind: package.kind, externalPath: path,
            findings: findings, installations: registry.installations
        )
    }

    /// Takes in a skill folder the user picks. The folder itself is only read.
    private func importFolder() {
        let picker = NSOpenPanel()
        picker.title = String(localized: "Choose the skill folder")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let package = try SkillAuthoringService(layout: registry.layout).importFolder(at: url)
            registry.upsert(package)
            registry.record(AuditEvent(
                kind: .skillInstalled, extensionID: package.id,
                detail: String(localized: "added from a folder: \(url.path)")
            ))
            message = String(localized: "\(package.name) added; its source folder was left alone.")
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PackageCard: View {
    @ObservedObject var registry: ExtensionRegistry
    let package: ExtensionPackage
    let isExpanded: Bool
    let toggle: () -> Void
    @Binding var message: String?
    @EnvironmentObject private var projectStore: ProjectStore
    /// Adoption plan awaiting the user: the diff and the backup are on screen
    /// before any file is copied in.
    @State private var adoption: ExtensionAdoptionService.Plan?
    /// Repository the user is typing to attach to a local source.
    @State private var linkingRepository: String?
    @State private var showsLogs = false
    /// Pointer over the header, which is the whole disclosure target.
    @State private var headerHovering = false

    private var candidate: UpdateCandidate? {
        registry.updateCandidate(for: package.id)
    }

    private var findings: [SecurityFinding] {
        registry.findings.filter { $0.extensionID == package.id }
    }

    private var files: [String] {
        guard let path = package.activeRevision?.path else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted() ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(Theme.border)
                detail
            }
        }
        .panel()
        .accessibilityIdentifier("extensions.package.\(package.id)")
        .sheet(isPresented: $showsLogs) {
            TaskDiffSheet(
                taskText: "\(package.name) — MCP log",
                diff: registry.logTail(for: package) ?? "No log.",
                onClose: { showsLogs = false }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { adoption != nil },
                set: { if !$0 { adoption = nil } }
            )
        ) {
            if let plan = adoption {
                ExtensionAdoptionSheet(
                    plan: plan,
                    onAdopt: { adopt(plan) },
                    onCancel: { adoption = nil }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { linkingRepository != nil },
                set: { if !$0 { linkingRepository = nil } }
            )
        ) {
            RepositoryLinkSheet(
                packageName: package.name,
                onLink: { repository, tracking in linkToRepository(repository, tracking: tracking) },
                onCancel: { linkingRepository = nil }
            )
        }
    }

    /// Builds the adoption plan: file diff, backup, and the findings that would
    /// block it. Copies nothing.
    private func planAdoption() {
        guard case .detectedExternal(let path) = package.source else { return }
        let service = ExtensionAdoptionService(layout: registry.layout)
        do {
            if package.kind == .mcpServer {
                guard let definition = registry.definition(named: package.name) else {
                    message = String(localized: "\(package.name) is not declared in any agent config.")
                    return
                }
                adoption = try service.planDefinition(
                    definition,
                    agents: registry.agents(declaring: package.name),
                    findings: findings
                )
            } else {
                adoption = try service.plan(
                    name: package.name, kind: package.kind, externalPath: path,
                    findings: findings,
                    installations: registry.installations
                )
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func adopt(_ plan: ExtensionAdoptionService.Plan) {
        adoption = nil
        // A quick scan before anything is copied in. With no Bumblebee installed
        // this says so and the step continues on Uncoil's own findings.
        Task {
            let outcome = await BumblebeeScanCoordinator(registry: registry)
                .scanBeforeInstall(path: plan.externalPath)
            if outcome.didRun { message = outcome.message }
        }
        let service = ExtensionAdoptionService(layout: registry.layout)
        do {
            let adopted = try service.adopt(plan)
            registry.remove(packageID: package.id)
            registry.upsert(adopted)
            for copy in plan.agentCopies {
                registry.setAgentBinding(true, packageID: adopted.id, agent: copy.agent)
            }
            registry.record(AuditEvent(
                kind: package.kind == .skill ? .skillInstalled : .mcpEnabled,
                extensionID: adopted.id,
                detail: String(localized: "adopted: \(plan.summary), backup \(plan.backupPath ?? "-")")
            ))
            registry.discover()
            message = plan.agentCopies.isEmpty
                ? "\(package.name) sahiplenildi; \(plan.summary)."
                : "\(package.name) sahiplenildi; \(plan.summary). "
                    + "\(plan.agentCopies.count) agent copies were linked to a single copy."
        } catch {
            message = error.localizedDescription
        }
    }

    private func linkToRepository(_ repository: String, tracking: ExtensionSource.TrackingMode) {
        linkingRepository = nil
        guard let source = package.source.linkedToRepository(repository, tracking: tracking) else {
            message = String(localized: "\(package.name) cannot be linked to a repo.")
            return
        }
        var updated = package
        updated.source = source
        registry.upsert(updated)
        registry.record(AuditEvent(
            kind: .configChanged, extensionID: package.id,
            detail: String(localized: "source linked: \(repository) · \(tracking.label)")
        ))
        message = String(localized: "\(package.name) is now managed from \(repository).")
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                TablerIcon(
                    name: package.kind == .skill ? "sparkles" : "server",
                    size: 14,
                    color: package.state == .quarantined ? Theme.danger : Theme.textDim
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(package.name)
                            .font(Theme.mono(.large, .semibold))
                            .foregroundStyle(Theme.text)
                        SourceBadge(source: package.source)
                        if package.state != .active {
                            StatusBadge(
                                text: package.state.label,
                                level: package.state == .quarantined ? .danger : .warning
                            )
                        }
                        if package.hasLocalModification {
                            StatusBadge(text: String(localized: "Modified Locally"), level: .warning)
                        }
                        if let coverage = BumblebeeCoverage.label(for: package) {
                            StatusBadge(text: coverage, level: .neutral)
                        }
                    }
                    Text(package.summary ?? package.source.label)
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                Spacer()
                if candidate != nil {
                    Text("update")
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(Theme.highlight)
                }
                if let highest = findings.filter({ !$0.isAccepted }).map(\.severity).max() {
                    Text(highest.label)
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(highest >= .high ? Theme.danger : Theme.warn)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .animation(Theme.Motion.standard, value: isExpanded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                headerHovering ? Theme.panelHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.quick, value: headerHovering)
        .onHover { headerHovering = $0 }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeyValueRow(key: "Source", value: package.source.label)
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Management",
                value: package.source.isOwnedByUncoil ? "Managed by Uncoil" : "Unmanaged",
                tint: package.source.isOwnedByUncoil ? nil : Theme.textDim
            )
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Installed commit",
                value: package.activeRevision?.commitSHA?.prefix(12).description
                    ?? (package.activeRevision == nil ? "—" : "yerel kopya")
            )
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Available commit",
                value: package.supportsUpdateCheck
                    ? (candidate?.availableCommitSHA.prefix(12).description ?? "up to date")
                    : "out of reach",
                tint: candidate == nil ? nil : Theme.highlight
            )
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Agent assignments",
                value: registry.agents(for: package.id).isEmpty
                    ? "—"
                    : registry.agents(for: package.id).map(\.displayName).joined(separator: ", ")
            )
            Divider().overlay(Theme.border)
            KeyValueRow(key: "Project assignments", value: projectAssignmentSummary)
            if package.kind == .mcpServer {
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Transport", value: transportSummary)
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Authentication", value: authenticationSummary)
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Tool listesi", value: toolSummary)
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Prompt/resource listesi", value: promptResourceSummary)
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Last health check",
                    value: registry.lastHealthCheckAt[package.id]
                        .map { "\(RelativeClock.short(since: $0)) · \(processStateLabel)" }
                        ?? "never run"
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Last error",
                    value: registry.lastErrors[package.id] ?? "—",
                    tint: registry.lastErrors[package.id] == nil ? nil : Theme.danger
                )
            }
            if package.kind == .skill {
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Files",
                    value: files.isEmpty ? "—" : files.joined(separator: ", ")
                )
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Dependency listesi", value: dependencySummary)
                Divider().overlay(Theme.border)
                KeyValueRow(key: "Trigger test sonucu", value: triggerSummary)
            }
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Security durumu",
                value: findings.isEmpty
                    ? "No findings (scan reach was limited)"
                    : findings.map { "\($0.severity.label): \($0.rule)" }.joined(separator: ", "),
                tint: findings.contains { $0.severity >= .high && !$0.isAccepted } ? Theme.danger : nil
            )

            Divider().overlay(Theme.border)
            actions
        }
    }

    private var processStateLabel: String {
        registry.processHealth[package.id]?.state.label ?? "unknown"
    }

    /// Prompts and resources the server reports having. Absent when nothing has
    /// asked it yet — not the same as "it has none".
    private var promptResourceSummary: String {
        let reported = registry.reportedCapabilities[package.id] ?? []
        guard !reported.isEmpty else { return "the server did not report it" }
        let interesting = reported.filter { $0 == "prompts" || $0 == "resources" }
        return interesting.isEmpty ? "none" : interesting.joined(separator: ", ")
    }

    /// Dependencies the skill's own manifest declares.
    private var dependencySummary: String {
        guard let path = package.activeRevision?.path else { return "—" }
        let dependencies = ExtensionInstallPreviewBuilder
            .dependencies(at: URL(fileURLWithPath: path))
        return dependencies.isEmpty ? "—" : dependencies.joined(separator: ", ")
    }

    /// The last trigger test that mentioned this skill.
    private var triggerSummary: String {
        guard let entry = SkillTriggerHistory.shared.entries.first(where: {
            $0.matchedNames.contains(package.name)
        }) else { return "test edilmedi" }
        return "\(entry.verdict) · \"\(entry.prompt)\" · \(RelativeClock.short(since: entry.testedAt))"
    }

    private func update() -> String {
        guard let candidate = registry.updateCandidate(for: package.id) else {
            return "No update."
        }
        let engine = ExtensionUpdateEngine(
            mirror: ExtensionMirror(layout: registry.layout),
            store: SkillStore(layout: registry.layout),
            scan: { ExtensionSecurityScanner.scan(packageAt: $0).findings }
        )
        do {
            let staged = try engine.stage(candidate, package: package)
            let coordinator = BumblebeeScanCoordinator(registry: registry)
            let stagedPath = staged.path
            Task { _ = await coordinator.scanBeforeUpdate(stagedPath: stagedPath) }
            let updated = try engine.activate(staged, package: package, skillName: package.name)
            registry.upsert(updated)
            registry.record(AuditEvent(
                kind: .updateApplied, extensionID: package.id,
                detail: String(localized: "Updated to \(candidate.availableCommitSHA.prefix(12))")
            ))
            if let activePath = updated.activeRevision?.path {
                Task { _ = await coordinator.scanAfterUpdate(activePath: activePath) }
            }
            registry.discover()
            return "\(package.name) updated."
        } catch {
            return "No update was made: \(error.localizedDescription)"
        }
    }

    private func rollback() -> String {
        let engine = ExtensionUpdateEngine(
            mirror: ExtensionMirror(layout: registry.layout),
            store: SkillStore(layout: registry.layout)
        )
        do {
            let restored = try engine.rollback(package, skillName: package.name).package
            registry.upsert(restored)
            registry.record(AuditEvent(
                kind: .rolledBack, extensionID: package.id, detail: String(localized: "went back to the previous revision")
            ))
            registry.discover()
            return "\(package.name) went back to its previous revision."
        } catch {
            return "No rollback was made: \(error.localizedDescription)"
        }
    }

    private var projectAssignmentSummary: String {
        let bindings = registry.projectBindings.filter { $0.extensionID == package.id }
        guard !bindings.isEmpty else { return "Global" }
        return bindings.map { binding in
            let name = binding.projectID.flatMap { id in
                projectStore.projects.first { $0.id == id }?.name
            } ?? "Global"
            let agent = binding.agent?.displayName
            let scope = [name, agent].compactMap { $0 }.joined(separator: " / ")
            return binding.isEnabled ? scope : "\(scope) (off)"
        }.joined(separator: ", ")
    }

    private var transportSummary: String {
        guard let server = registry.configurations
            .flatMap(\.mcpServers)
            .first(where: { $0.name == package.name }) else { return "—" }
        return "\(server.transport.label) · \(server.displayTarget)"
    }

    private var authenticationSummary: String {
        guard let server = registry.configurations
            .flatMap(\.mcpServers)
            .first(where: { $0.name == package.name }) else { return "—" }
        if !server.environmentKeys.isEmpty {
            return "Secret required: \(server.environmentKeys.joined(separator: ", "))"
        }
        if case .remoteMCP = package.source {
            return "Managed server-side"
        }
        return "Secret gerekmiyor"
    }

    private var toolSummary: String {
        guard let server = registry.configurations
            .flatMap(\.mcpServers)
            .first(where: { $0.name == package.name }) else { return "—" }
        return server.reportedTools.isEmpty
            ? "No handshake"
            : server.reportedTools.joined(separator: ", ")
    }

    private var actions: some View {
        // Wraps instead of squeezing: a package can offer up to nine actions and
        // a squeezed row breaks their labels mid-word.
        FlowRow(spacing: 9) {
            // An external install Uncoil did not adopt is shown, not wired up:
            // assigning it would mean managing files that are not ours.
            if package.source.capabilities.canAssign {
                // Only the agents that are actually installed: a toggle for an
                // agent that is not here would bind an extension to nothing.
                ForEach(registry.installedAgents) { agent in
                    let isOn = registry.agents(for: package.id).contains(agent)
                    Button(isOn ? "\(agent.displayName): on" : "\(agent.displayName): off") {
                        registry.setAgentBinding(!isOn, packageID: package.id, agent: agent)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.package.toggle.\(package.id).\(agent.rawValue)")
                }
            }

            if package.source.capabilities.canAdopt {
                Button("Adopt into Uncoil…") { planAdoption() }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("extensions.package.adopt.\(package.id)")
            }

            if package.source.capabilities.canLinkToRepository {
                Button("Connect to a GitHub Source…") { linkingRepository = "" }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.package.link.\(package.id)")
            }

            if package.state == .quarantined {
                Button("Release from Quarantine") {
                    message = registry.restoreFromQuarantine(packageID: package.id)
                        ? "\(package.name) was restored and relinked."
                        : "\(package.name) could not be restored."
                }
                .buttonStyle(AccentButtonStyle())
            } else {
                Button("Quarantine") {
                    let outcome = registry.quarantine(
                        packageID: package.id,
                        reason: findings.first?.rule ?? String(localized: "you asked for it"),
                        findingID: findings.first?.id
                    )
                    message = String(localized: "\(package.name): \(outcome.summary)")
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.quarantine.\(package.id)")
            }

            if let path = package.activeRevision?.path {
                Button("Inspect Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(GhostButtonStyle())
            }

            if package.source.capabilities.canUpdate {
                Button("Update") { message = update() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(registry.updateCandidate(for: package.id) == nil)
                    .accessibilityIdentifier("extensions.package.update.\(package.id)")
                Button("Rollback") { message = rollback() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(package.previousRevision == nil)
                    .accessibilityIdentifier("extensions.package.rollback.\(package.id)")
            }

            if package.kind == .mcpServer {
                if registry.logURL(for: package) != nil {
                    Button("Logs") { showsLogs = true }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.package.logs.\(package.id)")
                }
                Button("Restart") {
                    let stopped = registry.restart(package)
                    message = stopped == 0
                        ? "There was no running process; the agent starts a new one on its next call."
                        : "\(stopped) processes stopped; the agent will start a new one."
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.restart.\(package.id)")
            }

            if package.source.isOwnedByUncoil {
                Button("Uninstall") {
                    registry.remove(packageID: package.id)
                    registry.record(AuditEvent(
                        kind: package.kind == .skill ? .skillRemoved : .mcpDisabled,
                        extensionID: package.id, detail: "removed"
                    ))
                    message = String(localized: "\(package.name) removed.")
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.uninstall.\(package.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Skill trigger tester

private struct TriggerTesterCard: View {
    @ObservedObject var registry: ExtensionRegistry
    @StateObject private var history = SkillTriggerHistory()
    @State private var prompt = ""
    @State private var results: [SkillTriggerTester.Result] = []
    @State private var candidateCount = 0

    var body: some View {
        SectionCard(
            title: String(localized: "Trigger Tester"),
            detail: String(localized: "Guesses which skill a prompt could trigger, from the descriptions the agent sees.")
        ) {
            HStack(spacing: 9) {
                TextField("Write an example prompt…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .onSubmit(run)
                    .accessibilityIdentifier("extensions.trigger.prompt")
                Button("Test It", action: run)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("extensions.trigger.run")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                Toggle("Keep test history", isOn: $history.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .accessibilityIdentifier("extensions.trigger.keepHistory")
                Spacer()
                if !history.entries.isEmpty {
                    Text("\(history.entries.count) records")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                    Button("Clear History") { history.clear() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !results.isEmpty {
                Divider().overlay(Theme.border)
                Text("\(candidateCount) skill descriptions loaded")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(result.agent.displayName)
                                .font(Theme.mono(.body, .semibold))
                                .foregroundStyle(Theme.text)
                            Text(result.verdict.label)
                                .font(Theme.mono(.small, .semibold))
                                .foregroundStyle(verdictColor(result.verdict))
                        }
                        Text(result.verdict.advice)
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.textDim)
                        ForEach(result.matches) { match in
                            Text("· \(match.candidate.name) — \(Int(match.score * 100))% · \(match.matchedTerms.prefix(4).joined(separator: ", "))")
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("extensions.trigger.result.\(result.agent.rawValue)")
                }
            }
        }
    }

    private func verdictColor(_ verdict: SkillTriggerTester.Verdict) -> Color {
        switch verdict {
        case .single: Theme.ok
        case .noMatch: Theme.textDim
        case .conflict: Theme.warn
        case .tooBroad: Theme.danger
        }
    }

    private func run() {
        let value = prompt.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let candidates = SkillTriggerTester.candidates(
            skills: registry.skills,
            agentBindings: registry.agentBindings
        ) { package in
            guard let path = package.activeRevision?.path
                ?? skillPath(for: package) else { return nil }
            return try? String(
                contentsOf: URL(fileURLWithPath: path).appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
        }
        candidateCount = candidates.count
        results = SkillTriggerTester.testAll(prompt: value, candidates: candidates)
        results.forEach(history.record)
    }

    /// Unmanaged skills have no revision, so their files are read where the
    /// agent keeps them.
    private func skillPath(for package: ExtensionPackage) -> String? {
        if case .detectedExternal(let path) = package.source { return path }
        if case .local(let path) = package.source { return path }
        return nil
    }
}

// MARK: - Assignments

private struct AssignmentsScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @EnvironmentObject private var projectStore: ProjectStore
    /// Filters this screen only; the other screens keep their own state.
    @State private var query = ""

    /// Only the agents actually installed on this machine: an assignment to an
    /// agent that is not here would manage nothing.
    private var agents: [ExtensionAgentID] { registry.installedAgents }

    private var packages: [ExtensionPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return registry.packages }
        return registry.packages.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            searchField

            let conflicts = SkillAssignment.conflicts(registry.projectBindings)
            if !conflicts.isEmpty {
                SectionCard(
                    title: String(localized: "Clashing assignments"),
                    detail: String(localized: "Both an allow and a deny record exist for the same scope.")
                ) {
                    ForEach(conflicts) { binding in
                        KeyValueRow(
                            key: binding.extensionID,
                            value: binding.isEnabled ? "open" : "off",
                            tint: Theme.warn
                        )
                    }
                }
            }

            SectionCard(
                title: String(localized: "Extension → agent"),
                detail: String(localized: "Which agents an extension is enabled for.")
            ) {
                if agents.isEmpty {
                    EmptyRow(
                        text: String(localized: "No installed agent found; there is nothing to assign to.")
                    )
                } else if packages.isEmpty {
                    EmptyRow(
                        text: registry.packages.isEmpty
                            ? String(localized: "No extensions yet.")
                            : String(localized: "No extension matches “\(query)”.")
                    )
                } else {
                    // A Grid rather than fixed widths: the name column takes what
                    // is left, so the matrix follows the window instead of
                    // spilling out of it.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Extension")
                                .font(Theme.mono(.small, .semibold))
                                .foregroundStyle(Theme.textFaint)
                                .gridColumnAlignment(.leading)
                            ForEach(agents) { agent in
                                Text(agent.displayName)
                                    .font(Theme.mono(.small, .semibold))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineLimit(1)
                                    .frame(width: 110, alignment: .leading)
                            }
                        }
                        .padding(.bottom, 2)

                        ForEach(packages) { package in
                            GridRow {
                                Text(package.name)
                                    .font(Theme.mono(.body))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(agents) { agent in
                                    let isOn = registry.agents(for: package.id).contains(agent)
                                    Button {
                                        registry.setAgentBinding(
                                            !isOn, packageID: package.id, agent: agent
                                        )
                                    } label: {
                                        Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 12))
                                            .foregroundStyle(isOn ? Theme.highlight : Theme.textFaint)
                                            .frame(width: 110, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.pressable)
                                    .accessibilityIdentifier(
                                        "extensions.matrix.\(package.id).\(agent.rawValue)"
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider().overlay(Theme.border)
                    // Wraps instead of running off the edge when several agents
                    // are installed.
                    FlowRow(spacing: 9) {
                        ForEach(agents) { agent in
                            Button("Assign All to \(agent.displayName)") {
                                for package in packages {
                                    registry.setAgentBinding(
                                        true, packageID: package.id, agent: agent
                                    )
                                }
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }

            SectionCard(
                title: String(localized: "Extension → project"),
                detail: String(localized: "With no record an extension is global; the project record, being the most specific, wins.")
            ) {
                if projectStore.projects.isEmpty {
                    EmptyRow(text: String(localized: "No projects yet."))
                } else if packages.isEmpty {
                    EmptyRow(text: String(localized: "No matching extension."))
                } else {
                    ForEach(packages) { package in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(package.name)
                                .font(Theme.mono(.body))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            FlowRow(spacing: 6) {
                                ForEach(projectStore.visibleProjects) { project in
                                    let binding = registry.projectBindings.first {
                                        $0.extensionID == package.id && $0.projectID == project.id
                                    }
                                    Button {
                                        registry.setProjectBinding(ProjectBinding(
                                            extensionID: package.id,
                                            projectID: project.id,
                                            isEnabled: !(binding?.isEnabled ?? true)
                                        ))
                                    } label: {
                                        Text(project.name)
                                            .font(Theme.mono(.small))
                                            .foregroundStyle(
                                                binding == nil
                                                    ? Theme.textFaint
                                                    : (binding!.isEnabled ? Theme.ok : Theme.warn)
                                            )
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    Theme.border, lineWidth: 1
                                                )
                                            )
                                    }
                                    .buttonStyle(.pressable)
                                    .accessibilityIdentifier(
                                        "extensions.projectMatrix.\(package.id).\(project.id.uuidString)"
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TablerIcon(name: "search", size: 12, color: Theme.textFaint)
            TextField("Search this page…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("extensions.assignments.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("extensions.assignments.search.clear")
                Text("\(packages.count)/\(registry.packages.count)")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .panel()
    }
}

/// A row that wraps onto the next line when it runs out of width.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty, next > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = next
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Sources

private struct SourcesScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?
    @State private var newSource = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard(
                title: String(localized: "GitHub sources"),
                detail: String(localized: "Several extensions from the same repo share a single bare mirror.")
            ) {
                HStack(spacing: 9) {
                    TextField("owner/repo", text: $newSource)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.text)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("extensions.sources.add")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                if registry.effectiveSources.isEmpty {
                    Divider().overlay(Theme.border)
                    EmptyRow(text: String(localized: "No source."))
                } else {
                    ForEach(registry.effectiveSources, id: \.self) { repository in
                        Divider().overlay(Theme.border)
                        SourceRow(
                            registry: registry, repository: repository, message: $message
                        )
                    }
                }
            }

            let remote = registry.packages.filter {
                if case .remoteMCP = $0.source { return true }
                return false
            }
            if !remote.isEmpty {
                SectionCard(
                    title: String(localized: "Remote MCP"),
                    detail: String(localized: "No local git: the version comes from the server and is not kept in step with the repo's.")
                ) {
                    ForEach(remote) { package in
                        KeyValueRow(
                            key: package.name,
                            value: package.source.label
                        )
                    }
                }
            }
        }
    }

    private func add() {
        let value = newSource.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        registry.addSource(value)
        newSource = ""
        message = String(localized: "\(value) was added as a source. Adding an extension needs discovery.")
    }
}

private struct SourceRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let repository: String
    @Binding var message: String?
    /// Which retracking sheet is open, if any.
    @State private var retracking: RetrackKind?
    @State private var reference = ""

    enum RetrackKind: String, Identifiable {
        case commit, branch
        var id: String { rawValue }
        var title: String { self == .commit ? String(localized: "Pin to a commit") : String(localized: "Switch branch or tag") }
        var placeholder: String { self == .commit ? String(localized: "commit SHA") : String(localized: "branch or tag name") }
    }

    private var packages: [ExtensionPackage] {
        registry.packages.filter {
            if case .managedGitHub(let value, _, _) = $0.source { return value == repository }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TablerIcon(name: "brand-github", size: 13, color: Theme.textDim)
                Text(repository)
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
                Text(trackingSummary)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text(trustSummary)
                    .font(Theme.mono(.micro, .semibold))
                    .foregroundStyle(packages.isEmpty ? Theme.textFaint : Theme.ok)
            }
            Text(
                packages.isEmpty
                    ? "No extension has been installed from this repo yet."
                    : "Extension: \(packages.map(\.name).joined(separator: ", "))"
            )
            .font(Theme.mono(.small))
            .foregroundStyle(Theme.textDim)
            Text("Last fetch: \(lastFetchSummary)")
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
            HStack(spacing: 9) {
                Button("Fetch Now") {
                    message = fetch()
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.sources.fetch.\(repository)")
                if !packages.isEmpty {
                    Button("Pin Commit…") { retracking = .commit }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.sources.pin.\(repository)")
                    Button("Switch Branch/Tag…") { retracking = .branch }
                        .buttonStyle(GhostButtonStyle())
                }
                Button("Remove Source") {
                    registry.removeSource(repository)
                    message = String(localized: "\(repository) removed; installed extensions were left alone.")
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sheet(item: $retracking) { kind in
            VStack(alignment: .leading, spacing: 12) {
                Text(kind.title)
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(repository) — \(packages.count) extensions will be affected.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textDim)
                TextField(kind.placeholder, text: $reference)
                    .font(Theme.mono(.body))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("extensions.sources.reference")
                HStack(spacing: 9) {
                    Spacer()
                    Button("Cancel") { retracking = nil }
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Apply") { applyTracking(kind) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("extensions.sources.applyTracking")
                }
            }
            .padding(18)
            .frame(width: 420)
            .background(Theme.bg)
        }
    }

    /// The newest fetch across this repository's extensions: what "last fetch"
    /// means for a mirror several extensions share.
    private var lastFetchSummary: String {
        guard let newest = packages.compactMap(\.lastFetchedAt).max() else {
            return "never done"
        }
        return RelativeClock.short(since: newest)
    }

    /// Pinning and moving what is followed are both the user's call, and neither
    /// fetches on its own: the next update check does that.
    private func applyTracking(_ kind: RetrackKind) {
        let value = reference.trimmingCharacters(in: .whitespaces)
        let tracking: ExtensionSource.TrackingMode = kind == .commit
            ? .pinnedCommit(value)
            : (value.first == "v" ? .tag(value) : .branch(value))
        var changed = 0
        for package in packages
        where registry.setTracking(tracking, packageID: package.id) {
            changed += 1
        }
        retracking = nil
        reference = ""
        message = changed == 0
            ? "Tracking is unchanged."
            : "\(changed) extensions now track \(tracking.label)."
    }

    private var trackingSummary: String {
        let modes = packages.compactMap { package -> String? in
            guard case .managedGitHub(_, _, let tracking) = package.source else { return nil }
            return tracking.label
        }
        return Set(modes).sorted().joined(separator: ", ")
    }

    private var trustSummary: String {
        packages.isEmpty ? "unused" : "in use"
    }

    private func fetch() -> String {
        let mirror = ExtensionMirror(layout: registry.layout)
        guard mirror.hasMirror(for: repository) else {
            return "No mirror for \(repository); one appears when an extension is installed."
        }
        do {
            try mirror.fetch(repository: repository)
            return "\(repository) fetched."
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Security

private struct SecurityScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @ObservedObject var scans: BumblebeeScanCoordinator
    @Binding var message: String?
    @EnvironmentObject private var projectStore: ProjectStore
    /// Bumped when the setup section installs a binary, so the cards below it
    /// re-read whether Bumblebee is there.
    @State private var installationToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Shown whether or not it is installed: after a fresh install this is
            // where the version is verified, and re-downloading lives here too.
            BumblebeeSetupSection(
                onChange: { installationToken += 1 },
                onVerify: { await scans.verifyBinary() }
            )

            SectionCard(
                title: String(localized: "Scan"),
                detail: scans.isInstalled
                    ? String(localized: "Bumblebee found; scans are run from here.")
                    : String(localized: "Bumblebee is not installed. Installing it happens with your approval; Uncoil keeps running its own scan.")
            ) {
                KeyValueRow(
                    key: "Last Bumblebee scan",
                    value: registry.lastBumblebeeScanAt
                        .map { RelativeClock.short(since: $0) } ?? "never",
                    tint: registry.lastBumblebeeScanAt == nil ? Theme.textFaint : nil
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Binary",
                    value: registry.bumblebeeVersion?.label ?? "unknown"
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Self-test",
                    value: registry.bumblebeeSelfTest.map {
                        $0.passed ? "passed" : "failed: \($0.detail)"
                    } ?? "did not run",
                    tint: registry.bumblebeeSelfTest?.passed == false ? Theme.danger : nil
                )
                Divider().overlay(Theme.border)
                FlowRow(spacing: 9) {
                    Button(scans.isScanning ? "Scanning…" : "Manual scan") {
                        Task { message = await scans.scanManually().message }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(scans.isScanning)
                    .accessibilityIdentifier("extensions.security.manualScan")

                    Button("Project Scan") {
                        let roots = projectStore.visibleProjects.map(\.rootPath)
                        Task { message = await scans.scanProjects(roots: roots).message }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(scans.isScanning)

                    Button("Deep Scan") {
                        Task { message = await scans.deepScan().message }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(scans.isScanning)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .task {
                // At launch: only when the last scan is old enough to redo.
                _ = await scans.scanAtLaunchIfStale()
                _ = await scans.scanDailyBaselineIfDue()
            }

            SectionCard(
                title: String(localized: "Coverage"),
                detail: String(localized: "A clean result does not mean the extension is entirely safe.")
            ) {
                KeyValueRow(
                    key: "Uncoil scan",
                    value: "File, command and instruction analysis runs."
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Bumblebee",
                    value: registry.findings.contains { $0.origin == .bumblebee }
                        ? "The last result is below"
                        : "Never run",
                    tint: Theme.textDim
                )
                Divider().overlay(Theme.border)
                ForEach(BumblebeeCoverage.all) { gap in
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Not covered by Bumblebee",
                        value: "\(gap.message) \(gap.remedy)",
                        tint: Theme.warn
                    )
                }
            }

            ForEach([SecurityFinding.Origin.uncoil, .bumblebee], id: \.rawValue) { origin in
                let originFindings = registry.findings.filter { $0.origin == origin }
                SectionCard(
                    title: String(localized: "\(origin.label) findings"),
                    detail: String(localized: "Sources are shown separately; they are not merged.")
                ) {
                    if originFindings.isEmpty {
                        EmptyRow(
                            text: origin == .bumblebee
                                ? String(localized: "Bumblebee did not run.")
                                : String(localized: "No open findings.")
                        )
                    } else if origin == .bumblebee {
                        // Grouped by kind: an inventory line and a malicious
                        // version are not the same kind of news.
                        let summary = BumblebeeFindingSummary(findings: originFindings)
                        Text(summary.caption(
                            scanned: registry.packages.count
                        ))
                        .font(Theme.ui(.small))
                        .foregroundStyle(summary.hasParserDiagnostics ? Theme.warn : Theme.textFaint)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        ForEach(summary.kinds) { kind in
                            Divider().overlay(Theme.border)
                            HStack(spacing: 7) {
                                StatusBadge(
                                    text: kind.label,
                                    level: kind.isActionable ? .warning : .neutral
                                )
                                Text(kind.remedy)
                                    .font(Theme.ui(.micro))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            ForEach(summary.byKind[kind] ?? []) { finding in
                                FindingRow(registry: registry, finding: finding)
                            }
                        }
                    } else {
                        ForEach(Array(originFindings.enumerated()), id: \.element.id) { index, finding in
                            FindingRow(registry: registry, finding: finding)
                            if index != originFindings.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                }
            }

            let quarantined = registry.packages.filter { $0.state == .quarantined }
            if !quarantined.isEmpty {
                SectionCard(
                    title: String(localized: "Quarantine"),
                    detail: String(localized: "No file was deleted; the launcher refuses to start.")
                ) {
                    ForEach(quarantined) { package in
                        HStack {
                            Text(package.name)
                                .font(Theme.mono(.body))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Button("Restore") {
                                registry.setState(.active, packageID: package.id)
                                message = String(localized: "\(package.name) restored.")
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }
}

private struct FindingRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let finding: SecurityFinding

    private var color: Color {
        switch finding.severity {
        case .blocked, .high: Theme.danger
        case .needsReview: Theme.warn
        case .low, .info: Theme.textDim
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TablerIcon(name: "shield-lock", size: 13, color: color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(finding.severity.label)
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(color)
                    Text(finding.rule)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                    if finding.isAccepted {
                        Text("accepted")
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                Text(finding.message)
                    .font(Theme.ui(.body))
                    .foregroundStyle(Theme.text)
                if let path = finding.path {
                    Text(path)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            if !finding.isAccepted {
                Button("Accept") {
                    registry.acceptFinding(id: finding.id)
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.finding.accept.\(finding.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Updates

private struct UpdatesScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?
    /// Reviews the user has looked at, so "Update all reviewed" means exactly
    /// that and nothing else.
    @State private var reviewed: Set<String> = []
    @State private var reviews: [String: UpdateReview] = [:]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if registry.updateCandidates.isEmpty {
                SectionCard(title: String(localized: "No update")) {
                    EmptyRow(
                        text: registry.managedPackages.isEmpty
                            ? String(localized: "No managed extension; unmanaged packages are not checked for updates.")
                            : String(localized: "No new commit since the last scan.")
                    )
                }
            }

            ForEach(registry.updateCandidates) { candidate in
                let package = registry.package(id: candidate.extensionID)
                SectionCard(title: package?.name ?? candidate.extensionID) {
                    KeyValueRow(
                        key: "Installed commit",
                        value: candidate.installedCommitSHA?.prefix(12).description ?? "—"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Available commit",
                        value: candidate.availableCommitSHA.prefix(12).description,
                        tint: Theme.highlight
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Commits", value: "\(candidate.commitCount)")
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Changed files",
                        value: candidate.changedFiles.isEmpty
                            ? "—"
                            : candidate.changedFiles.joined(separator: ", ")
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Changelog",
                        value: candidate.changelog ?? "—"
                    )
                    let review = reviews[candidate.extensionID]
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Security diff",
                        value: review.map { current in
                            current.securityDiff.isEmpty
                                ? "No new findings"
                                : current.securityDiff
                                    .map { "\($0.severity.label): \($0.rule)" }
                                    .joined(separator: ", ")
                        } ?? "Not reviewed yet",
                        tint: (review?.securityDiff.contains { $0.severity >= .high } ?? false)
                            ? Theme.danger : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "New permissions",
                        value: review.map {
                            $0.addedPermissions.isEmpty ? "—" : $0.addedPermissions.joined(separator: ", ")
                        } ?? "—",
                        tint: (review?.addedPermissions.isEmpty == false) ? Theme.warn : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "New tools",
                        value: review.map {
                            $0.addedTools.isEmpty ? "—" : $0.addedTools.joined(separator: ", ")
                        } ?? "—"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Removed tools",
                        value: review.map {
                            $0.removedTools.isEmpty ? "—" : $0.removedTools.joined(separator: ", ")
                        } ?? "—",
                        tint: (review?.removedTools.isEmpty == false) ? Theme.danger : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Breaking-change ihtimali",
                        value: review?.breakingChangeRisk.label ?? "incelenmedi",
                        tint: review?.breakingChangeRisk == .likely ? Theme.danger : nil
                    )
                    Divider().overlay(Theme.border)
                    FlowRow(spacing: 9) {
                        Button(reviewed.contains(candidate.extensionID) ? "Reviewed ✓" : "Review") {
                            makeReview(candidate, package: package)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.update.review.\(candidate.extensionID)")

                        Button("Update Selected") {
                            message = apply(candidate, package: package)
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(package == nil)
                        .accessibilityIdentifier("extensions.update.apply.\(candidate.extensionID)")

                        Button("Rollback") {
                            message = rollback(package)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(package?.previousRevision == nil)

                        Button("Rollback History") {
                            message = rollbackHistory(package)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }

            if !registry.updateCandidates.isEmpty {
                HStack(spacing: 9) {
                    Button("Update All Reviewed") { updateAllReviewed() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(reviewed.isEmpty)
                        .accessibilityIdentifier("extensions.update.applyReviewed")
                    Text("\(reviewed.count) reviewed")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
            }

            SectionCard(
                title: String(localized: "Rollback history"),
                detail: String(localized: "The previous revision is kept; rollback returns to it with one click.")
            ) {
                let withPrevious = registry.packages.filter { $0.previousRevision != nil }
                if withPrevious.isEmpty {
                    EmptyRow(text: String(localized: "No update applied yet."))
                } else {
                    ForEach(withPrevious) { package in
                        KeyValueRow(
                            key: package.name,
                            value: "previous: \(package.previousRevision?.commitSHA?.prefix(12) ?? "—")"
                        )
                    }
                }
            }
        }
    }

    /// Computes what the update would change. Nothing is applied.
    private func makeReview(_ candidate: UpdateCandidate, package: ExtensionPackage?) {
        guard let package, let active = package.activeRevision else {
            message = String(localized: "No revision of this package is installed; install it first.")
            return
        }
        let staging = registry.layout.revisions
            .appendingPathComponent(candidate.availableCommitSHA, isDirectory: true)
        reviews[candidate.extensionID] = UpdateReview.between(
            previous: URL(fileURLWithPath: active.path),
            next: FileManager.default.fileExists(atPath: staging.path)
                ? staging
                : URL(fileURLWithPath: active.path),
            candidate: candidate,
            extensionID: package.id
        )
        reviewed.insert(candidate.extensionID)
    }

    private func apply(_ candidate: UpdateCandidate, package: ExtensionPackage?) -> String {
        guard let package else { return "Package not found." }
        let engine = updateEngine()
        do {
            let staged = try engine.stage(candidate, package: package)
            let updated = try engine.activate(
                staged, package: package, skillName: package.name
            )
            registry.upsert(updated)
            registry.record(AuditEvent(
                kind: .updateApplied, extensionID: package.id,
                detail: String(localized: "Updated to \(candidate.availableCommitSHA.prefix(12))")
            ))
            registry.discover()
            return "\(package.name) updated."
        } catch {
            return "No update was made: \(error.localizedDescription)"
        }
    }

    private func rollback(_ package: ExtensionPackage?) -> String {
        guard let package, package.previousRevision != nil else {
            return "No previous revision to fall back to."
        }
        let engine = updateEngine()
        do {
            let restored = try engine.rollback(package, skillName: package.name).package
            registry.upsert(restored)
            registry.record(AuditEvent(
                kind: .rolledBack, extensionID: package.id,
                detail: String(localized: "went back to the previous revision")
            ))
            registry.discover()
            return "\(package.name) went back to its previous revision."
        } catch {
            return "No rollback was made: \(error.localizedDescription)"
        }
    }

    /// Applies only what the user actually reviewed, and says what it skipped.
    private func updateAllReviewed() {
        var applied: [String] = []
        var failed: [String] = []
        for candidate in registry.updateCandidates
        where reviewed.contains(candidate.extensionID) {
            let package = registry.package(id: candidate.extensionID)
            let result = apply(candidate, package: package)
            if result.contains("updated") {
                applied.append(package?.name ?? candidate.extensionID)
            } else {
                failed.append(package?.name ?? candidate.extensionID)
            }
        }
        let skipped = registry.updateCandidates
            .filter { !reviewed.contains($0.extensionID) }
            .count
        var parts: [String] = []
        if !applied.isEmpty { parts.append("updated: \(applied.joined(separator: ", "))") }
        if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: ", "))") }
        if skipped > 0 { parts.append("\(skipped) packages skipped because they were not reviewed") }
        message = parts.isEmpty ? "No reviewed package to update." : parts.joined(separator: " · ")
        reviewed.removeAll()
    }

    /// The engine, wired to Uncoil's own store and to the real scanner.
    private func updateEngine() -> ExtensionUpdateEngine {
        ExtensionUpdateEngine(
            mirror: ExtensionMirror(layout: registry.layout),
            store: SkillStore(layout: registry.layout),
            scan: { root in
                ExtensionSecurityScanner.scan(packageAt: root).findings
            }
        )
    }

    private func rollbackHistory(_ package: ExtensionPackage?) -> String {
        guard let package else { return "Package not found." }
        guard let previous = package.previousRevision else {
            return "There is no earlier revision of \(package.name)."
        }
        return "\(package.name)'s previous revision: \(previous.commitSHA ?? previous.id)"
    }
}

// MARK: - Activity

private struct ActivityScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?

    var body: some View {
        SectionCard(
            title: String(localized: "Activity"),
            detail: String(localized: "Append-only record; survives even if the registry is corrupted.")
        ) {
            if registry.auditEvents.isEmpty {
                EmptyRow(text: String(localized: "No records yet."))
            } else {
                ForEach(Array(registry.auditEvents.prefix(100).enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(event.kind.label)
                                    .font(Theme.mono(.body, .semibold))
                                    .foregroundStyle(Theme.text)
                                if let extensionID = event.extensionID {
                                    Text(extensionID)
                                        .font(Theme.mono(.small))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                if let agent = event.agent {
                                    Text(agent.displayName)
                                        .font(Theme.mono(.small))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                            Text(event.detail)
                                .font(Theme.ui(.small))
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Text(RelativeClock.short(since: event.at))
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                        if ExtensionRegistry.isUndoable(event) {
                            Button("Undo") {
                                message = registry.undo(event) ?? "This cannot be undone."
                            }
                            .buttonStyle(GhostButtonStyle())
                            .font(Theme.mono(.micro))
                            .accessibilityIdentifier("extensions.activity.undo.\(event.id.uuidString)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if index != min(registry.auditEvents.count, 100) - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
        .accessibilityIdentifier("extensions.activity.list")
    }
}

// MARK: - Window frame

private struct ExtensionsWindowFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            _ = window.setFrameUsingName("UncoilExtensionsWindow", force: true)
            window.setFrameAutosaveName("UncoilExtensionsWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
