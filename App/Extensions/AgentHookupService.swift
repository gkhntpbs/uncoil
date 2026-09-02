import Foundation

/// Finds every agent CLI installed on this machine and reports — per agent —
/// how deeply Uncoil can work with it, plus the one action (if any) that would
/// close the gap.
///
/// Deliberately narrow about what it will do on its own. Scanning is read-only
/// and runs whenever asked. Writing is limited to Uncoil's own hook entries in
/// the agent's settings, which are backed up first and identified by a marker
/// so a user's own hooks are never touched. Registering an MCP server in a
/// user's config is *not* done here: that is a change to a file they own, and
/// it belongs in the Extensions review flow where they see the diff.
@MainActor
final class AgentHookupService: ObservableObject {
    /// One entry per agent Uncoil knows about, installed or not, in a stable
    /// order so the list never reshuffles between scans.
    @Published private(set) var states: [AgentIntegrationState] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanAt: Date?
    /// Set when an action failed, cleared when the next one is attempted.
    @Published private(set) var lastError: String?

    private let registry: AgentAdapterRegistry

    /// One instance for the whole app: the Extensions card and the Settings
    /// page both observe this, so connecting an agent in one place updates the
    /// other without either having to know the other exists.
    static let shared = AgentHookupService()

    /// The registry is injected so tests can supply adapters pointed at a
    /// fixture home; the default is built here rather than in the signature
    /// because constructing it is main-actor work.
    init(registry: AgentAdapterRegistry? = nil) {
        self.registry = registry ?? AgentAdapterRegistry()
    }

    // MARK: - Derived views

    var installed: [AgentIntegrationState] { states.filter(\.isInstalled) }
    var missing: [AgentIntegrationState] { states.filter { !$0.isInstalled } }

    /// Installed agents sitting below the best level they could reach, where
    /// Uncoil can close the gap itself. What "Connect all" acts on.
    var actionable: [AgentIntegrationState] {
        states.filter { $0.isInstalled && $0.pendingAction != nil }
    }

    // MARK: - Scanning

