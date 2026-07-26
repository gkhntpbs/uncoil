import SwiftUI

// MARK: - Accounts

/// Settings → Agentlar → Hesaplar. One profile per isolated provider config
/// directory, plus the provider's own default profile, which Uncoil does not own
/// and therefore cannot delete.
struct AccountsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var newAccountName = ""
    @State private var addingFor: AgentProvider?

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        SettingsPage(
            title: String(localized: "Accounts"),
            subtitle: String(localized: "Each account uses its own config folder, so work and personal sessions on the same provider stay apart.")
        ) {
            ForEach(providers) { provider in
                Section {
                    ForEach(settings.accounts(for: provider)) { profile in
                        AccountRow(profile: profile)
                    }

                    if addingFor == provider {
                        SettingsTextField(
                            title: String(localized: "New account"),
                            detail: String(localized: "A separate profile is created, with its own config folder."),
                            prompt: "e.g. Work, Personal",
                            text: $newAccountName,
                            onSubmit: { commit(provider) }
                        )
                        .settingsID("accounts.newName.\(provider.rawValue)")

                        HStack {
                            Button("Add") { commit(provider) }
                                .buttonStyle(.borderedProminent)
                                .disabled(newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") { addingFor = nil }
                            Spacer()
                        }
                    }
                } header: {
                    HStack {
                        Text("\(provider.displayName) accounts")
                        Spacer()
                        Button {
                            addingFor = provider
                            newAccountName = ""
                        } label: {
                            Label("Add an account", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .settingsID("accounts.add.\(provider.rawValue)")
                    }
                }
            }
        }
    }

    private func commit(_ provider: AgentProvider) {
        let trimmed = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.addAccount(provider: provider, name: trimmed)
        addingFor = nil
    }
}

private struct AccountRow: View {
    let profile: AccountProfile
    @EnvironmentObject private var settings: SettingsStore
    @State private var email: String?
    @State private var showLogin = false
    @State private var refreshToken = 0

    private var isDefault: Bool {
        settings.defaultAccount(for: profile.provider)?.id == profile.id
    }

    var body: some View {
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                    if isDefault {
                        Text("default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.highlightMuted, in: Capsule())
                    }
                }
                Text(email ?? "not signed in — starting a session opens the provider's login flow")
                    .font(.caption)
                    .foregroundStyle(email == nil ? Theme.textFaint : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } control: {
            HStack(spacing: 8) {
                if profile.provider.loginCommand != nil, email == nil {
                    Button("Sign In") { showLogin = true }
                        .settingsID("account.loginButton.\(profile.name)")
                }
                if !isDefault {
                    Button("Make Default") { settings.setDefaultAccount(profile) }
                }
                if profile.directoryName != nil {
                    Button(role: .destructive) {
                        settings.removeAccount(profile)
                    } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginTerminalSheet(profile: profile) { refreshToken += 1 }
        }
        .task(id: "\(profile.id)-\(refreshToken)") {
            guard profile.provider != .terminal else { return }
            let root = settings.profilesRootURL
            let store = settings
            email = await Task.detached(priority: .utility) {
                store.loggedInEmail(for: profile, profilesRoot: root)
            }.value
        }
    }
}

// MARK: - CLI tools

struct CLIToolsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        SettingsPage(
            title: String(localized: "CLI Tools"),
            subtitle: String(localized: "Check the installed versions and update with one click.")
        ) {
            Section {
                ForEach(providers) { provider in
                    CLIToolRow(provider: provider)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button {
                        Task { await settings.checkCLIUpdates() }
                    } label: {
                        if settings.cliChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(settings.cliChecking)
                    .settingsID("cli.check")
                }
            }

            Section("Paths Found") {
                ForEach(providers) { provider in
                    LabeledContent(provider.displayName) {
                        Text(settings.binaryPath(for: provider) ?? "not found")
                            .font(.caption.monospaced())
                            .foregroundStyle(
                                settings.binaryPath(for: provider) == nil
                                    ? Theme.danger : Theme.textFaint
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .task { await settings.checkCLIUpdates() }
    }
}

private struct CLIToolRow: View {
    let provider: AgentProvider
    @EnvironmentObject private var settings: SettingsStore

    private var path: String? { settings.binaryPath(for: provider) }
    private var updating: Bool { settings.cliUpdating.contains(provider.rawValue) }

    private var sourceLabel: String? {
        path.map { CLIToolService.source(forBinaryAt: $0, provider: provider).label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                        if let sourceLabel {
                            Text(sourceLabel)
                                .font(.caption2)
                                .foregroundStyle(Theme.textDim)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.panelActive, in: Capsule())
                        }
                    }
                    Text(settings.cliVersions[provider.rawValue]
                         ?? (path == nil ? "not installed" : "reading the version…"))
                        .font(.caption)
                        .foregroundStyle(path == nil ? Theme.danger : Theme.textFaint)
                }
            } control: {
                if updating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("updating…").font(.caption).foregroundStyle(Theme.textDim)
                    }
                } else if settings.updateAvailable(for: provider) {
                    HStack(spacing: 8) {
                        if let latest = settings.cliLatest[provider.rawValue] {
                            Text("new: \(latest)").font(.caption).foregroundStyle(Theme.warn)
                        }
                        Button("Update") { Task { await settings.updateCLI(provider) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(path == nil)
                    }
                } else if path != nil {
                    SettingsStatusLine(level: .ok, text: "up to date")
                } else {
                    SettingsStatusLine(level: .error, text: "not installed")
                }
            }

            if let result = settings.cliUpdateResult[provider.rawValue] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✓") ? Theme.ok : Theme.danger)
                    .lineLimit(3)
            }
        }
    }
}

// MARK: - Launch arguments

struct LaunchArgumentsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        SettingsPage(
            title: String(localized: "Run Parameters"),
            subtitle: String(localized: "Appended to the launch command; applies from the next session on.")
        ) {
            Section {
                ForEach(providers) { provider in
                    SettingsTextField(
                        title: provider.displayName,
                        prompt: provider == .claude ? "e.g. --model opus" : "e.g. --full-auto",
                        text: Binding(
                            get: { settings.extraArguments[provider.rawValue] ?? "" },
                            set: { settings.extraArguments[provider.rawValue] = $0 }
                        ),
                        monospaced: true,
                        onSubmit: { settings.save() }
                    )
                    .settingsID("launchArgs.\(provider.rawValue)")
                }
            }
        }
        .onDisappear { settings.save() }
    }
}

