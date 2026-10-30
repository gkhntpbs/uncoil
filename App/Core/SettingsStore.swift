import CryptoKit
import Foundation

enum SessionQuitBehavior: String, Codable, CaseIterable, Identifiable {
    case keepSessionsRunning
    case terminateAllAgents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepSessionsRunning: String(localized: "Keep sessions running")
        case .terminateAllAgents: String(localized: "Terminate all agents on quit")
        }
    }

    var detail: String {
        switch self {
        case .keepSessionsRunning:
            String(localized: "Agents keep running inside the runtime daemon even after Uncoil closes.")
        case .terminateAllAgents:
            String(localized: "Every running agent and terminal process is closed when you quit Uncoil.")
        }
    }
}

/// User settings: account profiles, defaults, resolved binary paths.
@MainActor
final class SettingsStore: ObservableObject {
    struct Persisted: Codable {
        var accounts: [AccountProfile] = []
        var defaultAccountByProvider: [String: UUID] = [:]
        var defaultProvider: AgentProvider = .claude
        var resolvedBinaries: [String: String] = [:]
        var extraArguments: [String: String] = [:]
        var preferredEditor: PreferredEditor = .vscode
        var notifications: NotificationPrefs = NotificationPrefs()
        /// Configured session presets. Optional for backward compatibility with
        /// settings.json written before presets existed; nil/empty ⇒ built-ins.
        var presets: [SessionPreset]? = nil
        /// Per-provider terminal behavior (Shift+Enter newline, …). Optional for
        /// backward compatibility; a missing entry ⇒ the provider's defaults.
        var providerBehaviors: [String: ProviderBehavior]? = nil
        /// Command-palette hotkey. Optional for backward compatibility with
        /// settings.json written before it was configurable; nil ⇒ ⌘K.
        var commandPaletteHotkey: HotkeyBinding? = nil
        /// How loudly the sidebar pulses for a session that wants attention.
        /// Optional for backward compatibility; nil ⇒ subtle.
        var attentionEmphasis: AttentionEmphasis? = nil
        var usageWarningsEnabled: Bool? = nil
        var usageWarningThreshold: Double? = nil
        var quotaOptimization: QuotaOptimizationPrefs? = nil
        /// "Option is Meta" in the terminal. Optional for backward
        /// compatibility; nil ⇒ off, Option types the layout's character.
        var optionAsMetaKey: Bool? = nil
        var sessionQuitBehavior: SessionQuitBehavior? = nil
        var transcriptRetentionPolicy: TranscriptRetentionPolicy? = nil
        /// Minutes a permission request may sit unanswered; 0 = never
        /// expires. Optional for backward compatibility; nil ⇒ 10 minutes.
        var permissionTimeoutMinutes: Int? = nil
        /// Menu-bar monitor appearance and contents; nil ⇒ defaults.
        var menuBar: MenuBarPrefs? = nil
        /// What ⌘V does when the clipboard holds an image; nil ⇒ the default.
        var imagePasteMode: ImagePasteMode? = nil
        /// Which shortcuts the quick-launch strip offers, and in what order.
        /// nil ⇒ not configured, which resolves to what is installed.
        var launcher: LauncherPrefs? = nil
        /// Interface and agent-prompt language; nil ⇒ follow the system.
        var language: LanguagePrefs? = nil
        /// Onboarding version the user last went through; nil ⇒ never seen it.
        var onboardingVersion: Int? = nil
        /// Onboarding steps actually completed (skipped ones stay out).
        var onboardingCompletedSteps: [String]? = nil
        /// Capabilities stamped onto newly created sessions; nil ⇒ the control
        /// plane's own default grant set.
        var sessionCapabilityDefaults: [String]? = nil
        /// Where the user told Uncoil to look for a CLI, keyed by command name
        /// (`hermes`, `cursor-agent`, …) rather than by agent, because that is
        /// what `BinarySearchPath` searches by and what session launch and the
        /// Extensions screen both ask it for. nil ⇒ nobody has had to.
        var agentBinaryLocations: [String: String]? = nil
        /// Uncoil Auto: which agents it may reach, and how its runs work.
        /// nil ⇒ defaults.
        var uncoilAuto: UncoilAutoSettings? = nil
        /// Sessions a sidebar list shows before "Load more"; 0 = all of them.
        /// nil = `SidebarSessionLimit.default`.
        var sidebarSessionLimit: Int? = nil
        enum CodingKeys: String, CodingKey, CaseIterable {
            case accounts
            case defaultAccountByProvider
            case defaultProvider
            case resolvedBinaries
            case extraArguments
            case preferredEditor
            case notifications
            case presets
            case providerBehaviors
            case commandPaletteHotkey
            case attentionEmphasis
            case usageWarningsEnabled
            case usageWarningThreshold
            case quotaOptimization
            case optionAsMetaKey
            case sessionQuitBehavior
            case transcriptRetentionPolicy
            case permissionTimeoutMinutes
            case menuBar
            case imagePasteMode
            case launcher
            case language
            case onboardingVersion
            case onboardingCompletedSteps
            case sessionCapabilityDefaults
            case agentBinaryLocations
            case uncoilAuto
            case sidebarSessionLimit
        }
    }

