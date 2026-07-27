import Foundation

/// Turns a catalog entry into an installed extension, through the machinery
/// that already exists: MCP servers go through adapter plan → apply → rollback
/// (a diff on screen before any config is written), skills go through staging,
/// the security scanner, the install guard and the central `SkillStore`.
///
/// Nothing here bypasses a rule an ordinary install obeys: catalog inclusion
/// is not treated as proof of safety.
@MainActor
struct CatalogInstallService {
    var layout: ExtensionStoreLayout
    var store: SkillStore
    var adapters: AgentAdapterRegistry

    init(
        layout: ExtensionStoreLayout = .default(),
        store: SkillStore? = nil,
        adapters: AgentAdapterRegistry? = nil
    ) {
        self.layout = layout
        self.store = store ?? SkillStore(layout: layout)
        self.adapters = adapters ?? AgentAdapterRegistry()
    }

    // MARK: - Compatibility

    /// Why an agent cannot take this item, or nil when it can.
    func incompatibilityReason(
        agent: ExtensionAgentID,
        item: CatalogItem,
        installations: [AgentInstallation],
        choice: MCPInstallChoice? = nil
    ) -> String? {
        guard let installation = installations.first(where: { $0.agent == agent }) else {
            return String(localized: "Not installed on this machine")
        }
        switch item.kind {
        case .skill:
            guard installation.skillsDirectory != nil else {
                return String(localized: "Has no skills directory")
            }
            return nil
        case .mcpServer:
            guard let capabilities = adapters.adapter(for: agent)?.capabilities else {
                return String(localized: "No adapter for this agent")
            }
            switch choice {
            case .package where !capabilities.supportsStdioMCP:
                return String(localized: "Does not support STDIO MCP servers")
            case .remote where !capabilities.supportsHTTPMCP:
                return String(localized: "Does not support HTTP MCP servers")
            default:
                return nil
            }
        }
    }

    // MARK: - MCP

    /// The installable forms one MCP entry offers.
    enum MCPInstallChoice: Equatable, Identifiable {
        case package(MCPCatalogPackage)
        case remote(MCPCatalogRemote)

        var id: String {
            switch self {
            case .package(let package): "package:\(package.label)"
            case .remote(let remote): "remote:\(remote.url)"
            }
        }

        var label: String {
            switch self {
            case .package(let package): package.label
            case .remote(let remote): remote.label
            }
        }
    }

    static func choices(for item: CatalogItem) -> [MCPInstallChoice] {
        guard let mcp = item.mcp else { return [] }
        return mcp.packages.filter { $0.runtime != nil }.map(MCPInstallChoice.package)
            + mcp.remotes.filter { $0.transport != nil }.map(MCPInstallChoice.remote)
    }

    /// The definition the agent configs would carry. Secret-looking variables
    /// become Keychain-backed names; plain defaults stay in config.
    func definition(for item: CatalogItem, choice: MCPInstallChoice) throws -> MCPServerDefinition {
        let name = item.installName
        switch choice {
        case .remote(let remote):
            guard let transport = remote.transport else {
                throw AgentAdapterError.unsupportedChange(
                    "Remote transport \(remote.type) is not supported."
                )
            }
            return MCPServerDefinition(
                id: "catalog:\(item.id)", name: name, transport: transport, url: remote.url
            )
        case .package(let package):
            guard let runtime = package.runtime else {
                throw AgentAdapterError.unsupportedChange(
                    "Package type \(package.registryType) is not supported."
                )
            }
            var secretKeys: [String] = []
            var plain: [String: String] = [:]
            for env in package.environmentVariables {
                if env.isEffectivelySecret {
                    secretKeys.append(env.name)
                } else if let value = env.defaultValue {
                    plain[env.name] = value
                } else if env.isRequired {
                    // Required, no default, not secret: still has to come from
                    // the user, so it travels the same value-less path.
                    secretKeys.append(env.name)
                }
            }
            return MCPServerDefinition(
                id: "catalog:\(item.id)",
                name: name,
                transport: .stdio,
                command: runtime.command,
                arguments: runtime.arguments,
                environmentKeys: secretKeys.sorted(),
                environment: plain
            )
        }
    }

