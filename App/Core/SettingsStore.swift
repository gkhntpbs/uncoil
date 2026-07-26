import Foundation

enum SessionQuitBehavior: String, Codable, CaseIterable, Identifiable {
    case keepSessionsRunning
    case terminateAllAgents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepSessionsRunning: "Keep sessions running"
        case .terminateAllAgents: "Terminate all agents on quit"
        }
    }

    var detail: String {
        switch self {
        case .keepSessionsRunning:
            "Uncoil kapansa da agent’lar runtime daemon içinde çalışmaya devam eder."
        case .terminateAllAgents:
            "Uncoil’den çıkarken çalışan tüm agent ve terminal süreçleri kapatılır."
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
        var sessionQuitBehavior: SessionQuitBehavior? = nil
        var transcriptRetentionPolicy: TranscriptRetentionPolicy? = nil
        /// Minutes a permission request may sit unanswered; 0 = never
        /// expires. Optional for backward compatibility; nil ⇒ 10 minutes.
        var permissionTimeoutMinutes: Int? = nil
        /// Menu-bar monitor appearance and contents; nil ⇒ defaults.
        var menuBar: MenuBarPrefs? = nil
        /// Interface and agent-prompt language; nil ⇒ follow the system.
        var language: LanguagePrefs? = nil
    }

    @Published private(set) var accounts: [AccountProfile] = []
    @Published var defaultProvider: AgentProvider = .claude
    @Published private(set) var defaultAccountByProvider: [String: UUID] = [:]
    @Published private(set) var resolvedBinaries: [String: String] = [:]
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
    /// Installed CLI versions ("claude" -> "1.0.83 (Claude Code)").
    @Published var cliVersions: [String: String] = [:]
    /// Providers with an update currently running.
    @Published var cliUpdating: Set<String> = []
    /// Last update-run output per provider.
    @Published var cliUpdateResult: [String: String] = [:]
    /// Latest published versions from the registry.
    @Published var cliLatest: [String: String] = [:]
    @Published var cliChecking = false

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
        ensureDefaultAccounts()
    }

    var profilesRootURL: URL { profilesRoot }

    /// Effective session presets: the user's configured list when non-empty,
    /// otherwise the built-in defaults.
    var presets: [SessionPreset] {
        if let configured = configuredPresets, !configured.isEmpty { return configured }
        return SessionPreset.builtInDefaults
    }

    func preset(id: String) -> SessionPreset? {
        presets.first { $0.id == id }
    }

    func upsertPreset(_ preset: SessionPreset) {
        var configured = configuredPresets ?? SessionPreset.builtInDefaults
        if let index = configured.firstIndex(where: { $0.id == preset.id }) {
            configured[index] = preset
        } else {
            configured.append(preset)
        }
        configuredPresets = configured
        save()
    }

    func removePreset(id: String) {
        var configured = configuredPresets ?? SessionPreset.builtInDefaults
        configured.removeAll { $0.id == id }
        configuredPresets = configured.isEmpty ? nil : configured
        save()
    }

    func resetPresets() {
        configuredPresets = nil
        save()
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

    func workingMode(for provider: AgentProvider) -> AgentWorkingMode {
        let fallback: AgentWorkingMode = switch provider {
        case .claude: .manual
        case .codex: .askForApproval
        case .terminal: .providerDefault
        }
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
            return "bağlı"  // auth file exists but no readable identity

        case .terminal:
            return nil
        }
    }

    // MARK: - Binary resolution

    func binaryPath(for provider: AgentProvider) -> String? {
        resolvedBinaries[provider.rawValue]
    }

    /// Resolves the provider CLI through the user's login shell once and caches it.
    func resolveBinaries() async {
        for provider in [AgentProvider.claude, .codex] {
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
        for provider in [AgentProvider.claude, .codex] {
            guard let path = binaryPath(for: provider) else { continue }
            let version = await Task.detached(priority: .utility) {
                CLIToolService.version(binaryPath: path)
            }.value
            if let version {
                cliVersions[provider.rawValue] = version
            }
        }
    }

    func updateAvailable(for provider: AgentProvider) -> Bool {
        CLIToolService.isNewer(
            cliLatest[provider.rawValue],
            than: cliVersions[provider.rawValue]
        )
    }

    /// Refreshes installed versions and checks the registry for updates.
    func checkCLIUpdates() async {
        cliChecking = true
        await refreshCLIVersions()
        for provider in [AgentProvider.claude, .codex] {
            if let latest = await CLIToolService.latestVersion(provider: provider) {
                cliLatest[provider.rawValue] = latest
            }
        }
        cliChecking = false
    }

    func updateCLI(_ provider: AgentProvider) async {
        guard !cliUpdating.contains(provider.rawValue) else { return }
        let source = binaryPath(for: provider).map {
            CLIToolService.source(forBinaryAt: $0, provider: provider)
        } ?? .unknown
        guard let command = CLIToolService.updateCommand(provider: provider, source: source) else {
            cliUpdateResult[provider.rawValue] = "Bu kurulum için güncelleme yolu bilinmiyor."
            return
        }
        cliUpdating.insert(provider.rawValue)
        cliUpdateResult[provider.rawValue] = nil
        let result = await Task.detached(priority: .userInitiated) {
            CLIToolService.runUpdate(command: command)
        }.value
        cliUpdating.remove(provider.rawValue)
        cliUpdateResult[provider.rawValue] = result.success
            ? "✓ \(result.output)"
            : "✗ \(result.output)"
        // Path may have changed (e.g. npm relink); re-resolve then re-read.
        resolvedBinaries[provider.rawValue] = nil
        await resolveBinaries()
        await checkCLIUpdates()
    }

    /// Resolves a CLI by name using well-known install locations and an
    /// interactive login shell. Reused by the control-plane adapters to locate
    /// optional external drivers (agent-browser / cua-driver).
    nonisolated static func which(_ command: String) -> String? {
        // 1) Well-known install locations first: GUI apps start with a
        //    minimal PATH, and users often extend PATH only in ~/.zshrc.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownLocations = [
            "\(home)/.local/bin/\(command)",
            "\(home)/.claude/local/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(home)/.npm-global/bin/\(command)",
            "\(home)/.bun/bin/\(command)",
        ]
        for candidate in knownLocations where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // 2) Interactive login shell (-l -i sources both zprofile and zshrc).
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init)
        return path?.isEmpty == false ? path : nil
    }

    // MARK: - Persistence

    private func ensureDefaultAccounts() {
        for provider in [AgentProvider.claude, .codex]
        where !accounts.contains(where: { $0.provider == provider && $0.directoryName == nil }) {
            accounts.append(AccountProfile(provider: provider, name: "Varsayılan", directoryName: nil))
        }
        save()
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        accounts = decoded.accounts
        defaultAccountByProvider = decoded.defaultAccountByProvider
        defaultProvider = decoded.defaultProvider
        resolvedBinaries = decoded.resolvedBinaries
        extraArguments = decoded.extraArguments
        preferredEditor = decoded.preferredEditor
        notifications = decoded.notifications
        configuredPresets = decoded.presets
        providerBehaviors = decoded.providerBehaviors ?? [:]
        commandPaletteHotkey = decoded.commandPaletteHotkey ?? .commandPaletteDefault
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
        ApplicationLifecycle.shared.sessionQuitBehavior = sessionQuitBehavior
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

    func save() {
        let persisted = Persisted(
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
            sessionQuitBehavior: sessionQuitBehavior == .keepSessionsRunning
                ? nil : sessionQuitBehavior,
            transcriptRetentionPolicy: transcriptRetentionPolicy == .disabled
                ? nil : transcriptRetentionPolicy,
            permissionTimeoutMinutes: permissionTimeoutMinutes == 10
                ? nil : permissionTimeoutMinutes,
            menuBar: menuBar == MenuBarPrefs() ? nil : menuBar,
            language: language == LanguagePrefs() ? nil : language
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
