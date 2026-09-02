import Foundation

/// Grok CLI: TOML config at `~/.grok/config.toml`, MCP servers in
/// `[mcp_servers.*]` tables.
///
/// The table shape is the same one Codex uses — verified by running
/// `grok mcp add` against a throwaway `GROK_HOME` and reading what it wrote —
/// so the TOML surgery is `CodexTOML`'s rather than a second copy of it. What
/// differs is everything around it: the config root, the absence of a skills
/// directory (Grok extends itself through plugins and a marketplace), and the
/// fact that Grok keeps its credentials in the same directory.
@MainActor
struct GrokAdapter: AgentAdapter {
    let agent = ExtensionAgentID.grok

    let capabilities = AgentProviderCapabilities(
        readsSkillsFromDirectory: false,
        supportsPerSkillSymlinks: false,
        supportsStdioMCP: true,
        supportsHTTPMCP: true,
        supportsProjectScopedMCP: true,
        reloadsConfigWithoutRestart: false,
        preservesUnknownConfigKeys: true,
        reportsAuthenticationState: true
    )

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?

    func detectInstallations() -> [AgentInstallation] {
        let configDirectory = homeDirectory.appendingPathComponent(".grok", isDirectory: true)
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary("grok") else { return [] }
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: configDirectory.path,
                // Grok has no skills directory: plugins come from its
                // marketplace, which Uncoil does not manage.
                skillsDirectory: nil,
                mcpConfigPath: configDirectory.appendingPathComponent("config.toml").path,
                version: nil,
                // Cheap signal only, as with Codex: the file's presence says
                // someone signed in, not who.
                isAuthenticated: FileManager.default.fileExists(
                    atPath: configDirectory.appendingPathComponent("auth.json").path
                ),
                detectedAt: .now
            ),
        ]
    }

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration {
        let path = installation.mcpConfigPath
            ?? homeDirectory.appendingPathComponent(".grok/config.toml").path
        var raw = ""
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                throw AgentAdapterError.configUnreadable(path)
            }
            raw = text
        }
        return AgentConfiguration(
            installation: installation,
            path: path,
            raw: raw,
            hash: AgentAdapterSupport.hash(raw),
            mcpServers: CodexTOML.servers(in: raw),
            skillNames: []
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        for server in configuration.mcpServers {
            switch server.transport {
            case .stdio where (server.command ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "grok.mcp.\(server.name).command",
                    severity: .error,
                    message: String(localized: "The \(server.name) STDIO server has no command."),
                    remedy: String(localized: "Add the command, or remove the server.")
                ))
            case .http where (server.url ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "grok.mcp.\(server.name).url",
                    severity: .error,
                    message: String(localized: "The \(server.name) HTTP server has no address."),
                    remedy: String(localized: "Add a URL, or remove the server.")
                ))
            default:
                break
            }
            if !server.environmentKeys.isEmpty {
                issues.append(ConfigurationIssue(
                    id: "grok.mcp.\(server.name).secrets",
                    severity: .warning,
                    message: String(localized: "\(server.name) keeps a secret in Grok's config.toml: \(server.environmentKeys.joined(separator: ", "))."),
                    remedy: String(localized: "Move it to the Uncoil launcher to keep the value in the Keychain.")
                ))
            }
        }
        return issues
    }

    func plan(
        _ changes: [ConfigurationChange],
        for configuration: AgentConfiguration
    ) throws -> ConfigurationTransaction {
        // Same tables, same writer: Grok's `[mcp_servers.*]` is Codex's.
        let updated = try CodexAdapter.applying(changes, to: configuration.raw)
        return ConfigurationTransaction(
            agent: agent,
            configPath: configuration.path,
            baseHash: configuration.hash,
            diff: AgentAdapterSupport.diff(
                before: configuration.raw, after: updated, path: configuration.path
            ),
            pendingContent: updated
        )
    }

    func apply(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction {
        JSONMCPAdapter.performApply(transaction)
    }

    func rollback(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction {
        JSONMCPAdapter.performRollback(transaction)
    }

    func reload(_ installation: AgentInstallation) -> ReloadOutcome {
        .restartRequired(String(localized: "Grok reads config.toml at startup; open sessions must be restarted."))
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? { nil }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }
}