    /// One agent's part of an MCP install: the planned config diff, or the
    /// reason there is nothing to do.
    struct MCPAgentPlan: Identifiable {
        var agent: ExtensionAgentID
        var installation: AgentInstallation
        var transaction: ConfigurationTransaction?
        var changes: [ConfigurationChange]
        /// Set when planning failed or was refused (already installed, …).
        var blocked: String?

        var id: String { agent.rawValue }
    }

    /// Plans the config edit for every selected agent. Read-only: the diffs go
    /// on screen and nothing is written until `apply`.
    func planMCPInstall(
        definition: MCPServerDefinition,
        agents: [ExtensionAgentID],
        installations: [AgentInstallation],
        configurations: [AgentConfiguration]
    ) -> [MCPAgentPlan] {
        let service = ConfigurationTransactionService(registry: adapters)
        return agents.compactMap { agent in
            guard let installation = installations.first(where: { $0.agent == agent }) else {
                return nil
            }
            // Duplicate guard: an agent that already declares this name keeps
            // what it has; installing over it silently is exactly the accident
            // this screen exists to prevent.
            if let configuration = configurations.first(where: { $0.installation.agent == agent }),
               configuration.mcpServers.contains(where: { $0.name == definition.name }) {
                return MCPAgentPlan(
                    agent: agent, installation: installation, transaction: nil,
                    changes: [], blocked: String(localized: "Already declares “\(definition.name)”")
                )
            }
            let changes: [ConfigurationChange] = [.addMCPServer(definition)]
            do {
                let (transaction, _) = try service.plan(changes, agent: agent, installation: installation)
                return MCPAgentPlan(
                    agent: agent, installation: installation,
                    transaction: transaction, changes: changes, blocked: nil
                )
            } catch {
                return MCPAgentPlan(
                    agent: agent, installation: installation, transaction: nil,
                    changes: changes, blocked: error.localizedDescription
                )
            }
        }
    }

    struct AgentResult: Identifiable, Equatable {
        var agent: ExtensionAgentID
        var success: Bool
        var message: String

        var id: String { agent.rawValue }
    }

    /// Applies the planned config edits, records each transaction, and puts
    /// the server into the registry as a package. Failures stay per-agent: one
    /// agent's stale config never stops another's install.
    func applyMCPInstall(
        item: CatalogItem,
        definition: MCPServerDefinition,
        plans: [MCPAgentPlan],
        registry: ExtensionRegistry,
        now: Date = .now
    ) -> [AgentResult] {
        let service = ConfigurationTransactionService(registry: adapters)
        var results: [AgentResult] = []
        var appliedAgents: [ExtensionAgentID] = []
        for plan in plans {
            if let blocked = plan.blocked {
                results.append(AgentResult(agent: plan.agent, success: false, message: blocked))
                continue
            }
            guard let transaction = plan.transaction else { continue }
            do {
                let outcome = try service.apply(
                    transaction, changes: plan.changes, installation: plan.installation
                )
                registry.recordConfigTransaction(outcome.transaction)
                registry.record(ConfigurationTransactionService.auditEvent(
                    for: outcome, extensionID: definition.id
                ))
                if outcome.didApply {
                    appliedAgents.append(plan.agent)
                    results.append(AgentResult(
                        agent: plan.agent, success: true,
                        message: String(localized: "Installed · backup taken")
                    ))
                } else {
                    results.append(AgentResult(
                        agent: plan.agent, success: false,
                        message: outcome.needsReview
                            ? String(localized: "Config changed on disk; review the new plan")
                            : (outcome.transaction.failureReason ?? String(localized: "Not applied"))
                    ))
                }
            } catch {
                results.append(AgentResult(
                    agent: plan.agent, success: false, message: error.localizedDescription
                ))
            }
        }

        // The package is recorded once and only after something was written:
        // a failed install leaves the registry as it was.
        if !appliedAgents.isEmpty {
            let source: ExtensionSource = definition.transport == .http
                ? .remoteMCP(url: definition.url ?? "", transport: .http)
                : .adopted(path: layout.revisions
                    .appendingPathComponent("adopted", isDirectory: true)
                    .appendingPathComponent(definition.name, isDirectory: true).path)
            if definition.transport == .stdio {
                // The definition also lands in the store as JSON, the same way
                // an adopted server is recorded, so there is one recorded shape.
                let adoption = ExtensionAdoptionService(layout: layout, store: store)
                if let plan = try? adoption.planDefinition(definition, now: now),
                   let package = try? adoption.adopt(plan, now: now) {
                    var stamped = package
                    stamped.summary = String(localized: "From \(item.provider.label) · \(definition.displayTarget)")
                    registry.upsert(stamped)
                } else {
                    registry.upsert(fallbackPackage(item: item, definition: definition, source: source, now: now))
                }
            } else {
                registry.upsert(fallbackPackage(item: item, definition: definition, source: source, now: now))
            }
            if let packageID = registry.packages.first(where: {
                $0.kind == .mcpServer && $0.name == definition.name
            })?.id {
                for agent in appliedAgents {
                    registry.setAgentBinding(true, packageID: packageID, agent: agent)
                }
            }
        }
        return results
    }

