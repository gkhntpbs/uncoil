import SwiftUI

// MARK: - Welcome

/// What Uncoil is, in four lines, plus the one question that has to come first:
/// which language the rest of the flow should be read in.
struct OnboardingWelcomeStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    var body: some View {
        OnboardingScaffold(
            step: .welcome,
            primaryTitle: String(localized: "Get started"),
            primaryAction: onContinue,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        ProviderMark(provider: .claude, size: 22)
                        ProviderMark(provider: .codex, size: 22)
                    }
                    Text("Welcome to Uncoil")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("A control centre for the coding agents you already run — across projects, worktrees and accounts.")
                        .font(Theme.mono(.large))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .padding(.top, 16)

                VStack(alignment: .leading, spacing: 14) {
                    OnboardingBullet(
                        symbol: "rectangle.split.3x1",
                        text: String(localized: "Run several agents side by side on the same project.")
                    )
                    OnboardingBullet(
                        symbol: "bolt",
                        text: String(localized: "Sessions keep running in the background and survive a restart.")
                    )
                    OnboardingBullet(
                        symbol: "arrow.triangle.2.circlepath",
                        text: String(localized: "Agents can talk back to Uncoil through its own MCP tools.")
                    )
                    OnboardingBullet(
                        symbol: "checklist",
                        text: String(localized: "Hand out work straight from your project's TODO.md.")
                    )
                }
                .frame(maxWidth: 460)

                VStack(spacing: 8) {
                    Picker(selection: Binding(
                        get: { settings.language.interface },
                        set: { settings.language.interface = $0 }
                    )) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    } label: {
                        Text("Interface language")
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.textDim)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("onboarding.language")

                    Text("Uncoil shows the new language after a restart.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.top, 4)

                Text("Developed by Gökhan Topbaş")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }
}

// MARK: - Agent CLIs

/// What is installed on this Mac, and what to type if something is missing.
/// Uncoil never runs an installer itself — the command is offered to copy.
struct OnboardingCLIStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var scanning = false

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        OnboardingScaffold(
            step: .clis,
            title: String(localized: "Choose your agent CLIs"),
            subtitle: String(localized: "Uncoil runs the CLIs already on your Mac. Nothing is installed for you."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                ForEach(providers) { provider in
                    providerCard(provider)
                }

                HStack(spacing: 12) {
                    Button(scanning ? String(localized: "Scanning…") : String(localized: "Rescan PATH")) {
                        rescan()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(scanning)
                    .accessibilityIdentifier("onboarding.rescan")

                    Spacer()

                    Picker(selection: Binding(
                        get: { settings.defaultProvider },
                        set: { settings.defaultProvider = $0; settings.save() }
                    )) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    } label: {
                        Text("Default agent")
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.textDim)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("onboarding.defaultProvider")
                }

                OnboardingSkipLink(action: onSkip)
            }
        }
        .task { rescan() }
    }

    @ViewBuilder
    private func providerCard(_ provider: AgentProvider) -> some View {
        let path = settings.binaryPath(for: provider)
        let version = settings.cliVersions[provider.rawValue]
        OnboardingCard(
            title: provider.displayName,
            badge: path == nil ? String(localized: "Not found") : String(localized: "Installed"),
            badgeTint: path == nil ? Theme.warn : Theme.ok,
            detail: path.map { installedDetail(path: $0, version: version, provider: provider) }
                ?? String(localized: "No binary on this Mac's PATH. Install it, then rescan.")
        ) {
            if path == nil, let command = installCommand(for: provider) {
                OnboardingCommandRow(command: command)
                    .padding(.top, 2)
            }
        }
    }

    private func installedDetail(path: String, version: String?, provider: AgentProvider) -> String {
        let source = CLIToolService.source(forBinaryAt: path, provider: provider)
        let versionText = version ?? String(localized: "version unknown")
        return "\(versionText) · \(source.label)\n\(path)"
    }

    private func installCommand(for provider: AgentProvider) -> String? {
        let package = CLIToolService.npmPackage(for: provider)
        return package.isEmpty ? nil : "npm install -g \(package)"
    }

    private func rescan() {
        guard !scanning else { return }
        scanning = true
        Task {
            await settings.resolveBinaries()
            await settings.refreshCLIVersions()
            scanning = false
        }
    }
}

// MARK: - Accounts

/// Why a profile is worth making, and the one action that finishes it: the
/// provider's own login, run against that profile's isolated config root.
struct OnboardingAccountsStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var loggingIn: AccountProfile?
    @State private var newAccountProvider: AgentProvider?
    @State private var newAccountName = ""

    var body: some View {
        OnboardingScaffold(
            step: .accounts,
            title: String(localized: "Keep your accounts apart"),
            subtitle: String(localized: "Each profile gets its own config root, so a work login and a personal one never mix. Credentials stay with the provider's CLI — Uncoil never sees them."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                ForEach([AgentProvider.claude, .codex]) { provider in
                    providerSection(provider)
                }
                OnboardingSkipLink(action: onSkip)
            }
        }
        .sheet(item: $loggingIn) { profile in
            LoginTerminalSheet(profile: profile) { loggingIn = nil }
                .environmentObject(settings)
        }
        .alert("New profile", isPresented: Binding(
            get: { newAccountProvider != nil },
            set: { if !$0 { newAccountProvider = nil } }
        )) {
            TextField("Profile name", text: $newAccountName)
            Button("Create") { createAccount() }
            Button("Cancel", role: .cancel) { newAccountProvider = nil }
        } message: {
            Text("An isolated config directory is created for this profile.")
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: AgentProvider) -> some View {
        OnboardingCard(
            title: provider.displayName,
            detail: String(localized: "Profiles for this provider.")
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(settings.accounts(for: provider)) { profile in
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.text)
                        if let email = settings.loggedInEmail(
                            for: profile, profilesRoot: settings.profilesRootURL
                        ) {
                            OnboardingBadge(text: email, tint: Theme.ok)
                        } else {
                            OnboardingBadge(text: String(localized: "Not signed in"), tint: Theme.warn)
                        }
                        Spacer(minLength: 0)
                        Button(String(localized: "Sign in")) { loggingIn = profile }
                            .buttonStyle(.plain)
                            .font(Theme.mono(.small, .semibold))
                            .foregroundStyle(Theme.highlight)
                    }
                }
                Button(String(localized: "Add a profile")) {
                    newAccountName = ""
                    newAccountProvider = provider
                }
                .buttonStyle(.plain)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 2)
            }
        }
    }

    private func createAccount() {
        guard let provider = newAccountProvider else { return }
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return newAccountProvider = nil }
        settings.addAccount(provider: provider, name: name)
        newAccountProvider = nil
    }
}
