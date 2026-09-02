import Foundation

/// Hermes Agent: YAML config at `~/.hermes/config.yaml`, MCP servers under the
/// top-level `mcp_servers:` mapping.
///
/// Hermes is the first agent Uncoil manages whose config is YAML, so the
/// surgery is `HermesYAML`'s rather than `CodexTOML`'s — see that file for why
/// the config is edited in place instead of round-tripped through a parser.
///
/// Two things about Hermes are unlike its neighbours and worth stating here,
/// because they are what a reader of this file will wonder about:
///
/// - **The config root moves.** `HERMES_HOME` relocates the whole home —
///   `config.yaml`, `.env`, `auth.json`, sessions, the lot — so an installation
///   is read at whatever root the environment points at, falling back to
///   `~/.hermes`. This is also why per-account isolation works for Hermes and
///   why per-session MCP registration does not: a second root is a second set
///   of credentials.
/// - **The config file often does not exist.** Hermes writes `config.yaml`
///   lazily, so a working install can have nothing but `logs/` under its home.
///   An empty read is the normal case, not a broken one, and the adapter treats
///   it that way rather than reporting an issue.
@MainActor
struct HermesAdapter: AgentAdapter {
    let agent = ExtensionAgentID.hermes

    let capabilities = AgentProviderCapabilities(
        // `hermes skills` manages a real skills directory under the Hermes
        // home, but the layout is Hermes' own (a skills hub with bundles and a
        // curator) rather than a folder of `SKILL.md` directories, so Uncoil
        // does not claim to write into it.
        readsSkillsFromDirectory: false,
        supportsPerSkillSymlinks: false,
        supportsStdioMCP: true,
        supportsHTTPMCP: true,
        // `mcp_servers` is read from the active Hermes home only. There is no
        // project-scoped MCP file the way Claude Code and Cursor have one.
        supportsProjectScopedMCP: false,
        reloadsConfigWithoutRestart: false,
        preservesUnknownConfigKeys: true,
        reportsAuthenticationState: true
    )

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?
    /// `HERMES_HOME` as the app sees it, so a machine that relocates the Hermes
    /// root is read at the root it actually uses. Injectable for the tests.
    var hermesHomeOverride: String? = ProcessInfo.processInfo.environment["HERMES_HOME"]

    /// `$HERMES_HOME`, else `~/.hermes` — the same order `hermes_constants.py`
    /// resolves it in.
    var configRoot: URL {
        if let override = hermesHomeOverride?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
    }

    func detectInstallations() -> [AgentInstallation] {
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary(agent.cliBinaryName) else { return [] }
        let root = configRoot
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: root.path,
                skillsDirectory: nil,
                mcpConfigPath: root.appendingPathComponent("config.yaml").path,
                version: nil,
                // Cheap signal only, as with Codex and Grok: `auth.json` holds
                // per-provider credential state, so its presence says somebody
                // signed in — not to which provider, and not that the token is
                // still good.
                isAuthenticated: FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("auth.json").path
                ),
                detectedAt: .now
            ),
        ]
    }

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration {
        let path = installation.mcpConfigPath
            ?? configRoot.appendingPathComponent("config.yaml").path
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
            mcpServers: HermesYAML.servers(in: raw),
            skillNames: []
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        // A tab anywhere in the indentation makes the whole file unparseable to
        // PyYAML, and Hermes' own failure mode for that is to keep running on
        // built-in defaults while every edit is silently ignored. Worth saying
        // out loud, because from the outside it looks like Hermes is ignoring
        // the user rather than refusing to read the file.
        if configuration.raw.components(separatedBy: "\n")
            .contains(where: { $0.hasPrefix("\t") }) {
            issues.append(ConfigurationIssue(
                id: "hermes.config.tabs",
                severity: .error,
                message: String(localized: "config.yaml is indented with tabs, which YAML does not allow."),
                remedy: String(localized: "Replace the leading tabs with spaces; until then Hermes ignores the whole file.")
            ))
        }
        for server in configuration.mcpServers {
            switch server.transport {
            case .stdio where (server.command ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "hermes.mcp.\(server.name).command",
                    severity: .error,
                    message: String(localized: "The \(server.name) STDIO server has no command."),
                    remedy: String(localized: "Add the command, or remove the server.")
                ))
            case .http where (server.url ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "hermes.mcp.\(server.name).url",
                    severity: .error,
                    message: String(localized: "The \(server.name) HTTP server has no address."),
                    remedy: String(localized: "Add a URL, or remove the server.")
                ))
            default:
                break
            }
            // Hermes interpolates `${VAR}` in MCP values from its own `.env`,
            // so a secret does not have to sit in config.yaml — which makes a
            // literal one there a choice rather than a necessity.
            let literalSecrets = server.environmentKeys.filter {
                !(server.environment[$0]?.contains("${") ?? false)
            }
            if !literalSecrets.isEmpty {
                issues.append(ConfigurationIssue(
                    id: "hermes.mcp.\(server.name).secrets",
                    severity: .warning,
                    message: String(localized: "\(server.name) keeps a secret in Hermes' config.yaml: \(literalSecrets.joined(separator: ", "))."),
                    remedy: String(localized: "Move it to the Uncoil launcher to keep the value in the Keychain, or to ~/.hermes/.env and reference it as ${NAME}.")
                ))
            }
        }
        return issues
    }

    func plan(
        _ changes: [ConfigurationChange],
        for configuration: AgentConfiguration
    ) throws -> ConfigurationTransaction {
        let updated = try Self.applying(changes, to: configuration.raw)
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
        .restartRequired(String(localized: "Hermes reads config.yaml at startup; open sessions must be restarted."))
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? { nil }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }

    /// Pure, so the tests drive it without a file on disk. Mirrors
    /// `CodexAdapter.applying`, over `HermesYAML` instead of `CodexTOML`.
    nonisolated static func applying(
        _ changes: [ConfigurationChange],
        to raw: String
    ) throws -> String {
        var result = raw
        for change in changes {
            switch change {
            case .addMCPServer(let definition):
                switch definition.transport {
                case .stdio where (definition.command ?? "").isEmpty:
                    throw AgentAdapterError.unsupportedChange("\(definition.name): a command is required")
                case .http where (definition.url ?? "").isEmpty:
                    throw AgentAdapterError.unsupportedChange("\(definition.name): a URL is required")
                default:
                    break
                }
                result = HermesYAML.rewrite(result, name: definition.name, with: definition)
            case .removeMCPServer(let name):
                result = HermesYAML.rewrite(result, name: name, with: nil)
            case .setMCPServerEnabled(let name, let isEnabled):
                guard var definition = HermesYAML.servers(in: result)
                    .first(where: { $0.name == name }) else {
                    throw AgentAdapterError.unsupportedChange("\(name) is not defined")
                }
                definition.isEnabled = isEnabled
                result = HermesYAML.rewrite(result, name: name, with: definition)
            }
        }
        return result
    }
}
