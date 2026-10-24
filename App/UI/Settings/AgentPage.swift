import SwiftUI

/// Settings › Agents › *one page per agent*.
///
/// What was here before was four pages — Installed Agents, Accounts, CLI Tools,
/// Run Parameters, Working Mode — each a matrix of every agent against one
/// setting. A user arrives thinking about an agent ("I am setting up Codex")
/// and had to visit four pages to do it, reading two other agents' rows on each.
/// The matrix also forced every option to exist for every agent, which is how
/// a provider-specific setting ends up as a column that is blank for the rest.
///
/// So the page is the agent, and the descriptor decides what it contains: the
/// logins section disappears for a provider with no login command, the working
/// mode picker offers that agent's own modes, and an agent that ships its own
/// updater says so instead of showing a version to compare.
struct AgentSettingsPage: View {
    let provider: AgentProvider
    /// Back to the list this page was opened from.
    let back: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @State private var newAccountName = ""
    @State private var isAddingAccount = false
    @State private var locationMessage: String?

    private var descriptor: AgentDescriptor { provider.descriptor }
    private var isInstalled: Bool { settings.binaryPath(for: provider) != nil }
    private var hasUpdate: Bool { settings.updateAvailable(for: provider) }

    var body: some View {
        SettingsPage(
            title: descriptor.displayName,
            subtitle: subtitle,
            back: (String(localized: "Installed Agents"), back)
        ) {
            // Not installed is the first thing to say, not a footnote: every
            // setting under it is inert until there is a binary to run.
            if !isInstalled {
                Section {
                    SettingsStatusLine(
                        level: .error,
                        text: String(localized: "\(descriptor.fullName) was not found on this Mac. Nothing on this page takes effect until it is installed, or until you point Uncoil at where it lives.")
                    )
                    locationControls
                }
            }

            // An update waiting is why the user is here — the gear's badge led
            // them — so the section that holds it comes first, not last.
            if hasUpdate {
                cli
                logins
                defaults
            } else {
                logins
                defaults
                cli
            }
        }
    }

    private var subtitle: String {
        isInstalled
            ? String(localized: "Logins, what it does on its own, and the CLI Uncoil runs.")
            : String(localized: "Not installed.")
    }

    // MARK: - Logins

    /// One profile per isolated config directory, plus the provider's own
    /// default profile, which Uncoil does not own and therefore cannot delete.
    @ViewBuilder
    private var logins: some View {
        if descriptor.isAgent {
            Section {
                ForEach(settings.accounts(for: provider)) { profile in
                    AccountRow(profile: profile)
                }

                if isAddingAccount {
                    SettingsTextField(
                        title: String(localized: "New account"),
                        detail: String(localized: "A separate profile is created, with its own config folder."),
                        prompt: String(localized: "e.g. Work, Personal"),
                        text: $newAccountName,
                        onSubmit: commitAccount
                    )
                    .settingsID("accounts.newName.\(provider.rawValue)")

                    HStack {
                        Button("Add", action: commitAccount)
                            .buttonStyle(.borderedProminent)
                            .disabled(newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { isAddingAccount = false }
                        Spacer()
                    }
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Button {
                        isAddingAccount = true
                        newAccountName = ""
                    } label: {
                        Label("Add an account", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .settingsID("accounts.add.\(provider.rawValue)")
                }
            } footer: {
                SettingsNote(String(localized: "Each account uses its own config folder, so work and personal sessions on the same provider stay apart."))
            }
        }
    }

    // MARK: - Defaults

    /// What a new session of this agent starts as. Both rows are defaults a
    /// session can override, which is why they share a section rather than
    /// sitting on pages called "Working Mode" and "Run Parameters".
    @ViewBuilder
    private var defaults: some View {
        Section {
            if descriptor.workingModes.count > 1 {
                Picker(selection: Binding(
                    get: { settings.workingMode(for: provider) },
                    set: { settings.setWorkingMode($0, for: provider) }
                )) {
                    ForEach(AgentWorkingMode.options(for: provider)) { mode in
                        Text(mode.label(for: provider)).tag(mode)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Working mode"),
                        detail: settings.workingMode(for: provider).detail(for: provider)
                    )
                }
                .settingsID("agentBehavior.workingMode.\(provider.rawValue)")
            }

            SettingsTextField(
                title: String(localized: "Run parameters"),
                detail: String(localized: "Appended to the launch command."),
                prompt: provider == .claude
                    ? String(localized: "e.g. --model opus")
                    : String(localized: "e.g. --full-auto"),
                text: Binding(
                    get: { settings.extraArguments[provider.rawValue] ?? "" },
                    set: { settings.extraArguments[provider.rawValue] = $0 }
                ),
                monospaced: true,
                onSubmit: { settings.save() }
            )
            .settingsID("launchArgs.\(provider.rawValue)")
        } header: {
            Text("New sessions")
        } footer: {
            SettingsNote(String(localized: "Applies from the next session on; open sessions are unaffected."))
        }
        .onDisappear { settings.save() }
    }

    // MARK: - The CLI

    @ViewBuilder
    private var cli: some View {
        if isInstalled {
            Section {
                CLIToolRow(provider: provider)
                locationControls
            } header: {
                HStack(spacing: 6) {
                    Text("The CLI")
                    if hasUpdate {
                        Circle().fill(Theme.danger).frame(width: 7, height: 7)
                            .accessibilityIdentifier("settings.cli.updateMark")
                        Text("Update available")
                            .foregroundStyle(Theme.danger)
                    }
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
            .task { await settings.checkCLIUpdates() }
        }
    }

    /// The panel is `AgentLocationPicker`'s, shared with the Extensions card,
    /// so the wording and the refusal are the same wherever it is opened from.
    @ViewBuilder
    private var locationControls: some View {
        if let agent = descriptor.extensionAgentID, let command = descriptor.cliBinaryName {
            let chosen = settings.agentBinaryLocation(forCommand: command)
            HStack {
                Button(chosen == nil ? "Locate…" : "Change Location…") {
                    AgentLocationPicker.choose(for: agent, settings: settings) { text, changed in
                        locationMessage = text
                        if changed { Task { await AgentHookupService.shared.scan() } }
                    }
                }
                .settingsID("agent.locate.\(provider.rawValue)")
                if chosen != nil {
                    Button("Use PATH Again") {
                        locationMessage = AgentLocationPicker.clear(for: agent, settings: settings)
                        Task { await AgentHookupService.shared.scan() }
                    }
                }
                Spacer()
            }
            if let locationMessage {
                SettingsStatusLine(level: .neutral, text: locationMessage)
            }
        }
    }

    private func commitAccount() {
        let trimmed = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.addAccount(provider: provider, name: trimmed)
        isAddingAccount = false
    }
}
