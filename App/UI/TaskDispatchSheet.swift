import SwiftUI

/// Chooses how a task is handed to an agent, and shows the exact prompt before
/// anything is sent.
struct TaskDispatchSheet: View {
    let task: ProjectTask
    let document: TaskDocument
    let project: Project
    /// Called with the finished request; the caller performs the dispatch.
    let onSend: (TaskDispatchRequest) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var request = TaskDispatchRequest()
    @State private var showsPreview = false

    private var eligible: (sameProject: [SessionRecord], otherProjects: [SessionRecord]) {
        TaskPromptBuilder.eligibleSessions(
            projectStore.sessions,
            statuses: sessionStore.statuses,
            taskProjectID: project.id
        )
    }

    private var selectedSession: SessionRecord? {
        request.existingSessionID.flatMap { id in
            projectStore.sessions.first { $0.id == id }
        }
    }

    private var crossProjectWarning: String? {
        guard let session = selectedSession,
              let sessionProject = projectStore.projects.first(where: { $0.id == session.projectID })
        else { return nil }
        return TaskPromptBuilder.crossProjectWarning(
            sessionProjectName: sessionProject.name,
            taskProjectName: project.name
        )
    }

    private var previewPrompt: String {
        TaskPromptBuilder.prompt(TaskPromptBuilder.context(
            for: task,
            in: document,
            project: project,
            role: request.role,
            worktreePath: effectiveWorktreePath,
            permissionProfile: request.permissionProfile
        ))
    }