    @Published private(set) var accounts: [AccountProfile] = []
    @Published var defaultProvider: AgentProvider = .claude
    @Published private(set) var defaultAccountByProvider: [String: UUID] = [:]
    @Published private(set) var resolvedBinaries: [String: String] = [:]
    /// User-chosen CLI locations, keyed by command name. Mirrored into
    /// `BinarySearchPath` on every change so the two can never disagree.
    @Published private(set) var agentBinaryLocations: [String: String] = [:]
    /// Extra CLI arguments appended to the agent launch command, per provider.
    @Published var extraArguments: [String: String] = [:]
    @Published var preferredEditor: PreferredEditor = .vscode
    @Published var notifications = NotificationPrefs()
    /// Configured session presets; nil ⇒ the built-in defaults are used.
    @Published var configuredPresets: [SessionPreset]? = nil
    /// Per-provider terminal behavior overrides; a missing key ⇒ provider default.
    @Published var providerBehaviors: [String: ProviderBehavior] = [:]
    /// The hotkey that toggles the command palette. Defaults to ⌘K.
    @Published private(set) var commandPaletteHotkey: HotkeyBinding = .commandPaletteDefault
    /// How loudly the sidebar pulses for a session that wants attention.
    @Published private(set) var attentionEmphasis: AttentionEmphasis = .subtle
    /// Whether an account running low is worth saying anything about. The
    /// figures stay either way — this is about being told, not about knowing.
    @Published private(set) var usageWarningsEnabled = true
    /// Percent remaining at which an account is called low. Fifteen by default,
    /// which on a five-hour window is roughly enough time to finish a thought.
    @Published private(set) var usageWarningThreshold = UsageAlert.defaultThreshold
    @Published private(set) var quotaOptimization = QuotaOptimizationPrefs()
    @Published private(set) var launcher: LauncherPrefs = .default
    @Published private(set) var imagePasteMode: ImagePasteMode = .default
    /// When true, Option is sent to the agent as Meta (⌥f, ⌥b, ⌥.). When false
    /// — the default, matching Terminal.app — Option belongs to the keyboard
    /// layout, so a Turkish-Q layout can type `@` with ⌥Q and `#` with ⌥3.
    @Published private(set) var optionAsMetaKey = false
    @Published private(set) var sessionQuitBehavior: SessionQuitBehavior = .keepSessionsRunning
    @Published private(set) var transcriptRetentionPolicy: TranscriptRetentionPolicy = .disabled
    /// Minutes before an unanswered permission request expires; 0 = never.
    @Published private(set) var permissionTimeoutMinutes = 10
    /// Menu-bar monitor appearance and contents.
    @Published var menuBar = MenuBarPrefs()
    /// Interface language and the language agent prompts are written in.
    @Published var language = LanguagePrefs() {
        didSet {
            guard language != oldValue else { return }
            Self.applyInterfaceLanguage(language.interface)
            save()
        }
    }
    /// Onboarding version the user last went through; nil = never seen it.
    @Published private(set) var onboardingVersion: Int?
    /// Onboarding steps the user actually completed.
    @Published private(set) var onboardingCompletedSteps: Set<String> = []
    /// Extra capabilities the user opted into during onboarding, stamped onto
    /// new sessions. nil = the control plane's own default grant set.
    @Published private(set) var sessionCapabilityDefaults: [String]?
    /// Uncoil Auto's reach and its run harness.
    @Published private(set) var uncoilAuto: UncoilAutoSettings = .default
    /// Sessions a sidebar list shows before "Load more"; 0 = all of them.
    @Published private(set) var sidebarSessionLimit = SidebarSessionLimit.default
    /// Installed CLI versions ("claude" -> "1.0.83 (Claude Code)").
    @Published var cliVersions: [String: String] = [:]
    /// Providers with an update currently running.
    @Published var cliUpdating: Set<String> = []
    /// Last update-run output per provider.
    /// What the last update attempt actually did, per provider.
    @Published var cliUpdateOutcome: [String: AgentUpdateOutcome] = [:]
    /// Latest published versions from the registry.
    @Published var cliLatest: [String: String] = [:]
    @Published var cliChecking = false

    private var settingsDocument = SettingsDocument()
    private var isLoadingSettings = false
    private var migrationBackupCreated = false
    private let fileURL: URL
    private let profilesRoot: URL
    let transcriptStore: SessionTranscriptStore

