import Foundation

/// One agent's JSON config layout: where the file is, and where the MCP servers
/// live inside it.
///
/// Gemini CLI, Cursor and Amp all keep MCP servers in a JSON object; only the
/// path and the key differ. Describing that difference is enough, so there is no
/// third, fourth and fifth copy of the same JSON surgery.
struct JSONMCPConfigLayout: Equatable {
    let agent: ExtensionAgentID
    /// Config file, relative to the home directory.
    let configRelativePath: String
    /// Config root, relative to home — what the UI calls the agent's directory.
    let directoryRelativePath: String
    /// Skills directory relative to home, when the agent reads skills at all.
    let skillsRelativePath: String?
    /// Key chain to the servers map: `["mcpServers"]`, `["amp.mcpServers"]`, …
    let serversKeyPath: [String]
    /// Binary looked up on PATH.
    let binaryName: String
    /// What happens to a running agent when its config changes.
    let reload: String

    static let geminiCLI = JSONMCPConfigLayout(
        agent: .geminiCLI,
        configRelativePath: ".gemini/settings.json",
        directoryRelativePath: ".gemini",
        skillsRelativePath: nil,
        serversKeyPath: ["mcpServers"],
        binaryName: "gemini",
        reload: "Gemini CLI reads its config at startup; open sessions must be restarted."
    )

    static let cursor = JSONMCPConfigLayout(
        agent: .cursor,
        configRelativePath: ".cursor/mcp.json",
        directoryRelativePath: ".cursor",
        skillsRelativePath: ".cursor/rules",
        serversKeyPath: ["mcpServers"],
        binaryName: "cursor",
        reload: "Cursor reloads its MCP list from its own interface; the change shows up there."
    )

    static let amp = JSONMCPConfigLayout(
        agent: .amp,
        configRelativePath: ".config/amp/settings.json",
        directoryRelativePath: ".config/amp",
        skillsRelativePath: nil,
        serversKeyPath: ["amp.mcpServers"],
        binaryName: "amp",
        reload: "Amp settings are read at startup; open sessions must be restarted."
    )

    static let all: [JSONMCPConfigLayout] = [.geminiCLI, .cursor, .amp]
}

/// An adapter for any agent whose configuration is a JSON object with an MCP
/// server map inside it.
///
/// Only that map is read and written; every other key is carried through at the
/// JSON level, so a user's own settings are never reformatted away. The paths
/// come from each agent's documented defaults and are overridable, because an
/// agent that moved its config file must be fixable without a new build.
@MainActor
struct JSONMCPAdapter: AgentAdapter {
    let layout: JSONMCPConfigLayout
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?
    /// Set by tests and by a user pointing Uncoil at a non-standard install.
    var configPathOverride: String?

    var agent: ExtensionAgentID { layout.agent }

    var capabilities: AgentProviderCapabilities {
        AgentProviderCapabilities(
            readsSkillsFromDirectory: layout.skillsRelativePath != nil,
            supportsPerSkillSymlinks: layout.skillsRelativePath != nil,
            supportsStdioMCP: true,
            supportsHTTPMCP: true,
            supportsProjectScopedMCP: layout.agent == .cursor,
            reloadsConfigWithoutRestart: layout.agent == .cursor,
            preservesUnknownConfigKeys: true,
            reportsAuthenticationState: false
        )
    }

    private var configPath: String {
        configPathOverride
            ?? homeDirectory.appendingPathComponent(layout.configRelativePath).path
    }

