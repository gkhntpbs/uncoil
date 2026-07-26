import SwiftUI

// MARK: - Permissions

/// Settings → Gizlilik ve İzinler → İzinler.
///
/// Same model as before — grouped access for a selected session, a timeout for
/// unanswered requests, and an advanced disclosure for individual capabilities —
/// rebuilt on `Form`. Driver installation moved to its own Integrations page.
struct PermissionsSettingsPage: View {
    @ObservedObject var service: PermissionService
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedSessionID: UUID?
    @State private var showAdvanced = false

    private struct AccessGroup: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let keys: Set<String>
        let requiresApproval: Bool
    }

    private var accessGroups: [AccessGroup] {
        [
            AccessGroup(
                id: "projects",
                title: "Projeler ve Dosyalar",
                detail: "Projeleri, worktree'leri ve artifact'ları yönetir.",
                symbol: "folder",
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
                symbol: "bubble.left.and.bubble.right",
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
                symbol: "globe",
                keys: ["browser.use", "browser.persistent_state"],
                requiresApproval: false
            ),
            AccessGroup(
                id: "computer",
                title: "Computer Use",
                detail: "Mac ekranını görür, fare ve klavyeyi kontrol eder.",
                symbol: "display",
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
        SettingsPage(title: "İzinler") {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Güvenli otomasyon hazır").font(.headline)
                        Text("Proje, oturum, artifact ve Agent Browser yeni oturumlarda otomatik açıktır. Computer Use her oturum için sen açana kadar kapalı kalır.")
                            .font(.callout)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Theme.ok)
                        .font(.title2)
                }
            }
            .settingsID("permissions.overview")

            if !service.pending().isEmpty {
                Section("Onay Bekleyenler") {
                    ForEach(service.pending()) { request in
                        requestRow(request) {
                            Button("Bir Kez") { service.grant(id: request.id, scope: .once) }
                                .settingsID("permissions.grantOnce")
                            Button("Kalıcı") { service.grant(id: request.id, scope: .persistent) }
                                .settingsID("permissions.grantPersistent")
                            Button("Reddet", role: .destructive) { service.deny(id: request.id) }
                        }
                    }
                }
                .settingsID("permissions.pending")
            }

            if !service.expired().isEmpty {
                Section {
                    ForEach(Array(service.expired().prefix(5))) { request in
                        requestRow(request) {
                            Button("Kaldır") { service.revoke(id: request.id) }
                        }
                    }
                } header: {
                    Text("Zaman Aşımına Düşenler")
                } footer: {
                    SettingsNote("Kimse zamanında cevaplamadı; agent yeniden istemek zorunda.")
                }
                .settingsID("permissions.expired")
            }

            Section("İzin Zaman Aşımı") {
                Picker(selection: Binding(
                    get: { settings.permissionTimeoutMinutes },
                    set: {
                        settings.setPermissionTimeoutMinutes($0)
                        service.pendingTTL = settings.permissionTimeout
                    }
                )) {
                    Text("Kapalı").tag(0)
                    ForEach([1, 5, 10, 30], id: \.self) { Text("\($0) dk").tag($0) }
                } label: {
                    SettingsLabel(
                        title: "Süre",
                        detail: "Cevaplanmayan istek bu süre sonunda zaman aşımına düşer."
                    )
                }
                .settingsID("permissions.timeout")
            }

            Section {
                if projectStore.sessions.isEmpty {
                    Text("İzin verilecek bir oturum henüz yok.")
                        .foregroundStyle(Theme.textDim)
                } else {
                    Picker(selection: $selectedSessionID) {
                        ForEach(projectStore.sessions) { session in
                            Text(sessionLabel(session)).tag(UUID?.some(session.id))
                        }
                    } label: {
                        SettingsLabel(title: "Oturum")
                    }
                    .settingsID("permissions.sessionPicker")

                    if let record = selectedSession {
                        ForEach(accessGroups) { group in
                            Toggle(isOn: Binding(
                                get: { group.keys.isSubset(of: PolicyEngine.grants(for: record)) },
                                set: { set(group.keys, enabled: $0, sessionID: record.id) }
                            )) {
                                SettingsLabel(
                                    title: group.requiresApproval
                                        ? "\(group.title) — onay gerekir"
                                        : group.title,
                                    detail: group.detail,
                                    symbol: group.symbol
                                )
                            }
                            .settingsID("permissions.group.\(group.id)")
                        }
                    }
                }
            } header: {
                Text("Oturum Erişimi")
            } footer: {
                if let record = selectedSession {
                    HStack {
                        Text(record.capabilities == nil
                             ? "Varsayılan profil kullanılıyor"
                             : "Bu oturum için özelleştirildi")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        if record.capabilities != nil {
                            Button("Varsayılana Dön") {
                                projectStore.updateSession(record.id) { $0.capabilities = nil }
                            }
                            .settingsID("permissions.reset")
                        }
                    }
                }
            }

            Section(isExpanded: $showAdvanced) {
                if let record = selectedSession {
                    ForEach(CapabilityCatalog.grouped(), id: \.domain.id) { group in
                        ForEach(group.entries) { entry in
                            Toggle(isOn: Binding(
                                get: { PolicyEngine.grants(for: record).contains(entry.key) },
                                set: { set([entry.key], enabled: $0, sessionID: record.id) }
                            )) {
                                SettingsLabel(
                                    title: "\(group.domain.title) · \(entry.label)",
                                    detail: entry.detail
                                )
                            }
                            .settingsID("permissions.grant.\(entry.key)")
                        }
                    }
                }

                ForEach(service.granted()) { request in
                    requestRow(request) {
                        Button("İptal", role: .destructive) { service.revoke(id: request.id) }
                    }
                }
            } header: {
                Text("Gelişmiş İzinler")
            }
            .settingsID("permissions.advanced")
        }
        .task {
            service.pendingTTL = settings.permissionTimeout
            service.pruneExpiredIfNeeded()
            if selectedSessionID == nil {
                selectedSessionID = projectStore.sessions.first?.id
            }
        }
    }

    private func requestRow(
        _ request: PermissionRequest,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(CapabilityCatalog.entry(for: request.grantKey)?.label ?? request.grantKey)
                HStack(spacing: 6) {
                    Text("\(short(request.fromSessionID)) → \(short(request.targetSessionID))")
                    if request.status == .granted {
                        Text(request.effectiveScope.label)
                            .foregroundStyle(request.effectiveScope == .once ? Theme.warn : Theme.ok)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textDim)
            }
        } control: {
            HStack(spacing: 8) { actions() }
        }
    }

    private func set(_ keys: Set<String>, enabled: Bool, sessionID: UUID) {
        projectStore.updateSession(sessionID) { record in
            var grants = PolicyEngine.grants(for: record)
            if enabled { grants.formUnion(keys) } else { grants.subtract(keys) }
            record.capabilities = grants.sorted()
        }
    }

    private func sessionLabel(_ session: SessionRecord) -> String {
        let projectName = projectStore.projects.first { $0.id == session.projectID }?.name
        return [projectName, session.displayTitle].compactMap { $0 }.joined(separator: " · ")
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

// MARK: - Data & transcripts

struct PrivacyDataSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var confirmingClear = false

    var body: some View {
        SettingsPage(
            title: "Veri ve Transcript",
            subtitle: "Terminal çıktılarının diskte ne kadar süre saklanacağını seç. Varsayılan olarak kayıt kapalıdır."
        ) {
            Section {
                Picker(selection: Binding(
                    get: { settings.transcriptRetentionPolicy },
                    set: { settings.setTranscriptRetentionPolicy($0) }
                )) {
                    ForEach(TranscriptRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                } label: {
                    SettingsLabel(title: "Saklama süresi", symbol: "doc.text")
                }
                .settingsID("transcripts.retention")
            } footer: {
                HStack {
                    Spacer()
                    Button("Tüm Transcriptleri Sil", role: .destructive) {
                        confirmingClear = true
                    }
                    .settingsID("transcripts.clear")
                }
            }

            Section("Veri konumu") {
                LabeledContent("Klasör") {
                    Text(ProjectStore.defaultDirectory().path)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Finder’da Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.defaultDirectory()])
                }
            }
        }
        .confirmationDialog(
            "Tüm session transcriptleri silinsin mi?",
            isPresented: $confirmingClear
        ) {
            Button("Transcriptleri Sil", role: .destructive) { settings.clearTranscripts() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu işlem geri alınamaz ve saklanan hassas terminal çıktılarının tamamını kaldırır.")
        }
    }
}