    init(directory: URL? = nil) {
        let base = directory ?? ProjectStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("settings.json")
        profilesRoot = base.appendingPathComponent("profiles", isDirectory: true)
        transcriptStore = SessionTranscriptStore(dataDirectory: base)
        load()
        Self.applyInterfaceLanguage(language.interface)
        transcriptStore.prune(policy: transcriptRetentionPolicy)
        ApplicationLifecycle.shared.sessionQuitBehavior = sessionQuitBehavior
        // Mirrored here rather than in `load()`, which returns early when there
        // is no settings.json — on a first launch that left the global holding
        // whatever the last store had put there.
        AttentionMotion.shared.emphasis = attentionEmphasis
        BinarySearchPath.setUserLocations(agentBinaryLocations)
        ensureDefaultAccounts()
    }

    var profilesRootURL: URL { profilesRoot }

    /// Effective session presets: the user's configured list when non-empty,
    /// otherwise the built-in defaults.
    ///
    /// Nothing writes this list any more. A preset is a role — what a child
    /// session started through `create_child` is allowed to do — and editing
    /// roles by hand in Settings asked the user to design a permission model
    /// to use the app. The built-in roles are the model now. A list written by
    /// an older build is still read and still honoured, so nobody's setup
    /// changes under them.
    var presets: [SessionPreset] {
        if let configured = configuredPresets, !configured.isEmpty { return configured }
        return SessionPreset.builtInDefaults
    }

    func preset(id: String) -> SessionPreset? {
        presets.first { $0.id == id }
    }

    // MARK: - Provider behavior

    /// Effective Shift+Enter-newline setting for a provider: the user override
    /// when set, otherwise the provider's built-in default.
    func shiftEnterNewline(for provider: AgentProvider) -> Bool {
        providerBehaviors[provider.rawValue]?.shiftEnterNewline ?? provider.defaultShiftEnterNewline
    }

    func setShiftEnterNewline(_ value: Bool, for provider: AgentProvider) {
        var behavior = providerBehaviors[provider.rawValue] ?? ProviderBehavior()
        behavior.shiftEnterNewline = value
        providerBehaviors[provider.rawValue] = behavior
        save()
    }

    /// The mode a session launches with when nobody picked one.
    ///
    /// The provider's own, for every provider. It used to be `manual` for
    /// Claude and `askForApproval` for Codex, which meant Uncoil put
    /// `--permission-mode` and `--sandbox`/`--ask-for-approval` on the command
    /// line of a user who had never asked for either — overruling what they
    /// had set in the CLI's own configuration, every launch, with no way to
    /// stop it. Uncoil adds no flag it was not asked for; that has to include
    /// the flags it was not asked for by default.
    func workingMode(for provider: AgentProvider) -> AgentWorkingMode {
        let fallback: AgentWorkingMode = .providerDefault
        let mode = (providerBehaviors[provider.rawValue]?.workingMode ?? fallback)
            .normalized(for: provider)
        return AgentWorkingMode.options(for: provider).contains(mode)
            ? mode
            : fallback
    }

    func setWorkingMode(_ mode: AgentWorkingMode, for provider: AgentProvider) {
        guard AgentWorkingMode.options(for: provider).contains(mode) else { return }
        var behavior = providerBehaviors[provider.rawValue] ?? ProviderBehavior()
        behavior.workingMode = mode
        providerBehaviors[provider.rawValue] = behavior
        save()
    }

    func workingModeArguments(for provider: AgentProvider) -> [String] {
        workingMode(for: provider).launchArguments(for: provider)
    }

    // MARK: - Command palette hotkey

    func setCommandPaletteHotkey(_ binding: HotkeyBinding) {
        commandPaletteHotkey = binding
        save()
    }

    func resetCommandPaletteHotkey() {
        setCommandPaletteHotkey(.commandPaletteDefault)
    }

    func setQuotaOptimization(_ value: QuotaOptimizationPrefs) {
        var value = value
        value.resetWithinHours = min(72, max(1, value.resetWithinHours))
        value.minimumUnusedPercent = min(90, max(5, value.minimumUnusedPercent))
        quotaOptimization = value
        save()
    }

    func setUsageWarningsEnabled(_ enabled: Bool) {
        usageWarningsEnabled = enabled
        save()
    }

    /// Clamped rather than trusted: a threshold of 0 would only ever fire once
    /// the account was already empty, and one of 100 would fire always.
    func setUsageWarningThreshold(_ percent: Double) {
        usageWarningThreshold = min(90, max(1, percent))
        save()
    }

    func setAttentionEmphasis(_ emphasis: AttentionEmphasis) {
        attentionEmphasis = emphasis
        AttentionMotion.shared.emphasis = emphasis
        save()
    }

    /// The strip's contents, resolved against what is installed.
    ///
    /// `resolvedBinaries` is what "installed" means here: it is filled by the
    /// same detection the Agents settings page shows, so the strip and that
    /// page can never disagree about which CLIs exist.
    var launcherProviders: [AgentProvider] {
        LauncherPrefs.resolved(launcher, installed: installedProviders)
    }