    /// What the agent will actually run in: an existing worktree, a new one, or
    /// the project root.
    private var effectiveWorktreePath: String? {
        if let path = request.worktreePath { return path }
        guard request.createsWorktree else { return nil }
        let name = request.worktreeName ?? TaskPromptBuilder.worktreeName(for: task)
        return "\(project.rootPath)/.uncoil-worktrees/\(name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    targetSection
                    if !request.isExistingSession {
                        newSessionSection
                    }
                    roleAndWorktreeSection
                    previewSection
                }
                .padding(16)
            }
            .uncoilScrollers()
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 620, height: 620)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("taskDispatch.sheet")
        .onAppear {
            request.provider = settings.defaultProvider
            request.accountID = settings.defaultAccount(for: request.provider)?.id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent'a gönder")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.text)
            Text(task.text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hedef")
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                Button {
                    request.existingSessionID = nil
                } label: {
                    row(
                        title: "Yeni oturum oluştur",
                        detail: "Görev için taze bir agent başlat.",
                        isSelected: !request.isExistingSession
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("taskDispatch.newSession")

                ForEach(eligible.sameProject) { record in
                    Divider().overlay(Theme.border)
                    Button {
                        request.existingSessionID = record.id
                    } label: {
                        row(
                            title: record.displayTitle,
                            detail: "\(record.provider.displayName) · \(sessionStore.status(of: record.id).label)",
                            isSelected: request.existingSessionID == record.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("taskDispatch.session.\(record.id.uuidString)")
                }

                ForEach(eligible.otherProjects) { record in
                    Divider().overlay(Theme.border)
                    Button {
                        request.existingSessionID = record.id
                    } label: {
                        row(
                            title: record.displayTitle,
                            detail: "başka proje · \(record.provider.displayName)",
                            isSelected: request.existingSessionID == record.id,
                            tint: Theme.warn
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .panel()

            if let crossProjectWarning {
                HStack(alignment: .top, spacing: 8) {
                    TablerIcon(name: "alert-triangle", size: 12, color: Theme.warn)
                    Text(crossProjectWarning)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.warn)
                }
                .accessibilityIdentifier("taskDispatch.crossProjectWarning")
            }
        }
    }

    private func row(
        title: String,
        detail: String,
        isSelected: Bool,
        tint: Color? = nil
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Theme.codex : Theme.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(tint ?? Theme.text)
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yeni oturum")
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                pickerRow("Agent") {
                    Picker("", selection: $request.provider) {
                        ForEach([AgentProvider.claude, .codex]) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: request.provider) { _, provider in
                        request.accountID = settings.defaultAccount(for: provider)?.id
                        request.workingMode = nil
                    }
                    .accessibilityIdentifier("taskDispatch.provider")
                }
                Divider().overlay(Theme.border)
                pickerRow("Profil") {
                    Picker("", selection: Binding(
                        get: { request.accountID },
                        set: { request.accountID = $0 }
                    )) {
                        Text("Varsayılan").tag(UUID?.none)
                        ForEach(settings.accounts(for: request.provider)) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.profile")
                }
                Divider().overlay(Theme.border)
                pickerRow("Model") {
                    TextField("varsayılan", text: Binding(
                        get: { request.model ?? "" },
                        set: { request.model = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .frame(width: 180)
                    .accessibilityIdentifier("taskDispatch.model")
                }
                Divider().overlay(Theme.border)
                pickerRow("Çalışma modu") {
                    Picker("", selection: Binding(
                        get: { request.workingMode ?? settings.workingMode(for: request.provider) },
                        set: { request.workingMode = $0 }
                    )) {
                        ForEach(AgentWorkingMode.options(for: request.provider)) { mode in
                            Text(mode.label(for: request.provider)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.workingMode")
                }
                Divider().overlay(Theme.border)
                pickerRow("Preset") {
                    Picker("", selection: Binding(
                        get: { request.presetID },
                        set: { id in
                            request.presetID = id
                            applyPreset(id)
                        }
                    )) {
                        Text("Preset yok").tag(String?.none)
                        ForEach(settings.presets) { preset in
                            Text(preset.name).tag(String?.some(preset.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.preset")
                }
                Divider().overlay(Theme.border)
                pickerRow("İzin profili") {
                    Text(
                        request.permissionProfile.isEmpty
                            ? "oturum varsayılanı"
                            : "\(request.permissionProfile.count) yetki"
                    )
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                }
            }
            .panel()
        }
    }

    private var roleAndWorktreeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rol ve worktree")
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                pickerRow("Rol") {
                    Picker("", selection: $request.role) {
                        ForEach(TaskAgentRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.role")
                }
                Divider().overlay(Theme.border)
                pickerRow("Worktree oluştur") {
                    Toggle("", isOn: $request.createsWorktree)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityIdentifier("taskDispatch.createsWorktree")
                }
                if request.createsWorktree {
                    Divider().overlay(Theme.border)
                    pickerRow("Worktree adı") {
                        TextField(
                            TaskPromptBuilder.worktreeName(for: task),
                            text: Binding(
                                get: { request.worktreeName ?? "" },
                                set: { request.worktreeName = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                        .frame(width: 220)
                        .accessibilityIdentifier("taskDispatch.worktreeName")
                    }
                }
            }
            .panel()
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsPreview.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showsPreview ? 0 : -90))
                        .foregroundStyle(Theme.textFaint)
                    Text("Prompt önizlemesi")
                        .font(Theme.mono(11.5, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(previewPrompt.count) karakter")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("taskDispatch.previewToggle")

            if showsPreview {
                Text(previewPrompt)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .panel()
                    .accessibilityIdentifier("taskDispatch.preview")
            }
        }
    }

    private func pickerRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textDim)
            Spacer()
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Spacer()
            Button("Vazgeç", action: onCancel)
                .buttonStyle(GhostButtonStyle())
            Button("Gönder") {
                var finished = request
                if finished.createsWorktree, finished.worktreeName == nil {
                    finished.worktreeName = TaskPromptBuilder.worktreeName(for: task)
                }
                onSend(finished)
            }
            .buttonStyle(AccentButtonStyle())
            .accessibilityIdentifier("taskDispatch.send")
        }
        .padding(16)
    }

    /// A preset decides the role's capabilities and arguments, so selecting one
    /// carries its permission profile into the request.
    private func applyPreset(_ id: String?) {
        guard let id, let preset = settings.presets.first(where: { $0.id == id }) else {
            request.permissionProfile = []
            return
        }
        request.provider = preset.provider
        request.permissionProfile = preset.grantedCapabilities
        // The preset's permission mode is a label; it maps onto a working mode
        // only when it names one this provider understands.
        if let mode = AgentWorkingMode(rawValue: preset.permissionMode),
           AgentWorkingMode.options(for: preset.provider).contains(mode) {
            request.workingMode = mode
        }
    }
}
