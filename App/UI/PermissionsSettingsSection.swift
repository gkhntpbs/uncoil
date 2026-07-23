import SwiftUI

/// Settings → İzinler: a full permission manager for the MCP control plane.
///
/// - **Oturum Yetkileri** — proactively grant/revoke capability keys on a
///   session (writes `SessionRecord.capabilities`; the PolicyEngine reads this
///   live on the session's next call, so no agent request is needed).
/// - **Bekleyen İstekler** — approve/deny agent-triggered directional requests,
///   optionally persisting the grant onto the target session.
/// - **Verilen İzinler** — list/revoke directional grants.
/// - **İzin Ekle** — pre-authorize an A→B directional grant before any ask.
/// - **Test isteği** — inject a sample pending request to exercise the UI.
///
/// All PermissionService/ProjectStore mutations happen in button/toggle actions
/// or `.task`, never in `body` — publishing during a view update crashes.
struct PermissionsSettingsSection: View {
    @ObservedObject var service: PermissionService
    @EnvironmentObject private var projectStore: ProjectStore

    @State private var selectedSessionID: UUID?
    @State private var persistOnApprove = false
    @State private var showAddGrant = false
    @State private var addFrom: UUID?
    @State private var addTarget: UUID?
    @State private var addKey: String = "sessions.control_children"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sessionCapabilitiesSection
            pendingSection
            grantedSection
            addGrantSection
            testSection
        }
        .task { service.pruneExpiredIfNeeded() }
        .onAppear {
            if selectedSessionID == nil { selectedSessionID = projectStore.sessions.first?.id }
        }
    }

    // MARK: - (a) Session capability grants

    private var selectedSession: SessionRecord? {
        projectStore.sessions.first { $0.id == selectedSessionID }
    }

    private func effectiveGrants(_ record: SessionRecord) -> Set<String> {
        PolicyEngine.grants(for: record)
    }

    private var sessionCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Oturum Yetkileri", "Ajan istemeden, oturuma doğrudan yetki ver.")

            if projectStore.sessions.isEmpty {
                emptyLine("Henüz oturum yok.")
            } else {
                sessionPicker
                if let record = selectedSession {
                    capabilityToggles(for: record)
                }
            }
        }
    }

    private var sessionPicker: some View {
        Menu {
            ForEach(projectStore.sessions) { session in
                Button {
                    selectedSessionID = session.id
                } label: {
                    Text(sessionLabel(session))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedSession.map(sessionLabel) ?? "Oturum seç")
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                TablerIcon(name: "selector", size: 12, color: Theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func capabilityToggles(for record: SessionRecord) -> some View {
        let grants = effectiveGrants(record)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(CapabilityCatalog.grouped(), id: \.domain.id) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TablerIcon(name: group.domain.iconName, size: 11, color: Theme.textFaint)
                        Text(group.domain.title.uppercased())
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .kerning(0.6)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            capabilityRow(entry, record: record, isOn: grants.contains(entry.key))
                            if index != group.entries.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .panel()
                }
            }
        }
        .accessibilityIdentifier("settings.permissions.session.\(record.id.uuidString)")
    }

    private func capabilityRow(_ entry: CapabilityCatalog.Entry, record: SessionRecord, isOn: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.label)
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text)
                    if entry.risky {
                        Text("riskli")
                            .font(Theme.mono(8.5, .semibold))
                            .foregroundStyle(Theme.warn)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warn.opacity(0.14), in: Capsule())
                    }
                }
                Text(entry.detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in setGrant(entry.key, on: newValue, for: record.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier("settings.permissions.grant.\(entry.key)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Adds/removes a capability grant on a session. Materializes the effective
    /// grant set into an explicit array so toggling a *default* grant off (or an
    /// optional grant on) persists exactly. Effect is live on the next MCP call.
    private func setGrant(_ key: String, on: Bool, for sessionID: UUID) {
        projectStore.updateSession(sessionID) { record in
            var grants = PolicyEngine.grants(for: record)
            if on { grants.insert(key) } else { grants.remove(key) }
            record.capabilities = grants.sorted()
        }
    }

    // MARK: - (b) Pending requests

    private var pendingSection: some View {
        let records = service.pending()
        return VStack(alignment: .leading, spacing: 8) {
            header("Bekleyen İstekler", "Ajanların tetiklediği izin istekleri.")
            Toggle(isOn: $persistOnApprove) {
                Text("Onaylarken hedef oturuma kalıcı ver")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if records.isEmpty {
                emptyLine("Bekleyen izin isteği yok.")
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        recordRow(record) {
                            HStack(spacing: 8) {
                                Button("Onayla") { approve(record) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.ok)
                                Button("Reddet") { service.deny(id: record.id) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.warn)
                            }
                            .font(Theme.mono(11))
                        }
                    }
                }
                .panel()
            }
        }
    }

    private func approve(_ record: PermissionRequest) {
        service.grant(id: record.id)
        guard persistOnApprove,
              let raw = record.targetSessionID, let uuid = UUID(uuidString: raw),
              projectStore.sessions.contains(where: { $0.id == uuid }) else { return }
        setGrant(record.grantKey, on: true, for: uuid)
    }

    // MARK: - (c) Granted directional permissions

    private var grantedSection: some View {
        let records = service.granted()
        return VStack(alignment: .leading, spacing: 8) {
            header("Verilen İzinler", "Yönlü (kaynak → hedef) izinler.")
            if records.isEmpty {
                emptyLine("Verilmiş izin yok.")
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        recordRow(record) {
                            Button("İptal") { service.revoke(id: record.id) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textDim)
                                .font(Theme.mono(11))
                        }
                    }
                }
                .panel()
            }
        }
    }

    // MARK: - (d) Proactive directional grant

    private var addGrantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header("İzin Ekle", "A→B kontrolünü önceden yetkilendir.")
                Spacer()
                Button(showAddGrant ? "Kapat" : "İzin Ekle") {
                    if !showAddGrant {
                        addFrom = addFrom ?? projectStore.sessions.first?.id
                        addTarget = addTarget ?? projectStore.sessions.dropFirst().first?.id
                    }
                    showAddGrant.toggle()
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("settings.permissions.addGrant")
            }

            if showAddGrant {
                VStack(spacing: 0) {
                    pickerRow("Kaynak", selection: $addFrom)
                    Divider().overlay(Theme.border)
                    pickerRow("Hedef", selection: $addTarget)
                    Divider().overlay(Theme.border)
                    grantKeyPickerRow
                    Divider().overlay(Theme.border)
                    HStack {
                        Spacer()
                        Button("Ver") {
                            guard let from = addFrom else { return }
                            service.addGrant(
                                grantKey: addKey,
                                from: from.uuidString,
                                target: addTarget?.uuidString)
                            showAddGrant = false
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(addFrom == nil)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .panel()
            }
        }
    }

    private func pickerRow(_ title: String, selection: Binding<UUID?>) -> some View {
        HStack {
            Text(title)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Menu {
                ForEach(projectStore.sessions) { session in
                    Button(sessionLabel(session)) { selection.wrappedValue = session.id }
                }
            } label: {
                Text(projectStore.sessions.first { $0.id == selection.wrappedValue }
                    .map(sessionLabel) ?? "Seç")
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grantKeyPickerRow: some View {
        HStack {
            Text("Yetki")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Menu {
                ForEach(CapabilityCatalog.all) { entry in
                    Button("\(entry.domain.title) · \(entry.label)") { addKey = entry.key }
                }
            } label: {
                Text(CapabilityCatalog.entry(for: addKey)?.label ?? addKey)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Test affordance

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Test", "Canlı ajan olmadan izin akışını dene.")
            Button("Test isteği oluştur") {
                let sessions = projectStore.sessions
                service.injectTestRequest(
                    from: sessions.first?.id.uuidString,
                    target: sessions.dropFirst().first?.id.uuidString)
            }
            .buttonStyle(GhostButtonStyle())
            .accessibilityIdentifier("settings.permissions.testRequest")
        }
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func recordRow(
        _ record: PermissionRequest, @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CapabilityCatalog.entry(for: record.grantKey)?.label ?? record.grantKey)
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                Text("kaynak \(short(record.fromSessionID)) → hedef \(short(record.targetSessionID))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.textFaint)
    }

    private func sessionLabel(_ session: SessionRecord) -> String {
        let project = projectStore.projects.first { $0.id == session.projectID }
        let prefix = project.map { "\($0.name) · " } ?? ""
        return prefix + session.displayTitle
    }

    private func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return String(id.prefix(8))
    }
}