    // MARK: - Uncoil Auto

    func updateUncoilAuto(_ change: (inout UncoilAutoSettings) -> Void) {
        var next = uncoilAuto
        change(&next)
        guard next != uncoilAuto else { return }
        uncoilAuto = next
        save()
    }

    /// Changes how Auto runs are set up.
    func updateAutoHarness(_ change: (inout AutoHarnessSettings) -> Void) {
        updateUncoilAuto { change(&$0.harness) }
    }

    /// Whether Uncoil Auto may address the agent by default. Turning one off
    /// pins the list: agents installed later are not let in behind the
    /// user's back.
    func setUncoilAutoAllows(_ provider: AgentProvider, _ allowed: Bool) {
        updateUncoilAuto { settings in
            var list = Set(settings.allowedAgents ?? AgentProvider.agents.map(\.rawValue))
            if allowed { list.insert(provider.rawValue) } else { list.remove(provider.rawValue) }
            settings.allowedAgents = AgentProvider.agents.map(\.rawValue).filter(list.contains)
        }
    }

    var installedProviders: Set<AgentProvider> {
        Set(AgentProvider.agents.filter { resolvedBinaries[$0.rawValue] != nil })
    }

    func setSidebarSessionLimit(_ limit: Int) {
        sidebarSessionLimit = max(0, limit)
        save()
    }

    func setImagePasteMode(_ mode: ImagePasteMode) {
        imagePasteMode = mode
        save()
    }

    func setLauncherOrder(_ order: [AgentProvider]) {
        guard order.count >= LauncherPrefs.minimumItems else { return }
        launcher.order = order
        save()
    }

    func setOptionAsMetaKey(_ enabled: Bool) {
        optionAsMetaKey = enabled
        TerminalRegistry.shared.applyOptionAsMetaToLiveTerminals(enabled)
        save()
    }

    func setSessionQuitBehavior(_ behavior: SessionQuitBehavior) {
        sessionQuitBehavior = behavior
        ApplicationLifecycle.shared.sessionQuitBehavior = behavior
        save()
    }

    func setTranscriptRetentionPolicy(_ policy: TranscriptRetentionPolicy) {
        transcriptRetentionPolicy = policy
        transcriptStore.prune(policy: policy)
        save()
    }

    /// Answer window handed to `PermissionService`; nil = no expiry.
    var permissionTimeout: TimeInterval? {
        permissionTimeoutMinutes <= 0 ? nil : TimeInterval(permissionTimeoutMinutes * 60)
    }

    func setPermissionTimeoutMinutes(_ minutes: Int) {
        permissionTimeoutMinutes = max(0, minutes)
        save()
    }

    func clearTranscripts() {
        transcriptStore.clearAll()
    }

    // MARK: - Accounts

    func accounts(for provider: AgentProvider) -> [AccountProfile] {
        accounts.filter { $0.provider == provider }
    }

    func defaultAccount(for provider: AgentProvider) -> AccountProfile? {
        if let id = defaultAccountByProvider[provider.rawValue],
           let profile = accounts.first(where: { $0.id == id }) {
            return profile
        }
        return accounts(for: provider).first
    }

    func account(id: UUID?) -> AccountProfile? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    @discardableResult
    func addAccount(provider: AgentProvider, name: String) -> AccountProfile {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let directoryName = slug.isEmpty ? UUID().uuidString : slug
        let profile = AccountProfile(provider: provider, name: name, directoryName: directoryName)
        if let dir = profile.configDirectory(profilesRoot: profilesRoot) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        accounts.append(profile)
        save()
        return profile
    }

    func removeAccount(_ profile: AccountProfile) {
        // Default (nil-directory) profiles cannot be removed — they represent
        // the provider's own ~/.claude state, which Uncoil does not own.
        guard profile.directoryName != nil else { return }
        accounts.removeAll { $0.id == profile.id }
        if defaultAccountByProvider[profile.provider.rawValue] == profile.id {
            defaultAccountByProvider[profile.provider.rawValue] = nil
        }
        save()
    }

    func setDefaultAccount(_ profile: AccountProfile) {
        defaultAccountByProvider[profile.provider.rawValue] = profile.id
        save()
    }