    private func fallbackPackage(
        item: CatalogItem,
        definition: MCPServerDefinition,
        source: ExtensionSource,
        now: Date
    ) -> ExtensionPackage {
        ExtensionPackage(
            id: definition.id,
            kind: .mcpServer,
            name: definition.name,
            summary: String(localized: "From \(item.provider.label) · \(definition.displayTarget)"),
            source: source,
            lastFetchedAt: now
        )
    }

    // MARK: - Skills

    /// Everything a skill install needs to show before anything is written.
    struct SkillInstallPlan {
        var item: CatalogItem
        /// Temporary staging copy of the full file set.
        var stagedPath: URL
        var preview: ExtensionInstallPreview
        var structureIssues: [String]
        /// The version pinned into the revision id: the registry's content
        /// hash when it has one, else the staged content hash.
        var pinnedHash: String
        var revisionID: String

        func blockers(userApprovedExecutables: Bool) -> [ExtensionInstallGuard.Blocker] {
            ExtensionInstallGuard.blockers(
                preview: preview,
                requestedReference: pinnedHash,
                userApprovedExecutables: userApprovedExecutables,
                structureIssues: structureIssues
            )
        }
    }

    /// Writes the fetched files into a staging directory and inspects them:
    /// structure, manifest claims, Uncoil's scanner. Download and analysis
    /// happen here, never in the agents' directories.
    func stageSkill(item: CatalogItem, now: Date = .now) throws -> SkillInstallPlan {
        guard let skill = item.skill, let files = skill.files, !files.isEmpty else {
            throw CatalogError.malformed("The skill's files were not fetched.")
        }
        try layout.ensure()
        let staging = layout.root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent("catalog-\(skill.slug)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in files {
            // Path safety: a registry answer never places files outside the
            // staging directory.
            let clean = file.path.split(separator: "/").map(String.init)
            guard !clean.isEmpty, !clean.contains(".."), !file.path.hasPrefix("/") else {
                throw CatalogError.malformed("Unsafe file path “\(file.path)”.")
            }
            let target = clean.reduce(staging) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (file.binaryContents ?? Data(file.contents.utf8))
                .write(to: target, options: .atomic)
        }

        let contentHash = SkillStore.contentHash(of: staging)
        // Pin priority: the exact commit the provider resolved, then a
        // provider content hash, then the staged bytes themselves — always
        // something an update check can compare against deterministically.
        let pinned = skill.pinRef ?? contentHash
        let scan = ExtensionSecurityScanner.scan(
            packageAt: staging, extensionID: "catalog:\(item.id)", now: now
        )
        let installedPath: URL? = {
            let active = layout.activeSkill(skill.slug)
            return FileManager.default.fileExists(atPath: active.path) ? active : nil
        }()
        let preview = ExtensionInstallPreviewBuilder.preview(
            name: skill.slug,
            kind: .skill,
            source: .gitHubRepository(
                repository: skill.source,
                subpath: skill.directory.isEmpty ? nil : skill.directory,
                reference: skill.commitSHA
            ),
            materializedPath: staging,
            installedPath: installedPath,
            tracking: String(localized: "pinned content hash \(CatalogStore.shortHash(pinned))"),
            lastCommit: nil,
            resolvedCommit: pinned,
            findings: scan.findings
        )
        return SkillInstallPlan(
            item: item,
            stagedPath: staging,
            preview: preview,
            structureIssues: ExtensionUpdateEngine.structureIssues(at: staging, kind: .skill),
            pinnedHash: pinned,
            revisionID: "catalog/\(skill.slug)@\(CatalogStore.shortHash(pinned))"
        )
    }