// MARK: - Mode & keyboard

struct AgentBehaviorSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        SettingsPage(title: String(localized: "Mode and Keyboard")) {
            Section {
                ForEach(providers) { provider in
                    Picker(selection: Binding(
                        get: { settings.workingMode(for: provider) },
                        set: { settings.setWorkingMode($0, for: provider) }
                    )) {
                        ForEach(AgentWorkingMode.options(for: provider)) { mode in
                            Text(mode.label(for: provider)).tag(mode)
                        }
                    } label: {
                        SettingsLabel(
                            title: provider.displayName,
                            detail: settings.workingMode(for: provider).detail(for: provider)
                        )
                    }
                    .settingsID("agentBehavior.workingMode.\(provider.rawValue)")
                }
            } header: {
                Text("Default agent mode")
            } footer: {
                SettingsNote(String(localized: "New sessions start in the selected mode; open sessions are unaffected."))
            }

            Section {
                ForEach(providers) { provider in
                    Toggle(isOn: Binding(
                        get: { settings.shiftEnterNewline(for: provider) },
                        set: { settings.setShiftEnterNewline($0, for: provider) }
                    )) {
                        SettingsLabel(
                            title: provider.displayName,
                            detail: String(localized: "Shift+Enter for a newline")
                        )
                    }
                    .settingsID("agentBehavior.shiftEnter.\(provider.rawValue)")
                }
            } header: {
                Text("Keyboard behaviour")
            } footer: {
                SettingsNote(
                    String(localized: "Shift+Enter (and Option+Enter) inserts a newline in the prompt; sending to the agent ")
                    + "sends a backslash + carriage return (\\⏎) instead. Applies to open sessions immediately."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.agentBehavior.container")
    }
}

// MARK: - Session presets

struct SessionPresetsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var editorRequest: PresetEditorRequest?