    /// Re-reads the filesystem. Read-only and safe to call on appear.
    ///
    /// Never runs twice at once: a slower scan that started earlier must not
    /// resume after an `apply()` and publish its pre-action snapshot over the
    /// fresh one — the row would offer "Connect" for hooks that were just
    /// installed. A scan requested while one is running is not dropped either;
    /// the running scan goes one more round, so the caller's reason for asking
    /// (something changed) is still honoured.
    func scan() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            await performScan()
        } while rescanRequested
    }

    private var rescanRequested = false

    private func performScan() async {
        // A rescan is the user asking again; an error from the last attempt
        // describes a state they may well have just fixed by hand.
        lastError = nil
        let detected = registry.detectInstallations()
        let byAgent = Dictionary(grouping: detected, by: \.agent)
        let missingCommands = ExtensionAgentID.allCases
            .filter { byAgent[$0] == nil }
            .map { (agent: $0, command: $0.cliBinaryName) }
        // Off the main actor: the hook-file read (one read serves both
        // questions) and the login-shell fallback for CLIs the fixed search
        // path misses (asdf, mise, a PATH built in ~/.zshrc).
        let (hookState, hermesHookState, shellFound) = await Task.detached(priority: .utility) {
            let hookState = HookInstaller.inspect()
            let hermesHookState = HermesHookInstaller.inspect()
            var shellFound: [ExtensionAgentID: String] = [:]
            for entry in missingCommands {
                if let path = SettingsStore.which(entry.command) {
                    shellFound[entry.agent] = path
                }
            }
            return (hookState, hermesHookState, shellFound)
        }.value

        states = ExtensionAgentID.allCases.map { agent in
            let installation = byAgent[agent]?.first
                ?? shellFound[agent].map { fallbackInstallation(agent, binaryPath: $0) }
            switch agent {
            case .claudeCode:
                return .forHookCapableAgent(
                    agent,
                    installation: installation,
                    hookStatus: hookState.status,
                    hasStaleCommands: hookState.hasStaleCommands
                )
            case .hermes:
                // Same decision table as Claude Code's, over a different file:
                // `HermesHookInstaller` reads and writes `~/.hermes/config.yaml`
                // and reports the same three states.
                return .forHookCapableAgent(
                    agent,
                    installation: installation,
                    hookStatus: hermesHookState.status,
                    hasStaleCommands: hermesHookState.hasStaleCommands
                )
            case .codex, .geminiCLI, .cursor, .amp, .opencode, .grok:
                return .forHooklessAgent(
                    agent,
                    installation: installation,
                    hasUncoilMCPServer: hasUncoilMCPServer(agent, installation: installation)
                )
            }
        }
        lastScanAt = .now
    }

    /// The minimal installation for a CLI the adapters did not find — either an
    /// agent with no adapter at all, or one whose binary only the login shell
    /// can locate. Enough to say "this agent is on the machine", which is what
    /// hook install and the row's claim both rest on.
    private func fallbackInstallation(
        _ agent: ExtensionAgentID,
        binaryPath: String
    ) -> AgentInstallation {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentInstallation(
            agent: agent,
            binaryPath: binaryPath,
            configDirectory: home.appendingPathComponent(agent.defaultConfigDirectory).path,
            skillsDirectory: nil,
            mcpConfigPath: nil,
            version: nil,
            isAuthenticated: nil,
            detectedAt: .now
        )
    }

    /// Whether the agent's own config already registers Uncoil's MCP server.
    ///
    /// A failure to read is reported as "no" rather than thrown: a malformed
    /// config is the Extensions screen's problem to surface, and it must not
    /// take the whole scan down with it.
    private func hasUncoilMCPServer(
        _ agent: ExtensionAgentID,
        installation: AgentInstallation?
    ) -> Bool {
        // Providers Uncoil wires per session are on the control plane whatever
        // their config says; parsing it would buy nothing.
        if agent.provider?.wiresControlPlane == true { return true }
        guard let installation,
              let adapter = registry.adapter(for: agent),
              let configuration = try? adapter.readConfiguration(installation)
        else { return false }
        return configuration.mcpServers.contains { $0.name == Self.uncoilMCPServerName }
    }

    /// The name Uncoil registers its stdio server under, matching the
    /// per-session config `TerminalHost` writes.
    static let uncoilMCPServerName = "uncoil"

    // MARK: - Acting

    /// Performs an agent's pending action, then rescans so the row reflects
    /// what is now on disk rather than what we expected to be.
    func apply(to agent: ExtensionAgentID) async {
        guard let state = states.first(where: { $0.agent == agent }),
              let action = state.pendingAction else { return }
        lastError = nil
        do {
            switch (agent, action) {
            // A partial install is repaired the same way as a fresh one: both
            // installers remove Uncoil's existing entries before writing, so
            // they converge rather than duplicating what is already there.
            case (.hermes, .installHooks), (.hermes, .completeHooks):
                try HermesHookInstaller.install()
            case (.hermes, .repairHooks):
                try HermesHookInstaller.repairStalePaths()
            case (_, .installHooks), (_, .completeHooks):
                try HookInstaller.install()
            case (_, .repairHooks):
                try HookInstaller.repairStalePaths()
            }
        } catch {
            lastError = error.localizedDescription
        }
        await scan()
    }

    /// Connects every installed agent Uncoil can connect on its own.
    ///
    /// Stops at the first failure: the errors here are things like "settings
    /// file is not valid JSON", which the next agent would hit too, and a list
    /// of five identical alerts helps nobody.
    func connectAll() async {
        for state in actionable {
            await apply(to: state.agent)
            if lastError != nil { return }
        }
    }

    /// Removes Uncoil's hooks from the agents that have them.
    func disconnect(_ agent: ExtensionAgentID) async {
        guard agent == .claudeCode || agent == .hermes else { return }
        lastError = nil
        do {
            if agent == .hermes {
                try HermesHookInstaller.uninstall()
            } else {
                try HookInstaller.uninstall()
            }
        } catch {
            lastError = error.localizedDescription
        }
        await scan()
    }
}