    /// Installs the staged skill for the selected agents: one immutable copy
    /// in the store, one symlink per agent. The staging directory is removed
    /// afterwards, success or not.
    func installSkill(
        plan: SkillInstallPlan,
        agents: [ExtensionAgentID],
        installations: [AgentInstallation],
        registry: ExtensionRegistry,
        userApprovedExecutables: Bool,
        now: Date = .now
    ) throws -> [AgentResult] {
        defer { try? FileManager.default.removeItem(at: plan.stagedPath) }
        let blockers = plan.blockers(userApprovedExecutables: userApprovedExecutables)
        guard blockers.isEmpty else {
            throw AgentAdapterError.unsupportedChange(blockers[0].message)
        }
        guard let skill = plan.item.skill else {
            throw CatalogError.malformed("Not a skill entry.")
        }
        let name = skill.slug
        let existing = registry.packages.first { $0.kind == .skill && $0.name == name }
        // A copy Uncoil does not own is not overwritten from the catalog; the
        // Skills screen's adoption flow is the door for that.
        if let existing, !existing.source.isOwnedByUncoil {
            throw AgentAdapterError.unsupportedChange(String(
                localized: "“\(name)” is already installed outside Uncoil. Adopt it on the Skills screen first."
            ))
        }

        var revision = try store.install(
            from: plan.stagedPath, name: name, revisionID: plan.revisionID,
            commitSHA: skill.commitSHA, now: now
        )
        revision.changelog = String(
            localized: "Installed from \(plan.item.provider.label) (\(skill.source))"
        ) + (skill.commitSHA.map { " @ \(String($0.prefix(12)))" } ?? "")
        _ = try? store.linkCanonical(name: name)

        var results: [AgentResult] = []
        for agent in agents {
            guard let directory = installations.first(where: { $0.agent == agent })?
                .skillsDirectory else {
                results.append(AgentResult(
                    agent: agent, success: false,
                    message: String(localized: "Has no skills directory")
                ))
                continue
            }
            do {
                _ = try store.link(name: name, intoAgentDirectory: URL(fileURLWithPath: directory))
                results.append(AgentResult(
                    agent: agent, success: true, message: String(localized: "Linked")
                ))
            } catch {
                results.append(AgentResult(
                    agent: agent, success: false, message: error.localizedDescription
                ))
            }
        }

        var package = existing ?? ExtensionPackage(
            id: "catalog:\(plan.item.id)",
            kind: .skill,
            name: name,
            source: .adopted(path: layout.revision(plan.revisionID).path)
        )
        package.summary = plan.item.summary
            ?? String(localized: "From \(plan.item.provider.label) · \(skill.source)")
        package.previousRevision = existing?.activeRevision
        package.activeRevision = revision
        package.source = .adopted(path: layout.revision(plan.revisionID).path)
        package.state = .active
        package.lastFetchedAt = now
        package.lastScannedAt = now
        package.hasLocalModification = false
        registry.upsert(package)
        registry.setFindings(plan.preview.findings, forExtension: package.id)
        for result in results where result.success {
            registry.setAgentBinding(true, packageID: package.id, agent: result.agent)
        }
        registry.record(AuditEvent(
            kind: .skillInstalled,
            extensionID: package.id,
            detail: String(
                localized: "\(name) from \(plan.item.provider.label), pinned \(CatalogStore.shortHash(plan.pinnedHash))"
            )
        ))
        return results
    }

    /// Removes staging leftovers from installs that never finished.
    func discardStaging(_ plan: SkillInstallPlan) {
        try? FileManager.default.removeItem(at: plan.stagedPath)
    }
}