    struct PresetEditorRequest: Identifiable {
        let id = UUID()
        let preset: SessionPreset?
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "Session Presets"),
            subtitle: String(localized: "Set the provider, opening prompt and permission bounds for child agents.")
        ) {
            Section {
                ForEach(settings.presets) { preset in
                    AdaptiveRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text("\(preset.id) · \(preset.provider.displayName) · \(preset.grantedCapabilities.count) grants")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    } control: {
                        HStack(spacing: 8) {
                            Button("Edit") {
                                editorRequest = PresetEditorRequest(preset: preset)
                            }
                            .settingsID("presets.edit.\(preset.id)")
                            Button(role: .destructive) {
                                settings.removePreset(id: preset.id)
                            } label: {
                                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .settingsID("presets.delete.\(preset.id)")
                        }
                    }
                }
            } footer: {
                HStack {
                    Button("Back to Defaults") { settings.resetPresets() }
                        .settingsID("presets.reset")
                    Spacer()
                    Button {
                        editorRequest = PresetEditorRequest(preset: nil)
                    } label: {
                        Label("Add Preset", systemImage: "plus")
                    }
                    .settingsID("presets.add")
                }
            }
        }
        .sheet(item: $editorRequest) { request in
            SessionPresetEditorSheet(preset: request.preset) { settings.upsertPreset($0) }
        }
    }
}

private struct SessionPresetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preset: SessionPreset?
    let onSave: (SessionPreset) -> Void

    @State private var id: String
    @State private var name: String
    @State private var provider: AgentProvider
    @State private var argumentsText: String
    @State private var prompt: String
    @State private var permissionMode: String
    @State private var capabilities: Set<String>

    init(preset: SessionPreset?, onSave: @escaping (SessionPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _id = State(initialValue: preset?.id ?? "")
        _name = State(initialValue: preset?.name ?? "")
        _provider = State(initialValue: preset?.provider ?? .claude)
        _argumentsText = State(initialValue: preset?.extraArguments.joined(separator: "\n") ?? "")
        _prompt = State(initialValue: preset?.initialPromptTemplate ?? "")
        _permissionMode = State(initialValue: preset?.permissionMode ?? "standard")
        _capabilities = State(initialValue: Set(
            preset?.grantedCapabilities ?? Array(PolicyEngine.defaultGrants)
        ))
    }

    private var normalizedID: String {
        id.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private var canSave: Bool {
        !normalizedID.isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !permissionMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsTextField(
                        title: String(localized: "Identity"),
                        detail: String(localized: "Cannot be changed; child agents ask for the preset by this name."),
                        prompt: "e.g. reviewer",
                        text: $id,
                        monospaced: true
                    )
                    .disabled(preset != nil)
                    .settingsID("presets.editor.id")

                    SettingsTextField(title: String(localized: "Name"), prompt: "e.g. Code Reviewer", text: $name)
                        .settingsID("presets.editor.name")

                    Picker("Provider", selection: $provider) {
                        ForEach([AgentProvider.claude, .codex]) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }

                    SettingsTextField(
                        title: String(localized: "Permission mode"),
                        prompt: "standard",
                        text: $permissionMode,
                        monospaced: true
                    )
                }

                Section("Startup") {
                    SettingsTextField(
                        title: String(localized: "CLI arguments"),
                        detail: String(localized: "One argument per line."),
                        prompt: "--model opus",
                        text: $argumentsText,
                        monospaced: true,
                        lineLimit: 2...5
                    )

                    SettingsTextField(
                        title: String(localized: "Opening prompt"),
                        detail: String(localized: "Sent to the agent the moment the session opens."),
                        text: $prompt,
                        lineLimit: 3...6
                    )
                }

                Section("Grants") {
                    ForEach(CapabilityCatalog.all) { capability in
                        Toggle(isOn: Binding(
                            get: { capabilities.contains(capability.key) },
                            set: { enabled in
                                if enabled {
                                    capabilities.insert(capability.key)
                                } else {
                                    capabilities.remove(capability.key)
                                }
                            }
                        )) {
                            SettingsLabel(title: capability.label, detail: capability.key)
                        }
                        .settingsID("presets.editor.capability.\(capability.key)")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(SessionPreset(
                        id: normalizedID,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        provider: provider,
                        extraArguments: argumentsText
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty },
                        initialPromptTemplate: prompt
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty ? nil : prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        grantedCapabilities: capabilities.sorted(),
                        permissionMode: permissionMode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .settingsID("presets.editor.save")
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .navigationTitle(preset == nil ? "Add Preset" : "Edit Preset")
    }
}
