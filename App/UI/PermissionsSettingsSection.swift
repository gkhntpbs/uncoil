import SwiftUI

struct PermissionsSettingsSection: View {
    @ObservedObject var service: PermissionService
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var selectedSessionID: UUID?
    @State private var showDrivers = false
    @State private var showAdvanced = false

    private struct AccessGroup: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let keys: Set<String>
        let requiresApproval: Bool
    }

    private var accessGroups: [AccessGroup] {
        [
            AccessGroup(
                id: "projects",
                title: "Projeler ve Dosyalar",
                detail: "Projeleri, worktree'leri ve artifact'ları yönetir.",
                icon: "folders",
                keys: [
                    "projects.read", "worktrees.read", "worktrees.create",
                    "artifacts.read", "artifacts.write",
                ],
                requiresApproval: false
            ),
            AccessGroup(
                id: "sessions",
                title: "Oturum Yönetimi",
                detail: "Oturumları görür, düzenler, gruplar ve alt agent başlatır.",
                icon: "messages",
                keys: [
                    "sessions.read", "sessions.read_all", "sessions.control_children",
                    "sessions.control_all", "sessions.create_children",
                    "sessions.cross_project", "sessions.organize",
                ],
                requiresApproval: false
            ),
            AccessGroup(
                id: "browser",
                title: "Agent Browser",
                detail: "Yönetilen Chromium tarayıcısını ve kalıcı durumunu kullanır.",
                icon: "world",
                keys: ["browser.use", "browser.persistent_state"],
                requiresApproval: false
            ),
            AccessGroup(
                id: "computer",
                title: "Computer Use",
                detail: "Mac ekranını görür, fare ve klavyeyi kontrol eder.",
                icon: "device-desktop",
                keys: [
                    "computer.inspect", "computer.background_control",
                    "computer.foreground_control",
                ],
                requiresApproval: true
            ),
        ]
    }

    private var selectedSession: SessionRecord? {
        projectStore.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overview
            if !service.pending().isEmpty {
                pendingRequests
            }
            sessionAccess
            drivers
            advanced
        }
        .task {
            service.pruneExpiredIfNeeded()
            if selectedSessionID == nil {
                selectedSessionID = projectStore.sessions.first?.id
            }
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 12) {
            TablerIcon(name: "shield-check", size: 20, color: Theme.ok)
                .frame(width: 28, height: 28)
                .background(Theme.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Güvenli otomasyon hazır")
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.text)
                Text("Proje, oturum, artifact ve Agent Browser yeni oturumlarda otomatik açıktır. Computer Use her oturum için sen açana kadar kapalı kalır.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.ok.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.ok.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("settings.permissions.overview")
    }

    private var sessionAccess: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(
                "Oturum Erişimi",
                "Bir oturum seç; yaygın izinleri tek yerden yönet."
            )
            if projectStore.sessions.isEmpty {
                emptyLine("İzin verilecek bir oturum henüz yok.")
            } else {
                sessionPicker
                if let record = selectedSession {
                    VStack(spacing: 0) {
                        ForEach(Array(accessGroups.enumerated()), id: \.element.id) { index, group in
                            accessRow(group, record: record)
                            if index != accessGroups.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .panel(radius: 10)

                    HStack {
                        Text(record.capabilities == nil
                             ? "Varsayılan profil kullanılıyor"
                             : "Bu oturum için özelleştirildi")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        if record.capabilities != nil {
                            Button("Varsayılana Dön") {
                                projectStore.updateSession(record.id) {
                                    $0.capabilities = nil
                                }
                            }
                            .buttonStyle(GhostButtonStyle())
                            .accessibilityIdentifier("settings.permissions.reset")
                        }
                    }
                }
            }
        }
    }

    private var sessionPicker: some View {
        Menu {
            ForEach(projectStore.projects) { project in
                let sessions = projectStore.sessions(for: project.id)
                if !sessions.isEmpty {
                    Section(project.name) {
                        ForEach(sessions) { session in
                            Button(session.displayTitle) {
                                selectedSessionID = session.id
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedSession.map(sessionLabel) ?? "Oturum seç")
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let selectedSession {
                    ProviderMark(provider: selectedSession.provider, size: 11)
                }
                Spacer()
                TablerIcon(name: "selector", size: 12, color: Theme.textDim)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minWidth: 260, maxWidth: 360, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("settings.permissions.sessionPicker")
    }

    private func accessRow(
        _ group: AccessGroup,
        record: SessionRecord
    ) -> some View {
        let grants = PolicyEngine.grants(for: record)
        let isOn = group.keys.isSubset(of: grants)
        return HStack(alignment: .center, spacing: 11) {
            TablerIcon(
                name: group.icon,
                size: 15,
                color: group.requiresApproval ? Theme.warn : Theme.textDim
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(Theme.mono(11.5, .semibold))
                        .foregroundStyle(Theme.text)
                    if group.requiresApproval {
                        Text("ONAY GEREKİR")
                            .font(Theme.mono(8, .bold))
                            .foregroundStyle(Theme.warn)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.warn.opacity(0.12), in: Capsule())
                    }
                }
                Text(group.detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { set(group.keys, enabled: $0, sessionID: record.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityIdentifier("settings.permissions.group.\(group.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var pendingRequests: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(
                "Onay Bekleyenler",
                "Agent tarafından şu anda istenen yönlü izinler."
            )
            VStack(spacing: 0) {
                ForEach(Array(service.pending().enumerated()), id: \.element.id) { index, request in
                    requestRow(request) {
                        Button("Onayla") { service.grant(id: request.id) }
                            .foregroundStyle(Theme.ok)
                        Button("Reddet") { service.deny(id: request.id) }
                            .foregroundStyle(Theme.warn)
                    }
                    if index != service.pending().count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel(radius: 10)
        }
        .accessibilityIdentifier("settings.permissions.pending")
    }

    private var drivers: some View {
        DisclosureGroup(isExpanded: $showDrivers) {
            VStack(alignment: .leading, spacing: 16) {
                AgentBrowserSetupSection()
                CuaDriverSetupSection()
            }
            .padding(.top, 12)
        } label: {
            disclosureLabel(
                "Sürücü Kurulumu",
                "Agent Browser ve Computer Use bağlantılarını kur ve doğrula.",
                icon: "settings-automation"
            )
        }
        .accessibilityIdentifier("settings.permissions.drivers")
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                if let record = selectedSession {
                    ForEach(CapabilityCatalog.grouped(), id: \.domain.id) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.domain.title.uppercased())
                                .font(Theme.mono(9, .semibold))
                                .foregroundStyle(Theme.textFaint)
                                .kerning(0.5)
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    capabilityRow(entry, record: record)
                                    if index != group.entries.count - 1 {
                                        Divider().overlay(Theme.border)
                                    }
                                }
                            }
                            .panel(radius: 9)
                        }
                    }
                }

                let granted = service.granted()
                if !granted.isEmpty {
                    sectionHeader(
                        "Yönlü İzinler",
                        "Belirli bir kaynak oturumdan hedef oturuma verilmiş izinler."
                    )
                    VStack(spacing: 0) {
                        ForEach(Array(granted.enumerated()), id: \.element.id) { index, request in
                            requestRow(request) {
                                Button("İptal") { service.revoke(id: request.id) }
                                    .foregroundStyle(Theme.textDim)
                            }
                            if index != granted.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .panel(radius: 9)
                }
            }
            .padding(.top, 12)
        } label: {
            disclosureLabel(
                "Gelişmiş İzinler",
                "Tek tek yetkileri ve yönlü agent izinlerini yönet.",
                icon: "adjustments"
            )
        }
        .accessibilityIdentifier("settings.permissions.advanced")
    }

    private func capabilityRow(
        _ entry: CapabilityCatalog.Entry,
        record: SessionRecord
    ) -> some View {
        let isOn = PolicyEngine.grants(for: record).contains(entry.key)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(Theme.text)
                Text(entry.detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { set([entry.key], enabled: $0, sessionID: record.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier("settings.permissions.grant.\(entry.key)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func requestRow(
        _ request: PermissionRequest,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CapabilityCatalog.entry(for: request.grantKey)?.label
                     ?? request.grantKey)
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                Text("\(short(request.fromSessionID)) → \(short(request.targetSessionID))")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            HStack(spacing: 9) {
                actions()
            }
            .buttonStyle(.plain)
            .font(Theme.mono(10.5, .medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private func disclosureLabel(
        _ title: String,
        _ detail: String,
        icon: String
    ) -> some View {
        HStack(spacing: 10) {
            TablerIcon(name: icon, size: 15, color: Theme.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func sectionHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textFaint)
    }

    private func set(
        _ keys: Set<String>,
        enabled: Bool,
        sessionID: UUID
    ) {
        projectStore.updateSession(sessionID) { record in
            var grants = PolicyEngine.grants(for: record)
            if enabled {
                grants.formUnion(keys)
            } else {
                grants.subtract(keys)
            }
            record.capabilities = grants.sorted()
        }
    }

    private func sessionLabel(_ session: SessionRecord) -> String {
        let projectName = projectStore.projects.first {
            $0.id == session.projectID
        }?.name
        return [projectName, session.displayTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        if let uuid = UUID(uuidString: id),
           let session = projectStore.sessions.first(where: { $0.id == uuid }) {
            return session.displayTitle
        }
        return String(id.prefix(8))
    }
}
