import Foundation

/// Claude Code: JSON config at `~/.claude.json`, skills under
/// `~/.claude/skills/`, MCP servers under the top-level `mcpServers` object.
///
/// Reads and writes only `mcpServers`; every other key in the file is copied
/// through byte-for-byte at the JSON level, so the user's own settings are
/// never reformatted away.
@MainActor
struct ClaudeCodeAdapter: AgentAdapter {
    let agent = ExtensionAgentID.claudeCode

    let capabilities = AgentProviderCapabilities(
        readsSkillsFromDirectory: true,
        supportsPerSkillSymlinks: true,
        supportsStdioMCP: true,
        supportsHTTPMCP: true,
        supportsProjectScopedMCP: true,
        reloadsConfigWithoutRestart: false,
        preservesUnknownConfigKeys: true,
        reportsAuthenticationState: false
    )

    /// Overridable so tests can point the adapter at a fixture home.
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?

    func detectInstallations() -> [AgentInstallation] {
        let configDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary("claude") else { return [] }
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: configDirectory.path,
                skillsDirectory: configDirectory.appendingPathComponent("skills", isDirectory: true).path,
                mcpConfigPath: homeDirectory.appendingPathComponent(".claude.json").path,
                version: nil,
                isAuthenticated: nil,
                detectedAt: .now
            ),
        ]
    }

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration {
        let path = installation.mcpConfigPath
            ?? homeDirectory.appendingPathComponent(".claude.json").path
        let raw: String
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                throw AgentAdapterError.configUnreadable(path)
            }
            raw = text
        } else {
            raw = ""
        }
        return AgentConfiguration(
            installation: installation,
            path: path,
            raw: raw,
            hash: AgentAdapterSupport.hash(raw),
            mcpServers: raw.isEmpty ? [] : try Self.parseServers(raw),
            skillNames: AgentAdapterSupport.skillNames(
                in: installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
            )
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        if !configuration.raw.isEmpty,
           (try? JSONSerialization.jsonObject(with: Data(configuration.raw.utf8))) == nil {
            issues.append(ConfigurationIssue(
                id: "claude.json.invalid",
                severity: .error,
                message: "~/.claude.json geçerli JSON değil.",
                remedy: "Dosyayı elle düzelt; Uncoil bozuk JSON'a yazmaz."
            ))
        }
        for server in configuration.mcpServers {
            switch server.transport {
            case .stdio where (server.command ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "claude.mcp.\(server.name).command",
                    severity: .error,
                    message: "\(server.name) STDIO sunucusunun komutu yok.",
                    remedy: "Komutu ekle veya sunucuyu kaldır."
                ))
            case .http where (server.url ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "claude.mcp.\(server.name).url",
                    severity: .error,
                    message: "\(server.name) HTTP sunucusunun adresi yok.",
                    remedy: "URL ekle veya sunucuyu kaldır."
                ))
            default:
                break
            }
            if !server.environmentKeys.isEmpty {
                issues.append(ConfigurationIssue(
                    id: "claude.mcp.\(server.name).secrets",
                    severity: .warning,
                    message: "\(server.name) config içinde secret tutuyor: \(server.environmentKeys.joined(separator: ", ")).",
                    remedy: "Uncoil launcher'a taşıyarak değeri Keychain'de tut."
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
        var result = transaction
        guard !transaction.diff.isEmpty else {
            result.status = .applied
            result.appliedAt = .now
            return result
        }
        guard let pendingContent = transaction.pendingContent else {
            result.status = .failed
            result.failureReason = "Plan içeriği yok; değişiklik yeniden planlanmalı."
            return result
        }
        let current = (try? String(contentsOfFile: transaction.configPath, encoding: .utf8)) ?? ""
        // Optimistic lock: the plan was computed against `baseHash`, so a file
        // touched since then must be re-planned rather than overwritten.
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
            try Data(pendingContent.utf8).write(
                to: URL(fileURLWithPath: transaction.configPath), options: .atomic
            )
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
            result.failureReason = "Geri alınacak yedek yok; eski durum korunuyor."
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
        .restartRequired("Claude Code config'i başlangıçta okur; açık oturumlar yeniden başlatılmalı.")
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? {
        installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
    }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - JSON handling

    nonisolated static func parseServers(_ raw: String) throws -> [MCPServerDefinition] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AgentAdapterError.configMalformed("~/.claude.json")
        }
        let servers = object["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name -> MCPServerDefinition? in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let environment = entry["env"] as? [String: String] ?? [:]
            let split = AgentAdapterSupport.partitionEnvironment(environment)
            let url = entry["url"] as? String
            let command = entry["command"] as? String
            return MCPServerDefinition(
                id: "claudeCode:\(name)",
                name: name,
                transport: url == nil ? .stdio : .http,
                command: command,
                arguments: entry["args"] as? [String] ?? [],
                url: url,
                environmentKeys: split.secretKeys,
                environment: split.plain,
                isEnabled: (entry["disabled"] as? Bool).map { !$0 } ?? true
            )
        }
    }

    /// Applies `changes` to the raw JSON, touching only `mcpServers`.
    nonisolated static func applying(
        _ changes: [ConfigurationChange],
        to raw: String
    ) throws -> String {
        var root: [String: Any]
        if raw.isEmpty {
            root = [:]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw AgentAdapterError.configMalformed("~/.claude.json")
            }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]

        for change in changes {
            switch change {
            case .addMCPServer(let definition):
                var entry: [String: Any] = [:]
                switch definition.transport {
                case .stdio:
                    guard let command = definition.command, !command.isEmpty else {
                        throw AgentAdapterError.unsupportedChange("\(definition.name): komut gerekli")
                    }
                    entry["command"] = command
                    if !definition.arguments.isEmpty { entry["args"] = definition.arguments }
                case .http:
                    guard let url = definition.url, !url.isEmpty else {
                        throw AgentAdapterError.unsupportedChange("\(definition.name): URL gerekli")
                    }
                    entry["url"] = url
                }
                // Secret VALUES never reach an agent config, even if a caller
                // put one in `environment`: the launcher injects them from the
                // Keychain at start-up instead.
                let safeEnvironment = definition.environment.filter {
                    !AgentAdapterSupport.isSecretKey($0.key)
                }
                if !safeEnvironment.isEmpty { entry["env"] = safeEnvironment }
                if !definition.isEnabled { entry["disabled"] = true }
                servers[definition.name] = entry
            case .removeMCPServer(let name):
                servers.removeValue(forKey: name)
            case .setMCPServerEnabled(let name, let isEnabled):
                guard var entry = servers[name] as? [String: Any] else {
                    throw AgentAdapterError.unsupportedChange("\(name) tanımlı değil")
                }
                if isEnabled {
                    entry.removeValue(forKey: "disabled")
                } else {
                    entry["disabled"] = true
                }
                servers[name] = entry
            }
        }

        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentAdapterError.writeFailed("JSON kodlanamadı")
        }
        return text + "\n"
    }
}