    /// Logged-in identity for a profile, read from the provider's own config
    /// files. Returns nil when nobody is logged in.
    nonisolated func loggedInEmail(for profile: AccountProfile, profilesRoot: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch profile.provider {
        case .claude:
            let configFile = profile.configDirectory(profilesRoot: profilesRoot)?
                .appendingPathComponent(".claude.json")
                ?? home.appendingPathComponent(".claude.json")
            guard
                let data = try? Data(contentsOf: configFile),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let oauth = object["oauthAccount"] as? [String: Any]
            else { return nil }
            return oauth["emailAddress"] as? String

        case .codex:
            // Codex stores auth at CODEX_HOME/auth.json (default ~/.codex).
            let authFile = profile.configDirectory(profilesRoot: profilesRoot)?
                .appendingPathComponent("auth.json")
                ?? home.appendingPathComponent(".codex/auth.json")
            guard
                let data = try? Data(contentsOf: authFile),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Best effort: pull the email out of the id_token JWT payload.
            let idToken = (object["tokens"] as? [String: Any])?["id_token"] as? String
                ?? object["id_token"] as? String
            if let idToken {
                let parts = idToken.split(separator: ".")
                if parts.count >= 2 {
                    var payload = String(parts[1])
                        .replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/")
                    while payload.count % 4 != 0 { payload += "=" }
                    if let decoded = Data(base64Encoded: payload),
                       let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                       let email = claims["email"] as? String {
                        return email
                    }
                }
            }
            return "linked"  // auth file exists but no readable identity

        // Nothing is read for Gemini or OpenCode: where their CLIs keep an
        // identity, and in what shape, is not verified here. OpenCode's
        // credentials live outside its config root entirely
        // (~/.local/share/opencode), and reporting "linked" off a file whose
        // meaning is a guess would be worse than reporting nothing.
        //
        // Hermes is the same: `~/.hermes/auth.json` holds per-provider
        // credential state, and whether an identity is in it depends on
        // which provider the user signed in to. `HermesAdapter` still
        // reports the file's presence as "somebody signed in", which is
        // all it can honestly say.
        case .gemini, .opencode, .grok, .cursor, .hermes, .terminal, .uncoil:
            return nil
        }
    }

    // MARK: - Binary resolution

    func binaryPath(for provider: AgentProvider) -> String? {
        resolvedBinaries[provider.rawValue]
    }

    // MARK: - User-chosen CLI locations

    /// What came of pointing Uncoil at a location, so the UI can say something
    /// specific instead of leaving the row unchanged and the user guessing.
    enum AgentLocationOutcome: Equatable {
        case resolved(String)
        /// The path is fine; there is just no `command` under it.
        case nothingExecutableThere
    }

    /// Points Uncoil at a location for one CLI. The path may be the executable
    /// itself or a directory holding it.
    ///
    /// Refuses a location that finds nothing rather than storing it: a setting
    /// that visibly did nothing is how "I told it where the agent is and it
    /// still says not found" happens, and the caller can only explain that if
    /// this says so.
    @discardableResult
    func setAgentBinaryLocation(
        _ path: String, forCommand command: String
    ) -> AgentLocationOutcome {
        guard let resolved = BinarySearchPath.resolveUserLocation(path, command: command) else {
            return .nothingExecutableThere
        }
        agentBinaryLocations[command] = (path as NSString).expandingTildeInPath
        applyAgentBinaryLocations(invalidating: command)
        return .resolved(resolved)
    }

    func clearAgentBinaryLocation(forCommand command: String) {
        guard agentBinaryLocations.removeValue(forKey: command) != nil else { return }
        applyAgentBinaryLocations(invalidating: command)
    }

    func agentBinaryLocation(forCommand command: String) -> String? {
        agentBinaryLocations[command]
    }

    /// Mirrors the locations into the search path and drops the cached
    /// resolution for whichever providers run `command`.
    ///
    /// Dropping the cache is the part that is easy to forget and impossible to
    /// diagnose: `resolveBinaries()` only re-resolves an entry once its old path
    /// stops being executable, so without this a chosen location would be
    /// obeyed by the Extensions screen and ignored by session launch until the
    /// old copy was deleted.
    private func applyAgentBinaryLocations(invalidating command: String) {
        BinarySearchPath.setUserLocations(agentBinaryLocations)
        for provider in AgentProvider.agents where provider.launchCommand == command {
            resolvedBinaries[provider.rawValue] = nil
        }
        save()
    }

    /// Resolves the provider CLI through the user's login shell once and caches it.
    func resolveBinaries() async {
        for provider in AgentProvider.agents {
            // Drop cached paths whose binary vanished (reinstall/move).
            if let cached = resolvedBinaries[provider.rawValue],
               !FileManager.default.isExecutableFile(atPath: cached) {
                resolvedBinaries[provider.rawValue] = nil
            }
            guard resolvedBinaries[provider.rawValue] == nil,
                  let command = provider.launchCommand else { continue }
            let path = await Task.detached(priority: .utility) {
                Self.which(command)
            }.value
            if let path {
                resolvedBinaries[provider.rawValue] = path
            }
        }
        save()
    }

    // MARK: - CLI versions & updates

    func refreshCLIVersions() async {
        for provider in AgentProvider.agents {
            guard let path = binaryPath(for: provider) else { continue }
            let version = await Task.detached(priority: .utility) {
                CLIToolService.version(binaryPath: path)
            }.value
            if let version {
                cliVersions[provider.rawValue] = version
            }
        }
    }

