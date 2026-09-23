import SwiftUI

// MARK: - Rows shared by the agent pages

/// One login of one agent. Rendered by `AgentSettingsPage`.
struct AccountRow: View {
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

/// The installed CLI of one agent: where it is, which version, and what
/// updating it would run. Rendered by `AgentSettingsPage`.
struct CLIToolRow: View {
    let provider: AgentProvider
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore

    private var path: String? { settings.binaryPath(for: provider) }
    private var updating: Bool { settings.cliUpdating.contains(provider.rawValue) }
    private var source: AgentInstallSource { settings.installSource(for: provider) }
    private var plan: AgentUpdatePlan { settings.updatePlan(for: provider) }
    private var availability: AgentUpdateAvailability { settings.updateAvailability(for: provider) }

    /// Sessions of this agent that a restart would actually touch.
    private var restartTargets: [UUID] {
        AgentProcessRestart.targets(
            sessions: projectStore.sessions,
            provider: provider,
            isLive: { TerminalRegistry.shared.hasTerminal(for: $0) },
            isAsleep: { id in
                projectStore.sessions.first { $0.id == id }?.sleepMode != nil
            }
        )
    }

    /// Where the launcher actually points. Two agents can be on `PATH` at
    /// paths that look alike and come from completely different installs; the
    /// far end of the symlink is the only place that says which.
    private var realPath: String? {
        path.flatMap { CLIToolService.resolvedPath(of: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                        if path != nil {
                            Text(source.label)
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
                } else {
                    control
                }
            }

            if path != nil {
                details
            }
            if let outcome = settings.cliUpdateOutcome[provider.rawValue] {
                Text(message(for: outcome))
                    .font(.caption)
                    .foregroundStyle(outcome.isFailure ? Theme.danger : Theme.ok)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            // Offered whenever this agent has something running, not only
            // after an update: an agent CLI reads its configuration and its
            // own code once at launch, so "restart it" is the answer to more
            // than one question. After an update it is the necessary next
            // step — Claude Code says so itself — and it is the only one that
            // used to mean visiting every session by hand.
            restartOffer
        }
    }

    /// One state per row, decided in one place.
    ///
    /// Every branch here used to be a separate question asked of separate
    /// fields, which is how a row came to say "new: 0.152.1" beside a button
    /// that could not deliver it: the version came from npm and the button ran
    /// Homebrew. `AgentUpdateAvailability` answers both from the same reading
    /// of how the tool was installed.
    @ViewBuilder
    private var control: some View {
        switch availability {
        case .available(_, let latest):
            HStack(spacing: 8) {
                Text("new: \(latest)").font(.caption).foregroundStyle(Theme.warn)
                Button("Update") { Task { await settings.updateCLI(provider) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cli.update.\(provider.rawValue)")
            }
        case .selfChecking:
            // No version to compare, and a button anyway. These four ship
            // their own updater and publish no list to read, so the only way
            // to find out is to run it — which is what the tool's own users do.
            Button("Check & Update") { Task { await settings.updateCLI(provider) } }
                .accessibilityIdentifier("cli.update.\(provider.rawValue)")
        case .upToDate:
            SettingsStatusLine(level: .ok, text: String(localized: "up to date"))
        case .noUpdater:
            SettingsStatusLine(level: .warning, text: String(localized: "no updater"))
        case .unchecked:
            // "up to date" is a claim rather than a placeholder.
            Text("checking…").font(.caption).foregroundStyle(Theme.textDim)
        case .notInstalled:
            SettingsStatusLine(level: .error, text: String(localized: "not installed"))
        }
    }

    /// Offered after an update, because most agent CLIs load themselves once
    /// at start: a session that was already running keeps running the version
    /// it launched with, and Claude Code says so out loud by asking to be
    /// restarted. Doing that by hand meant finding every session of that agent
    /// and restarting each — which is exactly the list Uncoil already has.
    @ViewBuilder
    private var restartOffer: some View {
        if let title = AgentProcessRestart.offer(
            count: restartTargets.count, provider: provider
        ) {
            Button(title) { restartRunningSessions() }
                .controlSize(.small)
                .accessibilityIdentifier("cli.restart.\(provider.rawValue)")
        }
    }

    private func restartRunningSessions() {
        SessionActions(projects: projectStore, sessions: sessionStore).restart(restartTargets)
    }

    /// Path, real path and the update command, in one place.
    ///
    /// The command is shown rather than merely run because it is the answer to
    /// "why did the update do nothing" — an `npm install -g` pointed at a Node
    /// the binary on `PATH` does not come from looks identical to a working
    /// one until you can read which npm it uses.
    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let path {
                SettingsDetailLine(label: String(localized: "path"), value: path)
            }
            if let realPath {
                SettingsDetailLine(label: String(localized: "resolves to"), value: realPath)
            }
            switch plan {
            case .run(let command):
                SettingsDetailLine(
                    label: String(localized: "updates with"), value: command, wraps: true
                )
            case .cannot(let reason):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("updates with")
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 76, alignment: .leading)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func message(for outcome: AgentUpdateOutcome) -> String {
        switch outcome {
        case .updated(let from, let to):
            if let from {
                return String(localized: "Updated: \(from) → \(to)")
            }
            return String(localized: "Updated to \(to)")
        case .ranButUnchanged(let version):
            return String(localized: "The update command succeeded but \(provider.displayName) is still \(version). It most likely installed into a different Node than the one this binary comes from — the command above says which npm was used.")
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Input

/// Typing and pasting, which is app behaviour rather than agent policy.
struct InputSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore

    private let providers: [AgentProvider] = AgentProvider.agents

    var body: some View {
        SettingsPage(
            title: String(localized: "Keyboard and Input"),
            subtitle: String(localized: "How keys and the clipboard behave in a session's prompt.")
        ) {
            // Was a "Keyboard" section on the General page. Keyboard settings
            // in two places is the same defect this reorganisation is for.
            Section("Modifier keys") {
                Toggle(isOn: Binding(
                    get: { settings.optionAsMetaKey },
                    set: { settings.setOptionAsMetaKey($0) }
                )) {
                    SettingsLabel(
                        title: String(localized: "Use Option as Meta"),
                        detail: String(
                            localized: "Off, Option types the character your keyboard layout prints — ⌥Q gives @ on a Turkish-Q layout. On, Option is sent to the agent as Meta (⌥f, ⌥b). Applies immediately."
                        ),
                        symbol: "option"
                    )
                }
                .settingsID("general.optionAsMeta")
            }

            Section {
                ForEach(providers) { provider in
                    Toggle(isOn: Binding(
                        get: { settings.shiftEnterNewline(for: provider) },
                        set: { settings.setShiftEnterNewline($0, for: provider) }
                    )) {
                        SettingsLabel(title: provider.displayName)
                    }
                    .settingsID("agentBehavior.shiftEnter.\(provider.rawValue)")
                }
            } header: {
                Text("Shift+Enter for a newline")
            } footer: {
                SettingsNote(
                    String(localized: "Shift+Enter (and Option+Enter) inserts a newline in the prompt instead of submitting, using the sequence each agent expects (\\⏎ for Claude Code, ⌃J for Codex). Applies to open sessions immediately.")
                )
            }

            Section {
                Picker(selection: Binding(
                    get: { settings.imagePasteMode },
                    set: { settings.setImagePasteMode($0) }
                )) {
                    ForEach(ImagePasteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Pasting an image"),
                        detail: settings.imagePasteMode.detail
                    )
                }
                .settingsID("agentBehavior.imagePaste")
            } header: {
                Text("Clipboard")
            } footer: {
                SettingsNote(
                    String(localized: "Only ⌘V of an image is affected. Pasting text, a path or anything else is never touched, and neither is a plain terminal session.")
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.input.container")
    }
}


