import Foundation

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
    }

    @Published private(set) var accounts: [AccountProfile] = []
    @Published var defaultProvider: AgentProvider = .claude
    @Published private(set) var defaultAccountByProvider: [String: UUID] = [:]
    @Published private(set) var resolvedBinaries: [String: String] = [:]
    /// Extra CLI arguments appended to the agent launch command, per provider.
    @Published var extraArguments: [String: String] = [:]
    @Published var preferredEditor: PreferredEditor = .vscode
    /// Installed CLI versions ("claude" -> "1.0.83 (Claude Code)").
    @Published var cliVersions: [String: String] = [:]
    /// Providers with an update currently running.
    @Published var cliUpdating: Set<String> = []
    /// Last update-run output per provider.
    @Published var cliUpdateResult: [String: String] = [:]

    private let fileURL: URL
    private let profilesRoot: URL

    init(directory: URL? = nil) {
        let base = directory ?? ProjectStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("settings.json")
        profilesRoot = base.appendingPathComponent("profiles", isDirectory: true)
        load()
        ensureDefaultAccounts()
    }

    var profilesRootURL: URL { profilesRoot }

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

    /// Logged-in identity for a Claude profile, read from the provider's own
    /// config file. Returns nil when nobody is logged in.
    nonisolated func loggedInEmail(for profile: AccountProfile, profilesRoot: URL) -> String? {
        let configFile: URL
        if let dir = profile.configDirectory(profilesRoot: profilesRoot) {
            configFile = dir.appendingPathComponent(".claude.json")
        } else {
            configFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
        }
        guard
            let data = try? Data(contentsOf: configFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauth["emailAddress"] as? String
    }

    // MARK: - Binary resolution

    func binaryPath(for provider: AgentProvider) -> String? {
        resolvedBinaries[provider.rawValue]
    }

    /// Resolves the provider CLI through the user's login shell once and caches it.
    func resolveBinaries() async {
        for provider in [AgentProvider.claude, .codex] {
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
        await refreshCLIVersions()
    }

    nonisolated private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        process.arguments = ["-l", "-c", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    func save() {
        let persisted = Persisted(
            accounts: accounts,
            defaultAccountByProvider: defaultAccountByProvider,
            defaultProvider: defaultProvider,
            resolvedBinaries: resolvedBinaries,
            extraArguments: extraArguments,
            preferredEditor: preferredEditor
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