    /// What the Agents screen says about one agent, and whether it offers a
    /// button. One computation, so the row, the badge and the update action can
    /// never disagree about whether there is something to do.
    func updateAvailability(for provider: AgentProvider) -> AgentUpdateAvailability {
        let source = installSource(for: provider)
        return AgentUpdateCheck.availability(
            installed: binaryPath(for: provider) == nil
                ? nil
                : cliVersions[provider.rawValue],
            latest: cliLatest[provider.rawValue],
            plan: updatePlan(for: provider),
            versionSource: AgentUpdateCheck.versionSource(provider: provider, source: source),
            isNewer: CLIToolService.isNewer
        )
    }

    func updateAvailable(for provider: AgentProvider) -> Bool {
        updateAvailability(for: provider).isPending
    }

    /// Agents with a newer version waiting. What the badge counts.
    var pendingCLIUpdates: [AgentProvider] {
        AgentProvider.agents.filter { updateAvailability(for: $0).isPending }
    }

    /// Refreshes installed versions and asks each install's own channel
    /// whether there is anything newer.
    func checkCLIUpdates() async {
        cliChecking = true
        await refreshCLIVersions()
        // Homebrew is asked once for everything rather than once per agent:
        // `brew outdated` is a second of work and two agents can come from it.
        let brew = await Task.detached(priority: .utility) {
            CLIToolService.brewOutdated()
        }.value
        for provider in AgentProvider.agents {
            let source = installSource(for: provider)
            if let latest = await CLIToolService.latestVersion(
                provider: provider,
                source: source,
                binaryPath: binaryPath(for: provider),
                installed: cliVersions[provider.rawValue],
                brewOutdated: brew
            ) {
                cliLatest[provider.rawValue] = latest
            } else {
                // A channel that cannot answer must clear the last answer it
                // gave, or a tool that moves from npm to Homebrew keeps
                // advertising the npm version forever.
                cliLatest[provider.rawValue] = nil
            }
        }
        cliChecking = false
    }

    /// How this install would be updated, and by what command.
    func updatePlan(for provider: AgentProvider) -> AgentUpdatePlan {
        CLIToolService.updatePlan(provider: provider, source: installSource(for: provider))
    }

    func installSource(for provider: AgentProvider) -> AgentInstallSource {
        binaryPath(for: provider).map {
            CLIToolService.source(forBinaryAt: $0, provider: provider)
        } ?? .unknown
    }

    func updateCLI(_ provider: AgentProvider) async {
        guard !cliUpdating.contains(provider.rawValue) else { return }
        guard case .run(let command) = updatePlan(for: provider) else {
            if case .cannot(let reason) = updatePlan(for: provider) {
                cliUpdateOutcome[provider.rawValue] = .failed(reason)
            }
            return
        }
        // What the version was before, so "the command exited 0" can be told
        // apart from "the tool actually moved".
        let before = cliVersions[provider.rawValue]
        cliUpdating.insert(provider.rawValue)
        cliUpdateOutcome[provider.rawValue] = nil
        let result = await Task.detached(priority: .userInitiated) {
            CLIToolService.runUpdate(command: command)
        }.value
        cliUpdating.remove(provider.rawValue)
        // Path may have changed (e.g. npm relink); re-resolve then re-read.
        resolvedBinaries[provider.rawValue] = nil
        await resolveBinaries()
        await checkCLIUpdates()
        cliUpdateOutcome[provider.rawValue] = AgentCLIInstall.outcome(
            succeeded: result.success,
            output: result.output,
            before: before,
            after: cliVersions[provider.rawValue]
        )
    }

