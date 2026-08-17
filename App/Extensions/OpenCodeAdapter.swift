import Foundation

/// OpenCode: JSON (or JSONC) config at `~/.config/opencode/opencode.json`,
/// MCP servers under the top-level `mcp` object.
///
/// The shape differs from the `mcpServers` family enough to earn its own
/// adapter rather than a fourth `JSONMCPConfigLayout`: the command is an array
/// (`"command": ["bunx", "server"]`), locality is spelled with a `type` field
/// (`local`/`remote`), the environment key is `environment`, and the on/off
/// switch is `enabled` — every field the shared adapter would have written
/// would have been the wrong one.
///
/// Only the `mcp` object is written; every other key is carried through at the
/// JSON level. Comments in a `.jsonc` file survive reading but not writing —
/// the plan's diff shows exactly that before anything is applied.
@MainActor
struct OpenCodeAdapter: AgentAdapter {
    let agent = ExtensionAgentID.opencode

    let capabilities = AgentProviderCapabilities(
        readsSkillsFromDirectory: false,
        supportsPerSkillSymlinks: false,
        supportsStdioMCP: true,
        supportsHTTPMCP: true,
        supportsProjectScopedMCP: false,
        reloadsConfigWithoutRestart: false,
        preservesUnknownConfigKeys: true,
        reportsAuthenticationState: true
    )

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?
    var configPathOverride: String?

    /// `opencode.jsonc` wins when both spellings exist: it is the one the user
    /// edited last if they renamed, and OpenCode itself reads either.
    private var configPath: String {
        if let configPathOverride { return configPathOverride }
        let directory = homeDirectory.appendingPathComponent(".config/opencode", isDirectory: true)
        let jsonc = directory.appendingPathComponent("opencode.jsonc").path
        if FileManager.default.fileExists(atPath: jsonc) { return jsonc }
        return directory.appendingPathComponent("opencode.json").path
    }

    func detectInstallations() -> [AgentInstallation] {
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary("opencode") else { return [] }
        let configDirectory = homeDirectory
            .appendingPathComponent(".config/opencode", isDirectory: true)
        // Cheap signal only, like Codex's auth.json: present means someone
        // logged in at some point, absent means nothing was checked.
        let authPath = homeDirectory
            .appendingPathComponent(".local/share/opencode/auth.json").path
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: configDirectory.path,
                skillsDirectory: nil,
                mcpConfigPath: configPath,
                version: nil,
                isAuthenticated: FileManager.default.fileExists(atPath: authPath) ? true : nil,
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
            mcpServers: raw.isEmpty ? [] : try Self.parseServers(raw),
            skillNames: []
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        if !configuration.raw.isEmpty, (try? Self.parseRoot(configuration.raw)) == nil {
            issues.append(ConfigurationIssue(
                id: "opencode.json.invalid",
                severity: .error,
                message: String(localized: "\(configuration.path) is not valid JSON."),
                remedy: String(localized: "Repair the file by hand; Uncoil does not write to broken JSON.")
            ))
        }
        for server in configuration.mcpServers where !server.environmentKeys.isEmpty {
            issues.append(ConfigurationIssue(
                id: "opencode.mcp.\(server.name).secrets",
                severity: .warning,
                message: String(localized: "\(server.name) keeps a secret in OpenCode's config: ")
                    + server.environmentKeys.joined(separator: ", ") + ".",
                remedy: String(localized: "Move it to the Uncoil launcher to keep the value in the Keychain.")
            ))
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
        // The stale check, backup and atomic write are the shared adapter's,
        // verbatim: what may differ per agent is the JSON shape, never the
        // safety contract around writing it.
        JSONMCPAdapter.performApply(transaction)
    }

    func rollback(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction {
        JSONMCPAdapter.performRollback(transaction)
    }

    func reload(_ installation: AgentInstallation) -> ReloadOutcome {
        .restartRequired(String(localized: "OpenCode reads its config at startup; open sessions must be restarted."))
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? { nil }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - JSON handling

    /// Parses the config, tolerating the `.jsonc` dialect OpenCode documents:
    /// line and block comments are stripped (string-aware) before parsing.
    nonisolated static func parseRoot(_ raw: String) throws -> [String: Any] {
        let stripped = strippingJSONCComments(raw)
        guard let root = try? JSONSerialization
            .jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
            throw AgentAdapterError.configMalformed("opencode.json")
        }
        return root
    }

    nonisolated static func parseServers(_ raw: String) throws -> [MCPServerDefinition] {
        let root = try parseRoot(raw)
        let servers = root["mcp"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name -> MCPServerDefinition? in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let environment = entry["environment"] as? [String: String] ?? [:]
            let split = AgentAdapterSupport.partitionEnvironment(environment)
            let url = entry["url"] as? String
            let command = entry["command"] as? [String] ?? []
            let isRemote = (entry["type"] as? String) == "remote" || url != nil
            return MCPServerDefinition(
                id: "opencode:\(name)",
                name: name,
                transport: isRemote ? .http : .stdio,
                command: command.first,
                arguments: Array(command.dropFirst()),
                url: url,
                environmentKeys: split.secretKeys,
                environment: split.plain,
                isEnabled: entry["enabled"] as? Bool ?? true
            )
        }
    }

    /// Applies `changes`, touching only the `mcp` object.
    nonisolated static func applying(
        _ changes: [ConfigurationChange],
        to raw: String
    ) throws -> String {
        var root: [String: Any] = raw.isEmpty ? [:] : try parseRoot(raw)
        var servers = root["mcp"] as? [String: Any] ?? [:]

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
                    entry["type"] = "local"
                    entry["command"] = [command] + definition.arguments
                case .http:
                    guard let url = definition.url, !url.isEmpty else {
                        throw AgentAdapterError
                            .unsupportedChange("\(definition.name): a URL is required")
                    }
                    entry["type"] = "remote"
                    entry["url"] = url
                }
                let safe = definition.environment.filter {
                    !AgentAdapterSupport.isSecretKey($0.key)
                }
                if !safe.isEmpty { entry["environment"] = safe }
                if !definition.isEnabled { entry["enabled"] = false }
                servers[definition.name] = entry

            case .removeMCPServer(let name):
                servers.removeValue(forKey: name)

            case .setMCPServerEnabled(let name, let isEnabled):
                guard var entry = servers[name] as? [String: Any] else {
                    throw AgentAdapterError.unsupportedChange("\(name) is not in the config")
                }
                if isEnabled {
                    entry.removeValue(forKey: "enabled")
                } else {
                    entry["enabled"] = false
                }
                servers[name] = entry
            }
        }

        root["mcp"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Removes `//` and `/* */` comments without touching string contents.
    ///
    /// Character-by-character on purpose: a regex cannot tell `"http://x"`
    /// from a comment, and that URL is exactly what an MCP config contains.
    nonisolated static func strippingJSONCComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            if character == "/", next < text.endIndex {
                if text[next] == "/" {
                    // Line comment: drop to end of line, keep the newline.
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if text[next] == "*" {
                    // Block comment: drop to the closing `*/`.
                    var scan = text.index(after: next)
                    while scan < text.endIndex {
                        let close = text.index(after: scan)
                        if text[scan] == "*", close < text.endIndex, text[close] == "/" {
                            scan = text.index(after: close)
                            break
                        }
                        scan = text.index(after: scan)
                    }
                    index = scan
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }
}
