import AppKit
import SwiftUI

struct ExtensionsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview
        case agents
        case skills
        case mcpServers
        case assignments
        case sources
        case security
        case updates
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .agents: "Agents"
            case .skills: "Skills"
            case .mcpServers: "MCP Servers"
            case .assignments: "Assignments"
            case .sources: "Sources"
            case .security: "Security"
            case .updates: "Updates"
            case .activity: "Activity"
            }
        }

        var iconName: String {
            switch self {
            case .overview: "layout-dashboard"
            case .agents: "robot"
            case .skills: "sparkles"
            case .mcpServers: "server"
            case .assignments: "arrows-exchange"
            case .sources: "database"
            case .security: "shield-lock"
            case .updates: "refresh"
            case .activity: "activity"
            }
        }

        var description: String {
            switch self {
            case .overview: "Agent extension sisteminin genel durumu"
            case .agents: "Kurulu agent’lar ve profilleri"
            case .skills: "Kullanılabilir skill paketleri"
            case .mcpServers: "MCP server tanımları ve durumları"
            case .assignments: "Agent ve proje atamaları"
            case .sources: "Extension kaynakları"
            case .security: "Güvenlik bulguları ve karantina"
            case .updates: "Paket güncellemeleri"
            case .activity: "Extension etkinlik geçmişi"
            }
        }
    }

    @EnvironmentObject private var projectStore: ProjectStore
    @StateObject private var registry = {
        let registry = ExtensionRegistry()
        // The shared lock file lives in the user's home; a test-made registry
        // never gets one, which is why this is set here rather than defaulted.
        registry.skillLockHome = LaunchConfig.shared.isUITesting
            ? nil
            : FileManager.default.homeDirectoryForCurrentUser
        return registry
    }()
    @State private var selection: Section = .overview
    @State private var selectedPackageID: String?
    @State private var message: String?

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
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 42)
            Text("EXTENSIONS")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ForEach(Section.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 9) {
                        TablerIcon(
                            name: section.iconName,
                            size: 13,
                            color: selection == section ? Theme.text : Theme.textDim
                        )
                        Text(section.title)
                            .font(Theme.mono(11.5, selection == section ? .semibold : .regular))
                            .foregroundStyle(selection == section ? Theme.text : Theme.textDim)
                        Spacer()
                        if let badge = badge(for: section) {
                            Text("\(badge.count)")
                                .font(Theme.mono(9.5, .semibold))
                                .foregroundStyle(Theme.bg)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(badge.color, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(
                        selection == section ? Theme.panelActive : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("extensions.section.\(section.rawValue)")
            }

            Spacer()

            Button {
                registry.discover()
                message = "Health check çalıştı."
            } label: {
                HStack(spacing: 7) {
                    TablerIcon(name: "stethoscope", size: 12, color: Theme.text)
                    Text("Run Health Check")
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .accessibilityIdentifier("extensions.runHealthCheck")
        }
        .padding(.horizontal, 8)
        .frame(width: 196)
        .background(Theme.panel.opacity(0.35))
    }

    private func badge(for section: Section) -> (count: Int, color: Color)? {
        switch section {
        case .updates:
            registry.updateCandidates.isEmpty ? nil : (registry.updateCandidates.count, Theme.codex)
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
                    Text(selection.title)
                        .font(Theme.mono(18, .bold))
                        .foregroundStyle(Theme.text)
                    Text(selection.description)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if let lastDiscoveryAt = registry.lastDiscoveryAt {
                    Text("Son tarama \(RelativeClock.short(since: lastDiscoveryAt))")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            if let message {
                HStack(spacing: 8) {
                    TablerIcon(name: "info-circle", size: 12, color: Theme.codex)
                    Text(message)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Button {
                        self.message = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                .accessibilityIdentifier("extensions.message")
            }

            ScrollView {
                screen
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .uncoilScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.content.\(selection.rawValue)")
    }

    @ViewBuilder
    private var screen: some View {
        switch selection {
        case .overview:
            OverviewScreen(registry: registry)
        case .agents:
            AgentsScreen(registry: registry, message: $message)
        case .skills:
            PackagesScreen(
                registry: registry, kind: .skill,
                selectedPackageID: $selectedPackageID, message: $message
            )
        case .mcpServers:
            PackagesScreen(
                registry: registry, kind: .mcpServer,
                selectedPackageID: $selectedPackageID, message: $message
            )
        case .assignments:
            AssignmentsScreen(registry: registry)
        case .sources:
            SourcesScreen(registry: registry, message: $message)
        case .security:
            SecurityScreen(registry: registry, message: $message)
        case .updates:
            UpdatesScreen(registry: registry, message: $message)
        case .activity:
            ActivityScreen(registry: registry, message: $message)
        }
    }
}

// MARK: - Shared pieces

private struct StatTile: View {
    let label: String
    let value: String
    var tint: Color?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.mono(20, .bold))
                .foregroundStyle(tint ?? Theme.text)
            Text(label)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
            if let detail {
                Text(detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
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
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(Theme.mono(10.5))
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
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textDim)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(isMonospacedValue ? Theme.mono(11) : Theme.mono(11, .medium))
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
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                Text(result.detail)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                if let remedy = result.remedy {
                    Text(remedy)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            Text(result.outcome.label)
                .font(Theme.mono(10, .semibold))
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
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
    }
}

private struct SourceBadge: View {
    let source: ExtensionSource

    private var tint: Color {
        source.isManaged ? Theme.codex : (source.isOwnedByUncoil ? Theme.ok : Theme.textFaint)
    }

    var body: some View {
        Text(source.isManaged ? "Managed" : (source.isOwnedByUncoil ? "Bundled" : "Unmanaged"))
            .font(Theme.mono(9, .semibold))
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
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                StatTile(
                    label: "Kurulu agent",
                    value: "\(overview.agents.count)",
                    detail: overview.agents.isEmpty ? "Bulunamadı" : overview.agents.joined(separator: ", ")
                )
                StatTile(label: "Managed skill", value: "\(overview.managedSkills)")
                StatTile(
                    label: "Unmanaged skill",
                    value: "\(overview.unmanagedSkills)",
                    detail: "Uncoil dışında kurulmuş"
                )
                StatTile(label: "MCP server", value: "\(overview.mcpServers)")
                StatTile(
                    label: "Güncelleme bekleyen",
                    value: "\(overview.pendingUpdates)",
                    tint: overview.pendingUpdates > 0 ? Theme.codex : nil
                )
                StatTile(
                    label: "Bozuk extension",
                    value: "\(overview.brokenExtensions)",
                    tint: overview.brokenExtensions > 0 ? Theme.danger : nil
                )
                StatTile(
                    label: "Security finding",
                    value: "\(overview.openFindings)",
                    tint: overview.openFindings > 0 ? Theme.danger : nil
                )
                StatTile(
                    label: "Config drift",
                    value: "\(overview.configDrift)",
                    tint: overview.configDrift > 0 ? Theme.warn : nil
                )
                StatTile(
                    label: "Son Bumblebee scan",
                    value: overview.lastBumblebeeScan
                        .map { RelativeClock.short(since: $0) } ?? "—",
                    detail: overview.bumblebeeSummary ?? "Hiç çalıştırılmadı"
                )
            }
            .accessibilityIdentifier("extensions.overview.tiles")

            SectionCard(title: "Health check") {
                if registry.health.isEmpty {
                    EmptyRow(text: "Henüz çalıştırılmadı.")
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
                    title: "Agent config uyarıları",
                    detail: "Uncoil bu dosyaları yalnızca plan → apply ile değiştirir."
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
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.text)
                                if let remedy = issue.remedy {
                                    Text(remedy)
                                        .font(Theme.mono(10))
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
                SectionCard(title: "Agent bulunamadı") {
                    EmptyRow(text: "Claude Code veya Codex kurulu değil.")
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
                    KeyValueRow(key: "Kurulum yolu", value: installation.binaryPath)
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Binary sürümü",
                        value: installation.version
                            ?? versions[installation.agent]
                            ?? "sorgulanmadı"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Aktif profil", value: activeProfile(installation.agent))
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Update durumu",
                        value: updateStatus(installation.agent),
                        tint: registry.updateCandidates.isEmpty ? nil : Theme.codex
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Login durumu",
                        value: installation.isAuthenticated
                            .map { $0 ? "Giriş yapılmış" : "Giriş gerekli" } ?? "bilinmiyor",
                        tint: installation.isAuthenticated == false ? Theme.warn : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Config dizini", value: installation.configDirectory)
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "MCP config",
                        value: installation.mcpConfigPath ?? "yok"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Skill dizini",
                        value: installation.skillsDirectory ?? "yok"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Son doğrulama",
                        value: registry.lastDiscoveryAt
                            .map { RelativeClock.short(since: $0) } ?? "—"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Tanımlı MCP",
                        value: "\(configuration?.mcpServers.count ?? 0)"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Görünen skill",
                        value: configuration?.skillNames.joined(separator: ", ") ?? "—"
                    )

                    Divider().overlay(Theme.border)
                    HStack(spacing: 9) {
                        Button("Validate") {
                            registry.discover()
                            let issues = registry.configurationIssues.count
                            message = issues == 0
                                ? "\(installation.agent.displayName) config'i geçerli."
                                : "\(issues) uyarı bulundu; Overview'da listelendi."
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.validate.\(installation.agent.rawValue)")

                        Button("Repair") {
                            message = repairLinks(installation)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.repair.\(installation.agent.rawValue)")

                        Button("Export setup") {
                            message = exportSetup(installation)
                        }
                        .buttonStyle(GhostButtonStyle())

                        Button("Import setup") {
                            importSetup(installation)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.agent.import.\(installation.agent.rawValue)")

                        Button("Config'i Göster") {
                            guard let path = installation.mcpConfigPath else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: path),
                            ])
                        }
                        .buttonStyle(GhostButtonStyle())
                        Spacer()
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
                                    color: server.isEnabled ? Theme.codex : Theme.textFaint
                                )
                                Text(server.name)
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(Theme.text)
                                Text(server.transport.rawValue)
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.textFaint)
                                Spacer()
                                Button(server.isEnabled ? "Kapat" : "Aç") {
                                    planChange(
                                        [.setMCPServerEnabled(
                                            name: server.name, isEnabled: !server.isEnabled
                                        )],
                                        installation: installation,
                                        summary: server.isEnabled
                                            ? "\(server.name) kapatılıyor"
                                            : "\(server.name) açılıyor"
                                    )
                                }
                                .buttonStyle(GhostButtonStyle())
                                .font(Theme.mono(9.5))
                                .accessibilityIdentifier(
                                    "extensions.mcp.toggle.\(installation.agent.rawValue).\(server.name)"
                                )
                                Button("Kaldır") {
                                    planChange(
                                        [.removeMCPServer(name: server.name)],
                                        installation: installation,
                                        summary: "\(server.name) kaldırılıyor"
                                    )
                                }
                                .buttonStyle(GhostButtonStyle())
                                .font(Theme.mono(9.5))
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
                                "Son değişiklik "
                                    + (candidate.appliedAt.map {
                                        RelativeClock.short(since: $0)
                                    } ?? "bilinmiyor")
                            )
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textDim)
                            Spacer()
                            Button("Önceki config'e dön") {
                                message = rollback(candidate, installation: installation)
                            }
                            .buttonStyle(GhostButtonStyle())
                            .font(Theme.mono(9.5))
                            .accessibilityIdentifier(
                                "extensions.config.rollback.\(installation.agent.rawValue)"
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }

            if !AgentAdapterRegistry().unmanagedAgents.isEmpty {
                SectionCard(
                    title: "Henüz yönetilmeyen agent'lar",
                    detail: "Adapter geldiğinde bu ekranda görünecekler."
                ) {
                    ForEach(AgentAdapterRegistry().unmanagedAgents) { agent in
                        KeyValueRow(key: agent.displayName, value: "adapter yok")
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
                versions[installation.agent] = version ?? "okunamadı"
            }
        }
    }

    /// The preset Uncoil would launch this agent with. "Profile" is that preset
    /// plus the permission mode it carries.
    private func activeProfile(_ agent: ExtensionAgentID) -> String {
        guard let provider = agent.provider else { return "Uncoil bu agent'ı başlatmıyor" }
        guard let preset = settings.presets.first(where: { $0.provider == provider }) else {
            return "preset yok"
        }
        return "\(preset.name) · \(preset.grantedCapabilities.count) yetki"
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
                : "extension'lar güncel"
        }
        return "\(pending.count) extension güncellenebilir"
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
            message = "Setup dosyası okunamadı."
            return
        }
        guard let servers = root["mcp_servers"] as? [[String: String]], !servers.isEmpty else {
            message = "Setup dosyasında MCP server yok."
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
            message = "Setup dosyasındaki sunucular okunamadı."
            return
        }
        planChange(
            changes, installation: installation,
            summary: "\(changes.count) MCP server içe alınıyor"
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
                    pending.summary + " (config dışarıdan değişti, yeniden planlandı)",
                    outcome.issues
                )
                message = "Config dışarıdan değişmiş; plan yeniden hesaplandı."
                return
            }
            message = outcome.didApply
                ? "\(pending.summary): uygulandı."
                : (outcome.transaction.failureReason ?? "Değişiklik uygulanamadı.")
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
                return outcome.transaction.failureReason ?? "Geri alınamadı."
            }
            let errors = outcome.issues.filter { $0.severity == .error }
            return errors.isEmpty
                ? "Önceki config geri yüklendi."
                : "Config geri yüklendi ama \(errors.count) hata var: \(errors[0].message)"
        } catch {
            return error.localizedDescription
        }
    }

    private func capabilitySummary(_ agent: ExtensionAgentID) -> String {
        guard let capabilities = AgentAdapterRegistry().adapter(for: agent)?.capabilities else {
            return "adapter yok"
        }
        var parts: [String] = []
        if capabilities.supportsPerSkillSymlinks { parts.append("skill başına symlink") }
        if capabilities.supportsStdioMCP { parts.append("STDIO MCP") }
        if capabilities.supportsHTTPMCP { parts.append("HTTP MCP") }
        if capabilities.supportsProjectScopedMCP { parts.append("proje bazlı MCP") }
        parts.append(
            capabilities.reloadsConfigWithoutRestart
                ? "config'i canlı okur"
                : "config için restart gerekir"
        )
        if capabilities.reportsAuthenticationState { parts.append("giriş durumunu bildirir") }
        return parts.joined(separator: " · ")
    }

    private func repairLinks(_ installation: AgentInstallation) -> String {
        guard let directory = installation.skillsDirectory.map({ URL(fileURLWithPath: $0) }) else {
            return "\(installation.agent.displayName) skill dizini yok."
        }
        let store = SkillStore(layout: registry.layout)
        var repaired: [String] = []
        var skipped: [String] = []
        for package in registry.skills where package.source.isOwnedByUncoil {
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
        if repaired.isEmpty && skipped.isEmpty { return "Onarılacak bağlantı yok." }
        var text = repaired.isEmpty ? "" : "Onarıldı: \(repaired.joined(separator: ", "))."
        if !skipped.isEmpty {
            text += " Dokunulmadı (kullanıcı dosyası): \(skipped.joined(separator: ", "))."
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
        ) else { return "Export hazırlanamadı." }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-\(installation.agent.rawValue)-setup.json")
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Export yazıldı (secret değerleri dahil edilmedi): \(url.lastPathComponent)"
    }
}

// MARK: - Skills and MCP servers

private struct PackagesScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    let kind: ExtensionKind
    @Binding var selectedPackageID: String?
    @Binding var message: String?

    private var packages: [ExtensionPackage] {
        registry.packages.filter { $0.kind == kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if kind == .skill {
                TriggerTesterCard(registry: registry)
            }

            if packages.isEmpty {
                SectionCard(title: "\(kind.label) bulunamadı") {
                    EmptyRow(
                        text: kind == .skill
                            ? "Agent'ların skill dizinlerinde bir şey görünmüyor."
                            : "Agent config'lerinde MCP server tanımlı değil."
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
                diff: registry.logTail(for: package) ?? "Log yok.",
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
            adoption = try service.plan(
                name: package.name, kind: package.kind, externalPath: path,
                findings: findings
            )
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
            registry.upsert(adopted)
            registry.record(AuditEvent(
                kind: package.kind == .skill ? .skillInstalled : .mcpEnabled,
                extensionID: adopted.id,
                detail: "sahiplenildi: \(plan.summary), yedek \(plan.backupPath ?? "-")"
            ))
            message = "\(package.name) sahiplenildi; \(plan.summary)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func linkToRepository(_ repository: String, tracking: ExtensionSource.TrackingMode) {
        linkingRepository = nil
        guard let source = package.source.linkedToRepository(repository, tracking: tracking) else {
            message = "\(package.name) bir depoya bağlanamaz."
            return
        }
        var updated = package
        updated.source = source
        registry.upsert(updated)
        registry.record(AuditEvent(
            kind: .configChanged, extensionID: package.id,
            detail: "kaynak bağlandı: \(repository) · \(tracking.label)"
        ))
        message = "\(package.name) artık \(repository) kaynağından yönetiliyor."
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
                            .font(Theme.mono(12.5, .semibold))
                            .foregroundStyle(Theme.text)
                        SourceBadge(source: package.source)
                        if package.state != .active {
                            StatusBadge(
                                text: package.state.label,
                                level: package.state == .quarantined ? .danger : .warning
                            )
                        }
                        if package.hasLocalModification {
                            StatusBadge(text: "Modified Locally", level: .warning)
                        }
                        if let coverage = BumblebeeCoverage.label(for: package) {
                            StatusBadge(text: coverage, level: .neutral)
                        }
                    }
                    Text(package.summary ?? package.source.label)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                Spacer()
                if candidate != nil {
                    Text("update")
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(Theme.codex)
                }
                if let highest = findings.filter({ !$0.isAccepted }).map(\.severity).max() {
                    Text(highest.label)
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(highest >= .high ? Theme.danger : Theme.warn)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeyValueRow(key: "Kaynak", value: package.source.label)
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Yönetim",
                value: package.source.isOwnedByUncoil ? "Uncoil yönetiyor" : "Unmanaged",
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
                    ? (candidate?.availableCommitSHA.prefix(12).description ?? "güncel")
                    : "kapsam dışı",
                tint: candidate == nil ? nil : Theme.codex
            )
            Divider().overlay(Theme.border)
            KeyValueRow(
                key: "Agent atamaları",
                value: registry.agents(for: package.id).isEmpty
                    ? "—"
                    : registry.agents(for: package.id).map(\.displayName).joined(separator: ", ")
            )
            Divider().overlay(Theme.border)
            KeyValueRow(key: "Proje atamaları", value: projectAssignmentSummary)
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
                        ?? "hiç çalıştırılmadı"
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
                    key: "Dosyalar",
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
                    ? "Bulgu yok (tarama kapsamı sınırlı)"
                    : findings.map { "\($0.severity.label): \($0.rule)" }.joined(separator: ", "),
                tint: findings.contains { $0.severity >= .high && !$0.isAccepted } ? Theme.danger : nil
            )

            Divider().overlay(Theme.border)
            actions
        }
    }

    private var processStateLabel: String {
        registry.processHealth[package.id]?.state.label ?? "bilinmiyor"
    }

    /// Prompts and resources the server reports having. Absent when nothing has
    /// asked it yet — not the same as "it has none".
    private var promptResourceSummary: String {
        let reported = registry.reportedCapabilities[package.id] ?? []
        guard !reported.isEmpty else { return "sunucu bildirmedi" }
        let interesting = reported.filter { $0 == "prompts" || $0 == "resources" }
        return interesting.isEmpty ? "yok" : interesting.joined(separator: ", ")
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
            return "Güncelleme yok."
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
                detail: "\(candidate.availableCommitSHA.prefix(12)) sürümüne güncellendi"
            ))
            if let activePath = updated.activeRevision?.path {
                Task { _ = await coordinator.scanAfterUpdate(activePath: activePath) }
            }
            registry.discover()
            return "\(package.name) güncellendi."
        } catch {
            return "Güncelleme yapılmadı: \(error.localizedDescription)"
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
                kind: .rolledBack, extensionID: package.id, detail: "önceki revizyona dönüldü"
            ))
            registry.discover()
            return "\(package.name) önceki revizyona döndü."
        } catch {
            return "Rollback yapılmadı: \(error.localizedDescription)"
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
            return binding.isEnabled ? scope : "\(scope) (kapalı)"
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
            return "Secret gerekiyor: \(server.environmentKeys.joined(separator: ", "))"
        }
        if case .remoteMCP = package.source {
            return "Sunucu tarafında yönetiliyor"
        }
        return "Secret gerekmiyor"
    }

    private var toolSummary: String {
        guard let server = registry.configurations
            .flatMap(\.mcpServers)
            .first(where: { $0.name == package.name }) else { return "—" }
        return server.reportedTools.isEmpty
            ? "Handshake yapılmadı"
            : server.reportedTools.joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: 9) {
            // An external install Uncoil did not adopt is shown, not wired up:
            // assigning it would mean managing files that are not ours.
            if package.source.capabilities.canAssign {
                ForEach(ExtensionAgentID.supported) { agent in
                    let isOn = registry.agents(for: package.id).contains(agent)
                    Button(isOn ? "\(agent.displayName): açık" : "\(agent.displayName): kapalı") {
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
                Button("GitHub kaynağına bağla…") { linkingRepository = "" }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("extensions.package.link.\(package.id)")
            }

            if package.state == .quarantined {
                Button("Karantinadan Çıkar") {
                    message = registry.restoreFromQuarantine(packageID: package.id)
                        ? "\(package.name) geri yüklendi ve yeniden bağlandı."
                        : "\(package.name) geri yüklenemedi."
                }
                .buttonStyle(AccentButtonStyle())
            } else {
                Button("Quarantine") {
                    let outcome = registry.quarantine(
                        packageID: package.id,
                        reason: findings.first?.rule ?? "kullanıcı isteği",
                        findingID: findings.first?.id
                    )
                    message = "\(package.name): \(outcome.summary)"
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.quarantine.\(package.id)")
            }

            if let path = package.activeRevision?.path {
                Button("Inspect files") {
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
                        ? "Çalışan süreç yoktu; agent bir sonraki çağrıda yenisini başlatır."
                        : "\(stopped) süreç durduruldu; agent yenisini başlatacak."
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.restart.\(package.id)")
            }

            if package.source.isOwnedByUncoil {
                Button("Uninstall") {
                    registry.remove(packageID: package.id)
                    registry.record(AuditEvent(
                        kind: package.kind == .skill ? .skillRemoved : .mcpDisabled,
                        extensionID: package.id, detail: "kaldırıldı"
                    ))
                    message = "\(package.name) kaldırıldı."
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.package.uninstall.\(package.id)")
            }
            Spacer()
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
            title: "Trigger Tester",
            detail: "Bir prompt'un hangi skill'i tetikleyebileceğini, agent'ın gördüğü açıklamalardan tahmin eder."
        ) {
            HStack(spacing: 9) {
                TextField("Örnek prompt yaz…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .onSubmit(run)
                    .accessibilityIdentifier("extensions.trigger.prompt")
                Button("Test et", action: run)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("extensions.trigger.run")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                Toggle("Test geçmişini sakla", isOn: $history.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                    .accessibilityIdentifier("extensions.trigger.keepHistory")
                Spacer()
                if !history.entries.isEmpty {
                    Text("\(history.entries.count) kayıt")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                    Button("Geçmişi sil") { history.clear() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !results.isEmpty {
                Divider().overlay(Theme.border)
                Text("\(candidateCount) skill açıklaması yüklendi")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(result.agent.displayName)
                                .font(Theme.mono(11, .semibold))
                                .foregroundStyle(Theme.text)
                            Text(result.verdict.label)
                                .font(Theme.mono(10, .semibold))
                                .foregroundStyle(verdictColor(result.verdict))
                        }
                        Text(result.verdict.advice)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textDim)
                        ForEach(result.matches) { match in
                            Text("· \(match.candidate.name) — \(Int(match.score * 100))% · \(match.matchedTerms.prefix(4).joined(separator: ", "))")
                                .font(Theme.mono(10))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            let conflicts = SkillAssignment.conflicts(registry.projectBindings)
            if !conflicts.isEmpty {
                SectionCard(
                    title: "Çakışan atamalar",
                    detail: "Aynı kapsam için hem açık hem kapalı kayıt var."
                ) {
                    ForEach(conflicts) { binding in
                        KeyValueRow(
                            key: binding.extensionID,
                            value: binding.isEnabled ? "açık" : "kapalı",
                            tint: Theme.warn
                        )
                    }
                }
            }

            SectionCard(
                title: "Extension → agent",
                detail: "Bir extension'ın hangi agent'larda etkin olduğu."
            ) {
                if registry.packages.isEmpty {
                    EmptyRow(text: "Henüz extension yok.")
                } else {
                    HStack(spacing: 12) {
                        Text("Extension")
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 220, alignment: .leading)
                        ForEach(ExtensionAgentID.supported) { agent in
                            Text(agent.displayName)
                                .font(Theme.mono(10, .semibold))
                                .foregroundStyle(Theme.textFaint)
                                .frame(width: 110, alignment: .leading)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    ForEach(registry.packages) { package in
                        HStack(spacing: 12) {
                            Text(package.name)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .frame(width: 220, alignment: .leading)
                            ForEach(ExtensionAgentID.supported) { agent in
                                let isOn = registry.agents(for: package.id).contains(agent)
                                Button {
                                    registry.setAgentBinding(
                                        !isOn, packageID: package.id, agent: agent
                                    )
                                } label: {
                                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(isOn ? Theme.codex : Theme.textFaint)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 110, alignment: .leading)
                                .accessibilityIdentifier(
                                    "extensions.matrix.\(package.id).\(agent.rawValue)"
                                )
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }

                    Divider().overlay(Theme.border)
                    HStack(spacing: 9) {
                        ForEach(ExtensionAgentID.supported) { agent in
                            Button("Tümünü \(agent.displayName)'a ata") {
                                for package in registry.packages {
                                    registry.setAgentBinding(
                                        true, packageID: package.id, agent: agent
                                    )
                                }
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }

            SectionCard(
                title: "Extension → proje",
                detail: "Kayıt yoksa extension globaldir; proje kaydı en özel olanı kazanır."
            ) {
                if projectStore.projects.isEmpty {
                    EmptyRow(text: "Henüz proje yok.")
                } else {
                    ForEach(registry.packages) { package in
                        HStack(spacing: 12) {
                            Text(package.name)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.text)
                                .frame(width: 220, alignment: .leading)
                            ForEach(projectStore.projects) { project in
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
                                        .font(Theme.mono(10))
                                        .foregroundStyle(
                                            binding == nil
                                                ? Theme.textFaint
                                                : (binding!.isEnabled ? Theme.ok : Theme.warn)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
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
                title: "GitHub kaynakları",
                detail: "Aynı repodaki birden fazla extension tek bare mirror kullanır."
            ) {
                HStack(spacing: 9) {
                    TextField("owner/repo", text: $newSource)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .onSubmit(add)
                    Button("Ekle", action: add)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("extensions.sources.add")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                if registry.effectiveSources.isEmpty {
                    Divider().overlay(Theme.border)
                    EmptyRow(text: "Kaynak yok.")
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
                    title: "Remote MCP",
                    detail: "Yerel git yok: sürüm sunucudan gelir, repo sürümüyle eşitlenmez."
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
        message = "\(value) kaynak olarak eklendi. Extension eklemek için discovery gerekiyor."
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
        var title: String { self == .commit ? "Commit'e sabitle" : "Branch veya tag değiştir" }
        var placeholder: String { self == .commit ? "commit SHA" : "branch veya tag adı" }
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
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                Text(trackingSummary)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Text(trustSummary)
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(packages.isEmpty ? Theme.textFaint : Theme.ok)
            }
            Text(
                packages.isEmpty
                    ? "Bu repodan henüz extension kurulmadı."
                    : "Extension: \(packages.map(\.name).joined(separator: ", "))"
            )
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.textDim)
            Text("Last fetch: \(lastFetchSummary)")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textFaint)
            HStack(spacing: 9) {
                Button("Fetch now") {
                    message = fetch()
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("extensions.sources.fetch.\(repository)")
                if !packages.isEmpty {
                    Button("Pin commit…") { retracking = .commit }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.sources.pin.\(repository)")
                    Button("Branch/tag değiştir…") { retracking = .branch }
                        .buttonStyle(GhostButtonStyle())
                }
                Button("Remove source") {
                    registry.removeSource(repository)
                    message = "\(repository) kaldırıldı; kurulu extension'lara dokunulmadı."
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
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(repository) — \(packages.count) extension etkilenecek.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                TextField(kind.placeholder, text: $reference)
                    .font(Theme.mono(11))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("extensions.sources.reference")
                HStack(spacing: 9) {
                    Spacer()
                    Button("Vazgeç") { retracking = nil }
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Uygula") { applyTracking(kind) }
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
            return "hiç yapılmadı"
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
            ? "Takip değişmedi."
            : "\(changed) extension artık \(tracking.label) takip ediyor."
    }

    private var trackingSummary: String {
        let modes = packages.compactMap { package -> String? in
            guard case .managedGitHub(_, _, let tracking) = package.source else { return nil }
            return tracking.label
        }
        return Set(modes).sorted().joined(separator: ", ")
    }

    private var trustSummary: String {
        packages.isEmpty ? "kullanılmıyor" : "kullanımda"
    }

    private func fetch() -> String {
        let mirror = ExtensionMirror(layout: registry.layout)
        guard mirror.hasMirror(for: repository) else {
            return "\(repository) için mirror yok; extension kurulunca oluşur."
        }
        do {
            try mirror.fetch(repository: repository)
            return "\(repository) fetch edildi."
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Security

private struct SecurityScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?
    @EnvironmentObject private var projectStore: ProjectStore
    @StateObject private var scans: BumblebeeScanCoordinator

    init(registry: ExtensionRegistry, message: Binding<String?>) {
        self.registry = registry
        _message = message
        _scans = StateObject(wrappedValue: BumblebeeScanCoordinator(registry: registry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard(
                title: "Tarama",
                detail: scans.isInstalled
                    ? "Bumblebee bulundu; taramalar buradan çalıştırılır."
                    : "Bumblebee kurulu değil. Kurulumu senin onayınla olur; Uncoil kendi taramasını yapmaya devam eder."
            ) {
                KeyValueRow(
                    key: "Son Bumblebee taraması",
                    value: registry.lastBumblebeeScanAt
                        .map { RelativeClock.short(since: $0) } ?? "hiç",
                    tint: registry.lastBumblebeeScanAt == nil ? Theme.textFaint : nil
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Binary",
                    value: registry.bumblebeeVersion?.label ?? "bilinmiyor"
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Self-test",
                    value: registry.bumblebeeSelfTest.map {
                        $0.passed ? "geçti" : "başarısız: \($0.detail)"
                    } ?? "çalıştırılmadı",
                    tint: registry.bumblebeeSelfTest?.passed == false ? Theme.danger : nil
                )
                Divider().overlay(Theme.border)
                HStack(spacing: 9) {
                    Button(scans.isScanning ? "Taranıyor…" : "Manuel scan") {
                        Task { message = await scans.scanManually().message }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(scans.isScanning)
                    .accessibilityIdentifier("extensions.security.manualScan")

                    Button("Proje taraması") {
                        let roots = projectStore.projects.map(\.rootPath)
                        Task { message = await scans.scanProjects(roots: roots).message }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(scans.isScanning)

                    Button("Deep scan") {
                        Task { message = await scans.deepScan().message }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(scans.isScanning)
                    Spacer()
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
                title: "Kapsam",
                detail: "Temiz sonuç, extension'ın tümüyle güvenli olduğu anlamına gelmez."
            ) {
                KeyValueRow(
                    key: "Uncoil taraması",
                    value: "Dosya, komut ve talimat analizi çalışır."
                )
                Divider().overlay(Theme.border)
                KeyValueRow(
                    key: "Bumblebee",
                    value: registry.findings.contains { $0.origin == .bumblebee }
                        ? "Son sonuç aşağıda"
                        : "Hiç çalıştırılmadı",
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
                    title: "\(origin.label) bulguları",
                    detail: "Kaynaklar ayrı gösterilir; birleştirilmez."
                ) {
                    if originFindings.isEmpty {
                        EmptyRow(
                            text: origin == .bumblebee
                                ? "Bumblebee çalıştırılmadı."
                                : "Açık bulgu yok."
                        )
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
                    title: "Karantina",
                    detail: "Dosyalar silinmedi; launcher başlatmayı reddediyor."
                ) {
                    ForEach(quarantined) { package in
                        HStack {
                            Text(package.name)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Button("Restore") {
                                registry.setState(.active, packageID: package.id)
                                message = "\(package.name) geri yüklendi."
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
                        .font(Theme.mono(9.5, .semibold))
                        .foregroundStyle(color)
                    Text(finding.rule)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                    if finding.isAccepted {
                        Text("kabul edildi")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                Text(finding.message)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                if let path = finding.path {
                    Text(path)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            if !finding.isAccepted {
                Button("Kabul et") {
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
        VStack(alignment: .leading, spacing: 18) {
            if registry.updateCandidates.isEmpty {
                SectionCard(title: "Güncelleme yok") {
                    EmptyRow(
                        text: registry.managedPackages.isEmpty
                            ? "Yönetilen extension yok; unmanaged paketler için update kontrolü yapılmaz."
                            : "Son taramada yeni commit bulunmadı."
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
                        tint: Theme.codex
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(key: "Commit sayısı", value: "\(candidate.commitCount)")
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Değişen dosyalar",
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
                                ? "Yeni bulgu yok"
                                : current.securityDiff
                                    .map { "\($0.severity.label): \($0.rule)" }
                                    .joined(separator: ", ")
                        } ?? "Henüz incelenmedi",
                        tint: (review?.securityDiff.contains { $0.severity >= .high } ?? false)
                            ? Theme.danger : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Yeni permission'lar",
                        value: review.map {
                            $0.addedPermissions.isEmpty ? "—" : $0.addedPermissions.joined(separator: ", ")
                        } ?? "—",
                        tint: (review?.addedPermissions.isEmpty == false) ? Theme.warn : nil
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Yeni tool'lar",
                        value: review.map {
                            $0.addedTools.isEmpty ? "—" : $0.addedTools.joined(separator: ", ")
                        } ?? "—"
                    )
                    Divider().overlay(Theme.border)
                    KeyValueRow(
                        key: "Kaldırılan tool'lar",
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
                    HStack(spacing: 9) {
                        Button(reviewed.contains(candidate.extensionID) ? "İncelendi ✓" : "İncele") {
                            makeReview(candidate, package: package)
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("extensions.update.review.\(candidate.extensionID)")

                        Button("Update selected") {
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

                        Button("Rollback history") {
                            message = rollbackHistory(package)
                        }
                        .buttonStyle(GhostButtonStyle())
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }

            if !registry.updateCandidates.isEmpty {
                HStack(spacing: 9) {
                    Button("Update all reviewed") { updateAllReviewed() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(reviewed.isEmpty)
                        .accessibilityIdentifier("extensions.update.applyReviewed")
                    Text("\(reviewed.count) incelendi")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
            }

            SectionCard(
                title: "Rollback geçmişi",
                detail: "Önceki revision saklanır; rollback tek tıkla oraya döner."
            ) {
                let withPrevious = registry.packages.filter { $0.previousRevision != nil }
                if withPrevious.isEmpty {
                    EmptyRow(text: "Henüz update uygulanmadı.")
                } else {
                    ForEach(withPrevious) { package in
                        KeyValueRow(
                            key: package.name,
                            value: "önceki: \(package.previousRevision?.commitSHA?.prefix(12) ?? "—")"
                        )
                    }
                }
            }
        }
    }

    /// Computes what the update would change. Nothing is applied.
    private func makeReview(_ candidate: UpdateCandidate, package: ExtensionPackage?) {
        guard let package, let active = package.activeRevision else {
            message = "Bu paketin kurulu bir revizyonu yok; önce kurulmalı."
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
        guard let package else { return "Paket bulunamadı." }
        let engine = updateEngine()
        do {
            let staged = try engine.stage(candidate, package: package)
            let updated = try engine.activate(
                staged, package: package, skillName: package.name
            )
            registry.upsert(updated)
            registry.record(AuditEvent(
                kind: .updateApplied, extensionID: package.id,
                detail: "\(candidate.availableCommitSHA.prefix(12)) sürümüne güncellendi"
            ))
            registry.discover()
            return "\(package.name) güncellendi."
        } catch {
            return "Güncelleme yapılmadı: \(error.localizedDescription)"
        }
    }

    private func rollback(_ package: ExtensionPackage?) -> String {
        guard let package, package.previousRevision != nil else {
            return "Geri dönülecek önceki revizyon yok."
        }
        let engine = updateEngine()
        do {
            let restored = try engine.rollback(package, skillName: package.name).package
            registry.upsert(restored)
            registry.record(AuditEvent(
                kind: .rolledBack, extensionID: package.id,
                detail: "önceki revizyona dönüldü"
            ))
            registry.discover()
            return "\(package.name) önceki revizyona döndü."
        } catch {
            return "Rollback yapılmadı: \(error.localizedDescription)"
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
            if result.contains("güncellendi") {
                applied.append(package?.name ?? candidate.extensionID)
            } else {
                failed.append(package?.name ?? candidate.extensionID)
            }
        }
        let skipped = registry.updateCandidates
            .filter { !reviewed.contains($0.extensionID) }
            .count
        var parts: [String] = []
        if !applied.isEmpty { parts.append("güncellendi: \(applied.joined(separator: ", "))") }
        if !failed.isEmpty { parts.append("başarısız: \(failed.joined(separator: ", "))") }
        if skipped > 0 { parts.append("\(skipped) paket incelenmediği için atlandı") }
        message = parts.isEmpty ? "Güncellenecek incelenmiş paket yok." : parts.joined(separator: " · ")
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
        guard let package else { return "Paket bulunamadı." }
        guard let previous = package.previousRevision else {
            return "\(package.name) için önceki revision yok."
        }
        return "\(package.name) önceki revision: \(previous.commitSHA ?? previous.id)"
    }
}

// MARK: - Activity

private struct ActivityScreen: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var message: String?

    var body: some View {
        SectionCard(
            title: "Etkinlik",
            detail: "Append-only kayıt; registry bozulsa bile korunur."
        ) {
            if registry.auditEvents.isEmpty {
                EmptyRow(text: "Henüz kayıt yok.")
            } else {
                ForEach(Array(registry.auditEvents.prefix(100).enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(event.kind.label)
                                    .font(Theme.mono(11, .semibold))
                                    .foregroundStyle(Theme.text)
                                if let extensionID = event.extensionID {
                                    Text(extensionID)
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                if let agent = event.agent {
                                    Text(agent.displayName)
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                            Text(event.detail)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Text(RelativeClock.short(since: event.at))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                        if ExtensionRegistry.isUndoable(event) {
                            Button("Undo") {
                                message = registry.undo(event) ?? "Bu işlem geri alınamıyor."
                            }
                            .buttonStyle(GhostButtonStyle())
                            .font(Theme.mono(9.5))
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
