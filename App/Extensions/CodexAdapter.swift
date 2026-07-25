import Foundation

/// Codex: TOML config at `~/.codex/config.toml`, skills under
/// `~/.codex/skills/`, MCP servers in `[mcp_servers.*]` tables.
///
/// TOML round-trips comments and key order, so edits are surgical: only the
/// `[mcp_servers.<name>]` block being changed is rewritten and every other line
/// stays byte-identical.
@MainActor
struct CodexAdapter: AgentAdapter {
    let agent = ExtensionAgentID.codex

    let capabilities = AgentProviderCapabilities(
        readsSkillsFromDirectory: true,
        supportsPerSkillSymlinks: true,
        supportsStdioMCP: true,
        supportsHTTPMCP: true,
        supportsProjectScopedMCP: false,
        reloadsConfigWithoutRestart: false,
        preservesUnknownConfigKeys: true,
        reportsAuthenticationState: true
    )

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var binaryPathOverride: String?

    func detectInstallations() -> [AgentInstallation] {
        let configDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        guard let binaryPath = binaryPathOverride
            ?? AgentAdapterSupport.locateBinary("codex") else { return [] }
        return [
            AgentInstallation(
                agent: agent,
                binaryPath: binaryPath,
                configDirectory: configDirectory.path,
                skillsDirectory: configDirectory.appendingPathComponent("skills", isDirectory: true).path,
                mcpConfigPath: configDirectory.appendingPathComponent("config.toml").path,
                version: nil,
                // `auth.json` presence is the cheap signal; the app-server's
                // `account/read` is the authoritative one.
                isAuthenticated: FileManager.default.fileExists(
                    atPath: configDirectory.appendingPathComponent("auth.json").path
                ),
                detectedAt: .now
            ),
        ]
    }

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration {
        let path = installation.mcpConfigPath
            ?? homeDirectory.appendingPathComponent(".codex/config.toml").path
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
            mcpServers: CodexTOML.servers(in: raw),
            skillNames: AgentAdapterSupport.skillNames(
                in: installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
            )
        )
    }

    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        for server in configuration.mcpServers {
            switch server.transport {
            case .stdio where (server.command ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "codex.mcp.\(server.name).command",
                    severity: .error,
                    message: "\(server.name) STDIO sunucusunun komutu yok.",
                    remedy: "Komutu ekle veya sunucuyu kaldır."
                ))
            case .http where (server.url ?? "").isEmpty:
                issues.append(ConfigurationIssue(
                    id: "codex.mcp.\(server.name).url",
                    severity: .error,
                    message: "\(server.name) HTTP sunucusunun adresi yok.",
                    remedy: "URL ekle veya sunucuyu kaldır."
                ))
            default:
                break
            }
            if !server.environmentKeys.isEmpty {
                issues.append(ConfigurationIssue(
                    id: "codex.mcp.\(server.name).secrets",
                    severity: .warning,
                    message: "\(server.name) config.toml içinde secret tutuyor: \(server.environmentKeys.joined(separator: ", ")).",
                    remedy: "Uncoil launcher'a taşıyarak değeri Keychain'de tut."
                ))
            }
        }
        // Bumblebee does not read Codex's TOML MCP config, so say so rather
        // than let a clean scan imply coverage.
        if !configuration.mcpServers.isEmpty {
            issues.append(ConfigurationIssue(
                id: "codex.mcp.coverage",
                severity: .warning,
                message: "Codex TOML MCP config'i Bumblebee taramasının kapsamı dışında.",
                remedy: "Bu sunucular için Uncoil'in kendi taramasına güven."
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
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: transaction.configPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
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
        .restartRequired("Codex config.toml'u başlangıçta okur; app-server yeniden başlatılmalı.")
    }

    func skillsDirectory(for installation: AgentInstallation) -> URL? {
        installation.skillsDirectory.map { URL(fileURLWithPath: $0) }
    }

    func mcpConfigLocation(for installation: AgentInstallation) -> URL? {
        installation.mcpConfigPath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - TOML handling

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
                    throw AgentAdapterError.unsupportedChange("\(definition.name): komut gerekli")
                case .http where (definition.url ?? "").isEmpty:
                    throw AgentAdapterError.unsupportedChange("\(definition.name): URL gerekli")
                default:
                    break
                }
                result = CodexTOML.rewrite(
                    result, name: definition.name, with: CodexTOML.render(definition)
                )
            case .removeMCPServer(let name):
                result = CodexTOML.rewrite(result, name: name, with: nil)
            case .setMCPServerEnabled(let name, let isEnabled):
                guard var definition = CodexTOML.servers(in: result)
                    .first(where: { $0.name == name }) else {
                    throw AgentAdapterError.unsupportedChange("\(name) tanımlı değil")
                }
                definition.isEnabled = isEnabled
                result = CodexTOML.rewrite(
                    result, name: name, with: CodexTOML.render(definition)
                )
            }
        }
        return result
    }
}