    func detectInstallations() -> [AgentInstallation] {
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary(layout.binaryName) else { return [] }
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: homeDirectory
                    .appendingPathComponent(layout.directoryRelativePath, isDirectory: true).path,
                skillsDirectory: layout.skillsRelativePath.map {
                    homeDirectory.appendingPathComponent($0, isDirectory: true).path
                },
                mcpConfigPath: configPath,
                version: nil,
                isAuthenticated: nil,
                detectedAt: .now
            ),
        ]
    }

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration {
        let path = installation.mcpConfigPath ?? configPath
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
            mcpServers: raw.isEmpty
                ? []
                : try Self.parseServers(raw, layout: layout),
            skillNames: AgentAdapterSupport.skillNames(
                in: installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
            )
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        let name = agent.displayName
        if !configuration.raw.isEmpty,
           (try? JSONSerialization.jsonObject(with: Data(configuration.raw.utf8))) == nil {
            issues.append(ConfigurationIssue(
                id: "\(agent.rawValue).json.invalid",
                severity: .error,
                message: String(localized: "\(configuration.path) is not valid JSON."),
                remedy: String(localized: "Repair the file by hand; Uncoil does not write to broken JSON.")
            ))
        }
        for server in configuration.mcpServers {
            switch server.transport {
            case .stdio where (server.command ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "\(agent.rawValue).mcp.\(server.name).command",
                    severity: .error,
                    message: String(localized: "The \(server.name) STDIO server has no command."),
                    remedy: String(localized: "Add the command, or remove the server.")
                ))
            case .http where (server.url ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "\(agent.rawValue).mcp.\(server.name).url",
                    severity: .error,
                    message: String(localized: "The \(server.name) HTTP server has no address."),
                    remedy: String(localized: "Add a URL, or remove the server.")
                ))
            default:
                break
            }
            if !server.environmentKeys.isEmpty {
                issues.append(ConfigurationIssue(
                    id: "\(agent.rawValue).mcp.\(server.name).secrets",
                    severity: .warning,
                    message: String(localized: "\(server.name) keeps a secret in \(name)'s config: ")
                        + server.environmentKeys.joined(separator: ", ") + ".",
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
        let updated = try Self.applying(changes, to: configuration.raw, layout: layout)
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
        var result = transaction
        guard !transaction.diff.isEmpty else {
            result.status = .applied
            result.appliedAt = .now
            return result
        }
        guard let pendingContent = transaction.pendingContent else {
            result.status = .failed
            result.failureReason = "There is no plan content; the change has to be replanned."
            return result
        }
        let current = (try? String(contentsOfFile: transaction.configPath, encoding: .utf8)) ?? ""
        guard AgentAdapterSupport.hash(current) == transaction.baseHash else {
            result.status = .staleConfig
            result.failureReason = AgentAdapterError
                .staleConfig(transaction.configPath).localizedDescription
            return result
        }
        do {
            result.backupPath = try AgentAdapterSupport.backup(
                path: transaction.configPath,
                into: AgentAdapterSupport.configBackupDirectory()
            )
            let url = URL(fileURLWithPath: transaction.configPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(pendingContent.utf8).write(to: url, options: .atomic)
            result.status = .applied
            result.appliedAt = .now
        } catch {
            result.status = .failed
            result.failureReason = error.localizedDescription
        }
        return result
    }

    func rollback(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction {
        var result = transaction
        guard let backupPath = transaction.backupPath,
              let data = FileManager.default.contents(atPath: backupPath) else {
            result.failureReason = "No backup to roll back to; the previous state is kept."
            return result
        }
        do {
            try data.write(to: URL(fileURLWithPath: transaction.configPath), options: .atomic)
            result.status = .rolledBack
        } catch {
            result.status = .failed
            result.failureReason = error.localizedDescription
        }
        return result
    }

    func reload(_ installation: AgentInstallation) -> ReloadOutcome {
        capabilities.reloadsConfigWithoutRestart
            ? .reloaded
            : .restartRequired(layout.reload)
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? {
        installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
    }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - JSON handling

    nonisolated static func parseServers(
        _ raw: String,
        layout: JSONMCPConfigLayout
    ) throws -> [MCPServerDefinition] {
        guard let root = try? JSONSerialization
            .jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AgentAdapterError.configMalformed(layout.configRelativePath)
        }
        let servers = value(at: layout.serversKeyPath, in: root) as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name -> MCPServerDefinition? in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let environment = entry["env"] as? [String: String] ?? [:]
            let split = AgentAdapterSupport.partitionEnvironment(environment)
            let url = entry["url"] as? String
            return MCPServerDefinition(
                id: "\(layout.agent.rawValue):\(name)",
                name: name,
                transport: url == nil ? .stdio : .http,
                command: entry["command"] as? String,
                arguments: entry["args"] as? [String] ?? [],
                url: url,
                environmentKeys: split.secretKeys,
                environment: split.plain,
                // Two spellings in the wild: `disabled: true` and
                // `enabled: false`. Either one turns a server off.
                isEnabled: (entry["disabled"] as? Bool).map { !$0 }
                    ?? (entry["enabled"] as? Bool)
                    ?? true
            )
        }
    }

    /// Applies `changes`, touching only the servers map.
    nonisolated static func applying(
        _ changes: [ConfigurationChange],
        to raw: String,
        layout: JSONMCPConfigLayout
    ) throws -> String {
        var root: [String: Any] = [:]
        if !raw.isEmpty {
            guard let object = try? JSONSerialization
                .jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw AgentAdapterError.configMalformed(layout.configRelativePath)
            }
            root = object
        }
        var servers = value(at: layout.serversKeyPath, in: root) as? [String: Any] ?? [:]

        for change in changes {
            switch change {
            case .addMCPServer(let definition):
                var entry: [String: Any] = [:]
                switch definition.transport {
                case .stdio:
                    guard let command = definition.command, !command.isEmpty else {
                        throw AgentAdapterError
                            .unsupportedChange("\(definition.name): a command is required")
                    }
                    entry["command"] = command
                    if !definition.arguments.isEmpty { entry["args"] = definition.arguments }
                case .http:
                    guard let url = definition.url, !url.isEmpty else {
                        throw AgentAdapterError
                            .unsupportedChange("\(definition.name): a URL is required")
                    }
                    entry["url"] = url
                }
                // Secret values never reach an agent config, whatever the caller
                // passed: the launcher injects them from the Keychain.
                let safe = definition.environment.filter {
                    !AgentAdapterSupport.isSecretKey($0.key)
                }
                if !safe.isEmpty { entry["env"] = safe }
                if !definition.isEnabled { entry["disabled"] = true }
                servers[definition.name] = entry

            case .removeMCPServer(let name):
                servers.removeValue(forKey: name)

            case .setMCPServerEnabled(let name, let isEnabled):
                guard var entry = servers[name] as? [String: Any] else {
                    throw AgentAdapterError.unsupportedChange("\(name) is not in the config")
                }
                if isEnabled {
                    entry.removeValue(forKey: "disabled")
                    entry.removeValue(forKey: "enabled")
                } else {
                    entry["disabled"] = true
                }
                servers[name] = entry
            }
        }

        setValue(servers, at: layout.serversKeyPath, in: &root)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Reads a nested key chain. A single-element path is the common case; the
    /// chain exists because Amp namespaces its settings (`amp.mcpServers`) and
    /// some agents nest under a section.
    nonisolated static func value(at path: [String], in root: [String: Any]) -> Any? {
        var current: Any? = root
        for key in path {
            guard let object = current as? [String: Any] else { return nil }
            current = object[key]
        }
        return current
    }

    nonisolated static func setValue(
        _ value: Any,
        at path: [String],
        in root: inout [String: Any]
    ) {
        guard let first = path.first else { return }
        if path.count == 1 {
            root[first] = value
            return
        }
        var child = root[first] as? [String: Any] ?? [:]
        setValue(value, at: Array(path.dropFirst()), in: &child)
        root[first] = child
    }
}