    /// Resolves a CLI by name using well-known install locations and, failing
    /// those, the login shell's own PATH. Reused by the control-plane adapters
    /// to locate optional external drivers (agent-browser / cua-driver).
    nonisolated static func which(_ command: String) -> String? {
        // 1) Well-known install locations first: GUI apps start with a
        //    minimal PATH, and users often extend PATH only in ~/.zshrc.
        //    Shared with the Extensions adapters through `BinarySearchPath`, so
        //    both answer "installed?" the same way.
        if let path = BinarySearchPath.locate(command) { return path }

        // 2) Anywhere else the login shell would look. This used to run
        //    `command -v <name>` in a fresh `zsh -l -i` per lookup, which is
        //    one shell spawn per *miss* — and a miss is the common case, since
        //    a machine has a couple of these CLIs and is asked about all of
        //    them. Asking once for the whole PATH and then testing files makes
        //    the seventh lookup free.
        for directory in loginShellPATH {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The directories on an interactive login shell's PATH, minus the ones
    /// `BinarySearchPath` already covers.
    nonisolated static var loginShellPATH: [String] {
        let known = Set(BinarySearchPath.directories())
        return interactivePATH.filter { !known.contains($0) }
    }

    /// Exactly what an interactive login shell has on its PATH, in its order.
    ///
    /// The order is the part that matters and the part that used to be lost.
    /// A machine can have two Node installations — Homebrew's and nvm's — and
    /// which one a command resolves to is decided by which directory comes
    /// first. Anything that runs a tool on the user's behalf has to run it
    /// with *this* PATH, or it runs a different program with the same name.
    ///
    /// Resolved once per process — `static let` is lazy and its initialiser
    /// runs exactly once even under concurrent access — because sourcing a
    /// user's shell profile is expensive and its answer does not change while
    /// the app is open. Never call this from the main actor: the first caller
    /// pays for the spawn.
    nonisolated static let interactivePATH: [String] = {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        // -l -i sources both zprofile and zshrc, which is where a user's PATH
        // additions actually live.
        process.arguments = ["-l", "-i", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded rather than piped: an unread pipe fills at 64 KB and the
        // shell blocks writing into it forever, taking `waitUntilExit` — and
        // whatever was waiting on this — down with it. A chatty ~/.zshrc is
        // enough to do that.
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        // A profile that prompts, or waits on a network mount, must not hang
        // the app: read on a worker, give it a few seconds, then kill it.
        let output = DispatchGroup()
        output.enter()
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.leave()
        }
        if output.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }()

    // MARK: - Onboarding

    /// Whether the first-run flow should open on launch.
    var shouldPresentOnboarding: Bool {
        OnboardingFlow.shouldPresent(stampedVersion: onboardingVersion)
    }

    /// Actionable steps still undone — what the sidebar's resume row counts.
    ///
    /// A flow the user has been all the way through has no remainder, whatever
    /// they answered along the way: the only exits are Skip and the last page,
    /// and both mean "stop asking me". Someone who declined to add a project
    /// during setup was otherwise told to finish setup on every launch
    /// afterwards, forever. A version bump still reopens the flow — that is
    /// `shouldPresentOnboarding`'s job — and the new steps are counted then.
    var remainingOnboardingSteps: [OnboardingStep] {
        guard onboardingVersion != OnboardingFlow.currentVersion else { return [] }
        return OnboardingFlow.remaining(completed: onboardingCompletedSteps)
    }

    func markOnboardingStepCompleted(_ step: OnboardingStep) {
        guard step.isActionable, !onboardingCompletedSteps.contains(step.rawValue) else { return }
        onboardingCompletedSteps.insert(step.rawValue)
        save()
    }

    /// Stamps the flow as seen. Called both when the user reaches the end and
    /// when they skip out of it: either way it must not reopen by itself.
    func finishOnboarding() {
        onboardingVersion = OnboardingFlow.currentVersion
        save()
    }

    /// Starts the whole flow over — Settings → About.
    func resetOnboarding() {
        onboardingVersion = nil
        onboardingCompletedSteps = []
        save()
    }

    /// Capabilities stamped onto new sessions. Passing the control plane's own
    /// default set back in is stored as "no override" so a later change to the
    /// defaults still reaches sessions created today.
    func setSessionCapabilityDefaults(_ capabilities: Set<String>?) {
        if let capabilities, capabilities != PolicyEngine.defaultGrants {
            sessionCapabilityDefaults = capabilities.sorted()
        } else {
            sessionCapabilityDefaults = nil
        }
        ProjectStore.defaultSessionCapabilities = sessionCapabilityDefaults
        save()
    }

    /// The effective capability set for a new session.
    var effectiveSessionCapabilities: Set<String> {
        sessionCapabilityDefaults.map(Set.init) ?? PolicyEngine.defaultGrants
    }

    // MARK: - Persistence

    private func ensureDefaultAccounts() {
        for provider in AgentProvider.agents
        where !accounts.contains(where: { $0.provider == provider && $0.directoryName == nil }) {
            accounts.append(AccountProfile(provider: provider, name: "Default", directoryName: nil))
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = settingsDocument.decode(data) else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        accounts = decoded.accounts
        defaultAccountByProvider = decoded.defaultAccountByProvider
        defaultProvider = decoded.defaultProvider
        resolvedBinaries = decoded.resolvedBinaries
        agentBinaryLocations = decoded.agentBinaryLocations ?? [:]
        extraArguments = decoded.extraArguments
        preferredEditor = decoded.preferredEditor
        notifications = decoded.notifications
        configuredPresets = decoded.presets
        providerBehaviors = decoded.providerBehaviors ?? [:]
        commandPaletteHotkey = decoded.commandPaletteHotkey ?? .commandPaletteDefault
        attentionEmphasis = decoded.attentionEmphasis ?? .subtle
        usageWarningsEnabled = decoded.usageWarningsEnabled ?? true
        usageWarningThreshold = decoded.usageWarningThreshold ?? UsageAlert.defaultThreshold
        quotaOptimization = decoded.quotaOptimization ?? QuotaOptimizationPrefs()
        launcher = decoded.launcher ?? .default
        imagePasteMode = decoded.imagePasteMode ?? .default
        sidebarSessionLimit = max(0, decoded.sidebarSessionLimit ?? SidebarSessionLimit.default)
        optionAsMetaKey = decoded.optionAsMetaKey ?? false
        sessionQuitBehavior = decoded.sessionQuitBehavior ?? .keepSessionsRunning
        transcriptRetentionPolicy = decoded.transcriptRetentionPolicy ?? .disabled
        permissionTimeoutMinutes = decoded.permissionTimeoutMinutes ?? 10
        // The monitor's on/off switch used to live in UserDefaults; carry a
        // deliberate "off" over so the item does not reappear on upgrade.
        var restoredMenuBar = decoded.menuBar ?? MenuBarPrefs()
        if decoded.menuBar == nil,
           UserDefaults.standard.object(forKey: "menuBarMonitorEnabled") != nil {
            restoredMenuBar.enabled = UserDefaults.standard.bool(forKey: "menuBarMonitorEnabled")
        }
        menuBar = restoredMenuBar
        language = decoded.language ?? LanguagePrefs()
        onboardingVersion = decoded.onboardingVersion
        onboardingCompletedSteps = Set(decoded.onboardingCompletedSteps ?? [])
        sessionCapabilityDefaults = decoded.sessionCapabilityDefaults
        uncoilAuto = decoded.uncoilAuto ?? .default
        ProjectStore.defaultSessionCapabilities = sessionCapabilityDefaults
        ApplicationLifecycle.shared.sessionQuitBehavior = sessionQuitBehavior
        settingsDocument.captureBaseline(persistedSettings())
    }

    /// Mirrors the interface language into `AppleLanguages`.
    ///
    /// SwiftUI picks the language up immediately from `\.locale` on the root
    /// view; AppKit-owned surfaces — the menu bar, standard menu items, open and
    /// save panels — read `AppleLanguages` once at launch and never again, so
    /// those follow on the next start. Writing nil restores the system order.
    static func applyInterfaceLanguage(_ interface: InterfaceLanguage) {
        if let identifier = interface.localeIdentifier {
            UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    private func persistedSettings() -> Persisted {
        Persisted(
            accounts: accounts,
            defaultAccountByProvider: defaultAccountByProvider,
            defaultProvider: defaultProvider,
            resolvedBinaries: resolvedBinaries,
            extraArguments: extraArguments,
            preferredEditor: preferredEditor,
            notifications: notifications,
            presets: configuredPresets,
            providerBehaviors: providerBehaviors.isEmpty ? nil : providerBehaviors,
            commandPaletteHotkey: commandPaletteHotkey == .commandPaletteDefault
                ? nil : commandPaletteHotkey,
            attentionEmphasis: attentionEmphasis == .subtle ? nil : attentionEmphasis,
            usageWarningsEnabled: usageWarningsEnabled ? nil : false,
            usageWarningThreshold: usageWarningThreshold == UsageAlert.defaultThreshold
                ? nil : usageWarningThreshold,
            quotaOptimization: quotaOptimization == QuotaOptimizationPrefs() ? nil : quotaOptimization,
            optionAsMetaKey: optionAsMetaKey ? true : nil,
            sessionQuitBehavior: sessionQuitBehavior == .keepSessionsRunning
                ? nil : sessionQuitBehavior,
            transcriptRetentionPolicy: transcriptRetentionPolicy == .disabled
                ? nil : transcriptRetentionPolicy,
            permissionTimeoutMinutes: permissionTimeoutMinutes == 10
                ? nil : permissionTimeoutMinutes,
            menuBar: menuBar == MenuBarPrefs() ? nil : menuBar,
            imagePasteMode: imagePasteMode == .default ? nil : imagePasteMode,
            launcher: launcher == .default ? nil : launcher,
            language: language == LanguagePrefs() ? nil : language,
            onboardingVersion: onboardingVersion,
            onboardingCompletedSteps: onboardingCompletedSteps.isEmpty
                ? nil : onboardingCompletedSteps.sorted(),
            sessionCapabilityDefaults: sessionCapabilityDefaults,
            agentBinaryLocations: agentBinaryLocations.isEmpty ? nil : agentBinaryLocations,
            uncoilAuto: uncoilAuto == .default ? nil : uncoilAuto,
            sidebarSessionLimit: sidebarSessionLimit == SidebarSessionLimit.default
                ? nil : sidebarSessionLimit
        )
    }

    func save() {
        guard !isLoadingSettings else { return }
        let persisted = persistedSettings()
        guard let data = settingsDocument.encode(persisted) else { return }
        if settingsDocument.requiresBackup && !migrationBackupCreated {
            do {
                let original = try Data(contentsOf: fileURL)
                let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("settings-before-migration-\(digest).json")
                if FileManager.default.fileExists(atPath: backup.path) {
                    guard try Data(contentsOf: backup) == original else { return }
                } else {
                    try original.write(to: backup, options: .withoutOverwriting)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                migrationBackupCreated = true
            } catch {
                return
            }
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
