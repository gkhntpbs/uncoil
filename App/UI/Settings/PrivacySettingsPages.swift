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
                title: String(localized: "Projects and Files"),
                detail: String(localized: "Manages projects, worktrees and artifacts."),
                symbol: "folder",
                keys: [
                    "projects.read", "worktrees.read", "worktrees.create",
                    "artifacts.read", "artifacts.write",
                ],
                requiresApproval: false
            ),
            AccessGroup(
                id: "sessions",
                title: String(localized: "Session Management"),
                detail: String(localized: "Sees, edits and groups sessions, and starts child agents."),
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
                title: String(localized: "Agent Browser"),
                detail: String(localized: "Uses the managed Chromium browser and its persistent state."),
                symbol: "globe",
                keys: ["browser.use", "browser.persistent_state"],
                requiresApproval: false
            ),
            AccessGroup(
                id: "computer",
                title: String(localized: "Computer Use"),
                detail: String(localized: "Sees the Mac's screen, controls the mouse and keyboard."),
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
        SettingsPage(title: String(localized: "Permissions")) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Safe automation ready").font(.headline)
                        Text("Project, session, artifact and Agent Browser are on by default in new sessions. Computer Use stays off for every session until you turn it on.")
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
                Section("Awaiting Approval") {
                    ForEach(service.pending()) { request in
                        requestRow(request) {
                            Button("Once") { service.grant(id: request.id, scope: .once) }
                                .settingsID("permissions.grantOnce")
                            Button("Permanent") { service.grant(id: request.id, scope: .persistent) }
                                .settingsID("permissions.grantPersistent")
                            Button("Deny", role: .destructive) { service.deny(id: request.id) }
                        }
                    }
                }
                .settingsID("permissions.pending")
            }

            if !service.expired().isEmpty {
                Section {
                    ForEach(Array(service.expired().prefix(5))) { request in
                        requestRow(request) {
                            Button("Remove") { service.revoke(id: request.id) }
                        }
                    }
                } header: {
                    Text("Timed Out")
                } footer: {
                    SettingsNote(String(localized: "Nobody answered in time; the agent has to ask again."))
                }
                .settingsID("permissions.expired")
            }

            Section("Permission Timeout") {
                Picker(selection: Binding(
                    get: { settings.permissionTimeoutMinutes },
                    set: {
                        settings.setPermissionTimeoutMinutes($0)
                        service.pendingTTL = settings.permissionTimeout
                    }
                )) {
                    Text("Off").tag(0)
                    ForEach([1, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Duration"),
                        detail: String(localized: "An unanswered request times out after this long.")
                    )
                }
                .settingsID("permissions.timeout")
            }

            Section {
                if projectStore.sessions.isEmpty {
                    Text("There is no session to grant anything to yet.")
                        .foregroundStyle(Theme.textDim)
                } else {
                    Picker(selection: $selectedSessionID) {
                        ForEach(projectStore.sessions) { session in
                            Text(sessionLabel(session)).tag(UUID?.some(session.id))
                        }
                    } label: {
                        SettingsLabel(title: String(localized: "Session"))
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
                Text("Session Access")
            } footer: {
                if let record = selectedSession {
                    HStack {
                        Text(record.capabilities == nil
                             ? "Using the default profile"
                             : "Customised for this session")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        if record.capabilities != nil {
                            Button("Back to Default") {
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
                                    title: String(localized: "\(group.domain.title) · \(entry.label)"),
                                    detail: entry.detail
                                )
                            }
                            .settingsID("permissions.grant.\(entry.key)")
                        }
                    }
                }

                ForEach(service.granted()) { request in
                    requestRow(request) {
                        Button("Cancel", role: .destructive) { service.revoke(id: request.id) }
                    }
                }
            } header: {
                Text("Advanced Permissions")
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
            title: String(localized: "Data and Transcripts"),
            subtitle: String(localized: "Choose how long terminal output is kept on disk. Recording is off by default.")
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
                    SettingsLabel(title: String(localized: "Retention"), symbol: "doc.text")
                }
                .settingsID("transcripts.retention")
            } footer: {
                HStack {
                    Spacer()
                    Button("Delete All Transcripts", role: .destructive) {
                        confirmingClear = true
                    }
                    .settingsID("transcripts.clear")
                }
            }

            Section("Data location") {
                LabeledContent("Folder") {
                    Text(ProjectStore.defaultDirectory().path)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.defaultDirectory()])
                }
            }
        }
        .confirmationDialog(
            "Delete every session transcript?",
            isPresented: $confirmingClear
        ) {
            Button("Delete Transcripts", role: .destructive) { settings.clearTranscripts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone, and it removes every stored piece of sensitive terminal output.")
        }
    }
}

// MARK: - Hooks

struct HooksSettingsPage: View {
    @State private var status = HookInstaller.status()
    @State private var message: String?

    var body: some View {
        SettingsPage(
            title: String(localized: "Status Tracking"),
            subtitle: String(localized: "Claude Code's hooks are what make session states stream into Uncoil live.")
        ) {
            Section {
                AdaptiveRow {
                    SettingsStatusLine(
                        level: status == .installed ? .ok : .warning,
                        text: statusLabel
                    )
                } control: {
                    if status == .installed {
                        Button("Remove", role: .destructive) { run(install: false) }
                    } else {
                        Button("Install") { run(install: true) }
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
        case .installed: "Installed — states stream live"
        case .notInstalled: "Not installed"
        case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
        }
    }

    private func run(install: Bool) {
        do {
            if install {
                try HookInstaller.install()
                message = "settings.json updated; its backup is under config-backups/. Restart open Claude sessions."
            } else {
                try HookInstaller.uninstall()
                message = "Uncoil's entries were removed; other hooks were left alone."
            }
        } catch {
            message = error.localizedDescription
        }
        status = HookInstaller.status()
    }
}
