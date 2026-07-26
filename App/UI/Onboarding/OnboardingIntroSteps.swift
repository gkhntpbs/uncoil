import SwiftUI

// MARK: - Welcome

/// What Uncoil is, in four lines, plus the two language questions that decide
/// how everything after this page reads: the interface, and the language Uncoil
/// writes its prompts to agents in.
struct OnboardingWelcomeStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    var body: some View {
        OnboardingScaffold(
            step: .welcome,
            primaryTitle: String(localized: "Get started"),
            primaryAction: onContinue,
            onSkipAll: onSkipAll,
            footnote: "Developed by Gökhan Topbaş"
        ) {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image("MenuBarIconColor")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                        .accessibilityHidden(true)
                    Text("Welcome to Uncoil")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("A control centre for the coding agents you already run — across projects, worktrees and accounts.")
                        .font(Theme.mono(.large))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .padding(.top, 8)

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

                VStack(spacing: 10) {
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
                    .accessibilityIdentifier("onboarding.interfaceLanguage")

                    Picker(selection: Binding(
                        get: { settings.language.agent },
                        set: { settings.language.agent = $0 }
                    )) {
                        ForEach(AgentLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    } label: {
                        Text("Agent language")
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.textDim)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("onboarding.agentLanguage")

                    Text("The interface language applies after a restart. The agent language is the one Uncoil writes in when it hands a task to an agent.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Agent CLIs

/// What is installed on this Mac, and where to get what is missing. Uncoil never
/// runs an installer itself: the command is offered to copy, and the vendor's
/// own install page is one click away.
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
            leading: { ProviderMark(provider: provider, size: 20) },
            title: provider.displayName,
            badge: path == nil ? String(localized: "Not found") : String(localized: "Installed"),
            badgeTint: path == nil ? Theme.warn : Theme.ok,
            detail: path.map { installedDetail(path: $0, version: version, provider: provider) }
                ?? String(localized: "No binary on this Mac's PATH. Install it, then rescan.")
        ) {
            if path == nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let command = installCommand(for: provider) {
                        OnboardingCommandRow(command: command)
                    }
                    if let page = installPage(for: provider) {
                        Link(destination: page) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                Text("Open the install page")
                            }
                            .font(Theme.mono(.small, .semibold))
                            .foregroundStyle(Theme.highlight)
                        }
                        .accessibilityIdentifier("onboarding.installPage.\(provider.rawValue)")
                    }
                }
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

    private func installPage(for provider: AgentProvider) -> URL? {
        switch provider {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        case .codex: URL(string: "https://developers.openai.com/codex/cli/")
        case .terminal: nil
        }
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

/// Starts from what is already on the machine: the logins the provider CLIs
/// carry are read out of their own config files and offered as-is. Making a
/// second, isolated profile is a separate question, asked underneath.
struct OnboardingAccountsStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var loggingIn: AccountProfile?
    @State private var newAccountProvider: AgentProvider?
    @State private var newAccountName = ""

    private struct Detected: Identifiable {
        let profile: AccountProfile
        let email: String?
        var id: UUID { profile.id }
    }

    private var detected: [Detected] {
        settings.accounts.map {
            Detected(
                profile: $0,
                email: settings.loggedInEmail(for: $0, profilesRoot: settings.profilesRootURL)
            )
        }
    }

    private var signedIn: [Detected] { detected.filter { $0.email != nil } }
    private var signedOut: [Detected] { detected.filter { $0.email == nil } }

    var body: some View {
        OnboardingScaffold(
            step: .accounts,
            title: signedIn.isEmpty
                ? String(localized: "Sign your agents in")
                : String(localized: "We found these logins"),
            subtitle: signedIn.isEmpty
                ? String(localized: "Uncoil reads the login each CLI already carries. None are signed in yet — the provider's own flow opens in a small terminal, and the credentials stay with the CLI.")
                : String(localized: "These come from the CLIs' own config files. Uncoil never sees the credentials themselves — use them as they are, or add an isolated profile below."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                ForEach(signedIn) { entry in
                    accountCard(entry, isSignedIn: true)
                }
                ForEach(signedOut) { entry in
                    accountCard(entry, isSignedIn: false)
                }

                OnboardingCard(
                    symbol: "person.badge.plus",
                    title: String(localized: "Want a second account?"),
                    detail: String(localized: "A profile gets its own config root (CLAUDE_CONFIG_DIR / CODEX_HOME), so a work login and a personal one never mix — and each session picks the profile it runs under.")
                ) {
                    HStack(spacing: 10) {
                        ForEach([AgentProvider.claude, .codex]) { provider in
                            Button(String(localized: "Add a \(provider.displayName) profile")) {
                                newAccountName = ""
                                newAccountProvider = provider
                            }
                            .buttonStyle(GhostButtonStyle())
                            .accessibilityIdentifier("onboarding.addAccount.\(provider.rawValue)")
                        }
                    }
                    .padding(.top, 2)
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
    private func accountCard(_ entry: Detected, isSignedIn: Bool) -> some View {
        OnboardingCard(
            leading: { ProviderMark(provider: entry.profile.provider, size: 18) },
            title: "\(entry.profile.provider.displayName) · \(entry.profile.name)",
            badge: entry.email ?? String(localized: "Not signed in"),
            badgeTint: isSignedIn ? Theme.ok : Theme.warn,
            detail: entry.profile.directoryName == nil
                ? String(localized: "The provider's own config root — the login you already use in the terminal.")
                : String(localized: "An isolated profile managed by Uncoil.")
        ) {
            HStack(spacing: 12) {
                Button(isSignedIn
                       ? String(localized: "Sign in again")
                       : String(localized: "Sign in")) {
                    loggingIn = entry.profile
                }
                .buttonStyle(isSignedIn
                             ? AnyButtonStyle(GhostButtonStyle())
                             : AnyButtonStyle(AccentButtonStyle()))
                .accessibilityIdentifier("onboarding.signIn.\(entry.profile.provider.rawValue)")

                if settings.accounts(for: entry.profile.provider).count > 1 {
                    Button(String(localized: "Make default")) {
                        settings.setDefaultAccount(entry.profile)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(.small, .semibold))
                    .foregroundStyle(Theme.highlight)
                }
            }
            .padding(.top, 2)
        }
    }

    private func createAccount() {
        guard let provider = newAccountProvider else { return }
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return newAccountProvider = nil }
        let profile = settings.addAccount(provider: provider, name: name)
        newAccountProvider = nil
        loggingIn = profile
    }
}
