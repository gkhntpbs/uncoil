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
    /// What the installed CLI of the chosen provider actually supports; the
    /// pickers only offer what was detected.
    @State private var capabilities = AgentLaunchCapabilities()

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
            permissionProfile: request.permissionProfile,
            language: settings.language.resolvedAgent()
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
        .task(id: request.provider) {
            capabilities = await AgentLaunchCatalog.detect(
                provider: request.provider,
                binaryPath: settings.binaryPath(for: request.provider)
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send to agent")
                .font(Theme.mono(.large, .bold))
                .foregroundStyle(Theme.text)
            Text(task.displayText)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                Button {
                    request.existingSessionID = nil
                } label: {
                    row(
                        title: String(localized: "Create a new session"),
                        detail: String(localized: "Start a fresh agent for the task."),
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
                            detail: String(localized: "\(record.provider.displayName) · \(sessionStore.status(of: record.id).label)"),
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
                            detail: String(localized: "another project · \(record.provider.displayName)"),
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
                        .font(Theme.mono(.small))
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
                .foregroundStyle(isSelected ? Theme.highlight : Theme.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.mono(.body))
                    .foregroundStyle(tint ?? Theme.text)
                Text(detail)
                    .font(Theme.mono(.small))
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
            Text("New session")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                pickerRow(String(localized: "Agent")) {
                    Picker("", selection: $request.provider) {
                        ForEach(AgentProvider.agents) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: request.provider) { _, provider in
                        request.accountID = settings.defaultAccount(for: provider)?.id
                        request.workingMode = nil
                        // A model or effort picked for one CLI means nothing to
                        // the other.
                        request.model = nil
                        request.effort = nil
                    }
                    .accessibilityIdentifier("taskDispatch.provider")
                }
                Divider().overlay(Theme.border)
                pickerRow(String(localized: "Profile")) {
                    Picker("", selection: Binding(
                        get: { request.accountID },
                        set: { request.accountID = $0 }
                    )) {
                        Text("Default").tag(UUID?.none)
                        ForEach(settings.accounts(for: request.provider)) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.profile")
                }
                Divider().overlay(Theme.border)
                if !capabilities.models.isEmpty {
                    pickerRow(String(localized: "Model")) {
                        Picker("", selection: Binding(
                            get: { request.model },
                            set: { request.model = $0 }
                        )) {
                            Text(defaultModelLabel).tag(String?.none)
                            ForEach(capabilities.models) { option in
                                Text(option.label).tag(String?.some(option.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("taskDispatch.model")
                    }
                    Divider().overlay(Theme.border)
                }
                if !capabilities.efforts.isEmpty {
                    pickerRow(String(localized: "Effort")) {
                        Picker("", selection: Binding(
                            get: { request.effort },
                            set: { request.effort = $0 }
                        )) {
                            Text("Default").tag(String?.none)
                            ForEach(capabilities.efforts) { option in
                                Text(option.label).tag(String?.some(option.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("taskDispatch.effort")
                    }
                    Divider().overlay(Theme.border)
                }
                pickerRow(String(localized: "Working mode")) {
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
                pickerRow(String(localized: "Preset")) {
                    Picker("", selection: Binding(
                        get: { request.presetID },
                        set: { id in
                            request.presetID = id
                            applyPreset(id)
                        }
                    )) {
                        Text("No preset").tag(String?.none)
                        ForEach(settings.presets) { preset in
                            Text(preset.name).tag(String?.some(preset.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("taskDispatch.preset")
                }
                Divider().overlay(Theme.border)
                pickerRow(String(localized: "Permission profile")) {
                    Text(
                        request.permissionProfile.isEmpty
                            ? "session default"
                            : "\(request.permissionProfile.count) grants"
                    )
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                }
            }
            .panel()
        }
    }

    private var roleAndWorktreeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Role and worktree")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                pickerRow(String(localized: "Role")) {
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
                pickerRow(String(localized: "Create a worktree")) {
                    Toggle("", isOn: $request.createsWorktree)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityIdentifier("taskDispatch.createsWorktree")
                }
                if request.createsWorktree {
                    Divider().overlay(Theme.border)
                    pickerRow(String(localized: "Worktree name")) {
                        TextField(
                            TaskPromptBuilder.worktreeName(for: task),
                            text: Binding(
                                get: { request.worktreeName ?? "" },
                                set: { request.worktreeName = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(Theme.mono(.body))
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
                    Text("Prompt preview")
                        .font(Theme.mono(.body, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(previewPrompt.count) characters")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("taskDispatch.previewToggle")

            if showsPreview {
                Text(previewPrompt)
                    .font(Theme.mono(.small))
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
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
            Spacer()
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            // Sending the prompt and *starting* the turn are different acts:
            // sometimes the user wants to read and edit before Enter.
            Toggle(isOn: $request.autoStart) {
                Text("Start automatically")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("taskDispatch.autoStart")
            if !request.autoStart {
                Text("The prompt is typed in; you press Enter.")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(GhostButtonStyle())
            Button(request.autoStart ? "Send and start" : "Send (hold)") {
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

    /// What "Default" resolves to, when the CLI's own config says.
    private var defaultModelLabel: String {
        capabilities.defaultModelDetail.map { "Default (\($0))" } ?? "Default"
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