// MARK: - Hooks

struct HooksSettingsPage: View {
    @State private var status = HookInstaller.status()
    @State private var message: String?

    var body: some View {
        SettingsPage(
            title: "Durum Takibi",
            subtitle: "Claude Code’un hook’ları, oturum durumlarının Uncoil’e canlı akmasını sağlar."
        ) {
            Section {
                AdaptiveRow {
                    SettingsStatusLine(
                        level: status == .installed ? .ok : .warning,
                        text: statusLabel
                    )
                } control: {
                    if status == .installed {
                        Button("Kaldır", role: .destructive) { run(install: false) }
                    } else {
                        Button("Kur") { run(install: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                if let message {
                    SettingsNote(message)
                }
            }
        }
    }

    private var statusLabel: String {
        switch status {
        case .installed: "Kurulu — durumlar canlı akıyor"
        case .notInstalled: "Kurulu değil"
        case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
        }
    }

    private func run(install: Bool) {
        do {
            if install {
                try HookInstaller.install()
                message = "settings.json güncellendi; yedeği config-backups/ altında. Açık Claude oturumlarını yeniden başlat."
            } else {
                try HookInstaller.uninstall()
                message = "Uncoil girdileri kaldırıldı; diğer hook'lara dokunulmadı."
            }
        } catch {
            message = error.localizedDescription
        }
        status = HookInstaller.status()
    }
}
