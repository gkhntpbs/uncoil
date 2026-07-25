import Foundation

/// Persisted state of the Extensions system, plus the discovery pass that finds
/// what is already installed.
///
/// Discovery is deliberately non-destructive: an extension Uncoil did not
/// install is recorded as `detectedExternal` and shown read-only until the user
/// adopts it. Nothing is relinked, rewritten or removed as a side effect of
/// looking.
@MainActor
final class ExtensionRegistry: ObservableObject {
    struct Document: Codable, Equatable {
        static let currentVersion = 1
        var version = Document.currentVersion
        var packages: [ExtensionPackage] = []
        var agentBindings: [AgentBinding] = []
        var projectBindings: [ProjectBinding] = []
        var findings: [SecurityFinding] = []
        var updateCandidates: [UpdateCandidate] = []
        /// Repositories the user added, so Sources can list one even before it
        /// has produced an extension.
        var sources: [String] = []
        /// Applied config changes, so "go back to the previous config" is one
        /// click away after a restart too. `pendingContent` is dropped before
        /// storing: it holds a copy of the user's config, secrets included.
        var configTransactions: [ConfigurationTransaction] = []
    }

    @Published private(set) var packages: [ExtensionPackage] = []
    @Published private(set) var agentBindings: [AgentBinding] = []
    @Published private(set) var projectBindings: [ProjectBinding] = []
    @Published private(set) var findings: [SecurityFinding] = []
    @Published private(set) var updateCandidates: [UpdateCandidate] = []
    @Published private(set) var sources: [String] = []
    @Published private(set) var auditEvents: [AuditEvent] = []
    /// Config changes Uncoil applied, newest first.
    @Published private(set) var configTransactions: [ConfigurationTransaction] = []

    /// Transient (not persisted): rediscovered on every launch.
    @Published private(set) var installations: [AgentInstallation] = []
    @Published private(set) var configurations: [AgentConfiguration] = []
    @Published private(set) var configurationIssues: [ConfigurationIssue] = []
    @Published private(set) var unmanagedSkills: [ExtensionAgentID: [String]] = [:]
    @Published private(set) var linkStatuses: [String: SkillLinkStatus] = [:]
    @Published private(set) var health: [HealthCheckResult] = []
    /// Per-MCP process health, refreshed by `discover`.
    @Published private(set) var processHealth: [String: MCPProcessHealth] = [:]
    /// When each MCP server was last checked, and what it last said went wrong.
    @Published private(set) var lastHealthCheckAt: [String: Date] = [:]
    @Published private(set) var lastErrors: [String: String] = [:]
    /// What a remote MCP server reported having, keyed by package id. Empty means
    /// nothing asked it yet — not that it has nothing.
    @Published private(set) var reportedCapabilities: [String: [String]] = [:]
    @Published private(set) var lastDiscoveryAt: Date?

    let layout: ExtensionStoreLayout
    private let store: SkillStore
    private let auditFileName = "audit.jsonl"

    init(layout: ExtensionStoreLayout = .default(), store: SkillStore? = nil) {
        self.layout = layout
        self.store = store ?? SkillStore(layout: layout)
        load()
    }

    // MARK: - Persistence

    var documentURL: URL {
        layout.locks.appendingPathComponent("registry.json")
    }

    private var auditURL: URL {
        layout.audit.appendingPathComponent(auditFileName)
    }

    func load() {
        // The audit log is read first and unconditionally: it is a separate
        // append-only file precisely so a missing or corrupt registry never
        // loses the history of what happened.
        auditEvents = loadAudit()
        guard let data = FileManager.default.contents(atPath: documentURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data),
              document.version <= Document.currentVersion else { return }
        packages = document.packages
        agentBindings = document.agentBindings
        projectBindings = document.projectBindings
        findings = document.findings
        updateCandidates = document.updateCandidates
        sources = document.sources
        configTransactions = document.configTransactions
        health = healthChecks()
    }

    func save() {
        try? layout.ensure()
        let document = Document(
            packages: packages,
            agentBindings: agentBindings,
            projectBindings: projectBindings,
            findings: findings,
            updateCandidates: updateCandidates,
            sources: sources,
            configTransactions: configTransactions
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return }
        AtomicFile.write(data, to: documentURL)
    }

    // MARK: - Audit

    /// Appends to an append-only log. Kept separate from the registry document
    /// so a corrupt registry never loses the history of what happened.
    func record(_ event: AuditEvent) {
        auditEvents.insert(event, at: 0)
        if auditEvents.count > 500 { auditEvents.removeLast(auditEvents.count - 500) }
        try? layout.ensure()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: auditURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: auditURL, options: .atomic)
        }
    }

    private func loadAudit() -> [AuditEvent] {
        guard let data = FileManager.default.contents(atPath: auditURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(AuditEvent.self, from: Data($0)) }
            .reversed()
    }

    /// Remembers an applied or rolled-back config change.
    ///
    /// The pending content is stripped: it is a full copy of the agent's config
    /// and has no business sitting in a file Uncoil keeps around. The backup path
    /// is what a rollback actually needs.
    func recordConfigTransaction(_ transaction: ConfigurationTransaction) {
        var stored = transaction
        stored.pendingContent = nil
        if let index = configTransactions.firstIndex(where: { $0.id == stored.id }) {
            configTransactions[index] = stored
        } else {
            configTransactions.insert(stored, at: 0)
        }
        if configTransactions.count > 100 {
            configTransactions.removeLast(configTransactions.count - 100)
        }
        save()
    }

    /// The change a "go back to the previous config" button would undo for this
    /// agent: the newest applied transaction that still has its backup.
    func rollbackCandidate(for agent: ExtensionAgentID) -> ConfigurationTransaction? {
        configTransactions.first { transaction in
            transaction.agent == agent
                && transaction.status == .applied
                && transaction.backupPath.map {
                    FileManager.default.fileExists(atPath: $0)
                } == true
        }
    }

    // MARK: - Mutation

    func upsert(_ package: ExtensionPackage) {
        if let index = packages.firstIndex(where: { $0.id == package.id }) {
            packages[index] = package
        } else {
            packages.append(package)
        }
        save()
    }

    func remove(packageID: String) {
        packages.removeAll { $0.id == packageID }
        agentBindings.removeAll { $0.extensionID == packageID }
        projectBindings.removeAll { $0.extensionID == packageID }
        findings.removeAll { $0.extensionID == packageID }
        save()
    }

    func setState(_ state: ExtensionState, packageID: String) {
        guard let index = packages.firstIndex(where: { $0.id == packageID }) else { return }
        let previous = packages[index].state
        packages[index].state = state
        save()
        record(AuditEvent(
            kind: {
                switch state {
                case .quarantined: .quarantined
                case .active where previous == .quarantined: .restored
                case .active: .mcpEnabled
                case .disabled: .mcpDisabled
                case .broken: .scanCompleted
                }
            }(),
            extensionID: packageID,
            detail: "\(previous.label) → \(state.label)"
        ))
    }

    func setAgentBinding(_ isEnabled: Bool, packageID: String, agent: ExtensionAgentID) {
        agentBindings = SkillAssignment.setting(
            isEnabled, extensionID: packageID, agent: agent, in: agentBindings
        )
        save()
        record(AuditEvent(
            kind: .assignmentChanged, extensionID: packageID, agent: agent,
            detail: isEnabled ? "atandı" : "kaldırıldı"
        ))
    }

    func setProjectBinding(_ binding: ProjectBinding) {
        projectBindings.removeAll { $0.id == binding.id }
        projectBindings.append(binding)
        save()
        record(AuditEvent(
            kind: .assignmentChanged, extensionID: binding.extensionID,
            agent: binding.agent,
            detail: binding.isGlobal ? "global atama" : "proje ataması"
        ))
    }

    func setFindings(_ newFindings: [SecurityFinding], forExtension extensionID: String?) {
        findings.removeAll { $0.extensionID == extensionID }
        findings.append(contentsOf: newFindings)
        // A new finding has to show up in health without waiting for the next
        // discovery pass.
        health = healthChecks()
        save()
    }

    func acceptFinding(id: String) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[index].isAccepted = true
        health = healthChecks()
        save()
        record(AuditEvent(
            kind: .findingAccepted, extensionID: findings[index].extensionID,
            detail: findings[index].rule
        ))
    }

    func setUpdateCandidates(_ candidates: [UpdateCandidate]) {
        updateCandidates = candidates
        save()
    }

    func addSource(_ repository: String) {
        guard !sources.contains(repository) else { return }
        sources.append(repository)
        save()
    }

    func removeSource(_ repository: String) {
        sources.removeAll { $0 == repository }
        save()
    }

    // MARK: - Discovery

    /// Detects agents, reads their configs, and records what is installed. Every
    /// extension Uncoil did not install becomes a read-only `detectedExternal`
    /// entry; nothing on disk is modified.
    func discover(
        adapters: AgentAdapterRegistry? = nil,
        launcherPath: String? = nil,
        now: Date = .now
    ) {
        let adapters = adapters ?? AgentAdapterRegistry()
        let launcherPath = launcherPath ?? ExtensionLauncherService.bundledLauncherPath()
        installations = adapters.detectInstallations()
        let read = adapters.readAll()
        configurations = read.configurations
        configurationIssues = read.failures + read.configurations.flatMap { configuration in
            adapters.adapter(for: configuration.installation.agent)?
                .validate(configuration) ?? []
        }

        var discovered = packages.filter { $0.source.isOwnedByUncoil }
        var unmanaged: [ExtensionAgentID: [String]] = [:]
        var statuses: [String: SkillLinkStatus] = [:]

        for configuration in configurations {
            let agent = configuration.installation.agent

            // MCP servers, split by who owns them.
            for server in configuration.mcpServers {
                let isOurs = server.command == launcherPath
                let id = isOurs
                    ? (server.arguments.count >= 2 ? server.arguments[1] : "\(agent.rawValue):\(server.name)")
                    : "\(agent.rawValue):\(server.name)"
                if isOurs, discovered.contains(where: { $0.id == id }) { continue }
                if discovered.contains(where: { $0.id == id }) { continue }
                let source: ExtensionSource = {
                    if server.transport == .http, let url = server.url {
                        return .remoteMCP(url: url, transport: .http)
                    }
                    return .detectedExternal(path: server.displayTarget)
                }()
                discovered.append(ExtensionPackage(
                    id: id,
                    kind: .mcpServer,
                    name: server.name,
                    summary: server.displayTarget,
                    source: source,
                    state: server.isEnabled ? .active : .disabled
                ))
            }

            // Skills: ours are symlinks into the store, the rest are the user's.
            guard let directory = configuration.installation.skillsDirectory
                .map({ URL(fileURLWithPath: $0) }) else { continue }
            unmanaged[agent] = store.unmanagedSkills(in: directory)
            for name in unmanaged[agent] ?? [] {
                let id = "local:\(name)"
                guard !discovered.contains(where: { $0.id == id }) else { continue }
                discovered.append(ExtensionPackage(
                    id: id, kind: .skill, name: name,
                    source: .detectedExternal(
                        path: directory.appendingPathComponent(name).path
                    )
                ))
            }
            for package in discovered where package.kind == .skill {
                let status = store.status(name: package.name, inAgentDirectory: directory)
                statuses["\(package.id)@\(agent.rawValue)"] = status
            }
        }

        // Local modification is a property of the files, not of the config.
        for index in discovered.indices {
            guard let revision = discovered[index].activeRevision else { continue }
            discovered[index].hasLocalModification = store.hasLocalModification(revision)
        }

        packages = discovered.sorted {
            $0.kind == $1.kind ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue
        }
        unmanagedSkills = unmanaged
        linkStatuses = statuses
        lastDiscoveryAt = now
        refreshProcessHealth(launcherPath: launcherPath, now: now)
        health = healthChecks(now: now)
        save()
    }

    // MARK: - MCP process health

    /// Reads what the launcher recorded about each MCP process: whether it is
    /// running, what it last exited with, and when we looked.
    func refreshProcessHealth(launcherPath: String, now: Date = .now) {
        let launcher = ExtensionLauncherService(layout: layout, launcherPath: launcherPath)
        let records = launcher.runRecords()
        guard !records.isEmpty else { return }
        let supervisor = MCPProcessSupervisor()
        let revisions = Dictionary(
            packages.compactMap { package -> (String, String)? in
                package.activeRevision.map { (package.id, $0.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        for health in supervisor.healthByExtension(
            records: records, activeRevisions: revisions, now: now
        ) {
            processHealth[health.id] = health
            lastHealthCheckAt[health.id] = now
            if let exitCode = health.lastExitCode, exitCode != 0 {
                lastErrors[health.id] = "çıkış kodu \(exitCode)"
            } else if let signal = health.lastSignal {
                lastErrors[health.id] = "sinyal \(signal) ile sonlandı"
            } else if health.crashCount > 0 {
                lastErrors[health.id] = "\(health.crashCount) kez çöktü"
            }
        }
    }

    /// Records what a probe learned from a remote server.
    func record(probe: RemoteMCPStatus, packageID: String, now: Date = .now) {
        reportedCapabilities[packageID] = probe.reportedCapabilities
        lastHealthCheckAt[packageID] = probe.checkedAt
        switch probe.reachability {
        case .reachable, .localProcess:
            lastErrors.removeValue(forKey: packageID)
        case .authenticationRequired(let message), .unreachable(let message):
            lastErrors[packageID] = message
        }
    }

    /// The log the launcher tees an MCP server's stderr into.
    func logURL(for package: ExtensionPackage) -> URL? {
        let url = layout.root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(package.name).log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Last lines of that log, for the panel.
    func logTail(for package: ExtensionPackage, lines: Int = 40) -> String? {
        guard let url = logURL(for: package),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let all = text.components(separatedBy: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }

    /// Asks the launcher's children to stop; the agent starts a fresh one on its
    /// next call, which is how a restart happens without Uncoil owning the
    /// process.
    @discardableResult
    func restart(_ package: ExtensionPackage, launcherPath: String? = nil) -> Int {
        guard let health = processHealth[package.id] else { return 0 }
        let stopped = MCPProcessSupervisor().shutdown(health)
        record(AuditEvent(
            kind: .mcpEnabled, extensionID: package.id,
            detail: "\(stopped.count) süreç durduruldu; agent yeniden başlatacak"
        ))
        return stopped.count
    }

    // MARK: - Sources

    /// Pins a package to an exact commit, or moves what it follows. Both are the
    /// user's call and neither fetches anything on its own.
    func setTracking(
        _ tracking: ExtensionSource.TrackingMode,
        packageID: String
    ) -> Bool {
        guard let index = packages.firstIndex(where: { $0.id == packageID }),
              case .managedGitHub(let repository, let subpath, let previous) =
                packages[index].source else { return false }
        guard previous != tracking else { return false }
        packages[index].source = .managedGitHub(
            repository: repository, subpath: subpath, tracking: tracking
        )
        record(AuditEvent(
            kind: .configChanged, extensionID: packageID,
            detail: "takip değişti: \(previous.label) → \(tracking.label)"
        ))
        save()
        return true
    }

    // MARK: - Undo

    /// Whether an audit event describes something Uncoil can put back.
    static func isUndoable(_ event: AuditEvent) -> Bool {
        switch event.kind {
        case .quarantined, .restored, .assignmentChanged, .updateApplied, .findingAccepted:
            true
        case .skillInstalled, .skillRemoved, .mcpEnabled, .mcpDisabled, .configChanged,
             .rolledBack, .scanCompleted:
            false
        }
    }

    /// Undoes what an event did, when that is possible. Returns what happened, or
    /// nil when there is nothing Uncoil can safely reverse.
    @discardableResult
    func undo(_ event: AuditEvent) -> String? {
        guard Self.isUndoable(event), let extensionID = event.extensionID else { return nil }
        switch event.kind {
        case .quarantined:
            setState(.active, packageID: extensionID)
            return "Karantina geri alındı."
        case .restored:
            setState(.quarantined, packageID: extensionID)
            return "Geri yükleme geri alındı; paket yeniden karantinada."
        case .assignmentChanged:
            // The detail carries the agent and the direction it moved.
            guard let agent = ExtensionAgentID.allCases.first(where: {
                event.detail.contains($0.displayName) || event.detail.contains($0.rawValue)
            }) else { return nil }
            let isOn = agents(for: extensionID).contains(agent)
            setAgentBinding(!isOn, packageID: extensionID, agent: agent)
            return "Atama geri alındı: \(agent.displayName)."
        case .findingAccepted:
            guard let index = findings.firstIndex(where: {
                $0.extensionID == extensionID && $0.isAccepted
            }) else { return nil }
            findings[index].isAccepted = false
            save()
            return "Bulgu kabulü geri alındı."
        case .updateApplied:
            return nil
        default:
            return nil
        }
    }

    // MARK: - Derived views

    var managedPackages: [ExtensionPackage] {
        packages.filter { $0.source.isOwnedByUncoil }
    }

    var unmanagedPackages: [ExtensionPackage] {
        packages.filter { !$0.source.isOwnedByUncoil }
    }

    var skills: [ExtensionPackage] { packages.filter { $0.kind == .skill } }
    var mcpServers: [ExtensionPackage] { packages.filter { $0.kind == .mcpServer } }

    var brokenPackages: [ExtensionPackage] {
        packages.filter { $0.state == .broken }
            + packages.filter { package in
                linkStatuses.contains { $0.key.hasPrefix("\(package.id)@") && $0.value.needsRepair }
            }
    }

    /// Extensions whose files no longer match their revision, plus agent configs
    /// that no longer validate: everything that drifted away from what Uncoil
    /// recorded.
    var configDriftCount: Int {
        packages.filter(\.hasLocalModification).count
            + configurationIssues.filter { $0.severity == .error }.count
    }

    var openFindings: [SecurityFinding] {
        findings.filter { !$0.isAccepted }.sorted { $0.severity > $1.severity }
    }

    func agents(for packageID: String) -> [ExtensionAgentID] {
        SkillAssignment.activeAgents(extensionID: packageID, agentBindings: agentBindings)
    }

    func package(id: String) -> ExtensionPackage? {
        packages.first { $0.id == id }
    }

    func updateCandidate(for packageID: String) -> UpdateCandidate? {
        updateCandidates.first { $0.extensionID == packageID }
    }

    /// Repositories in play: the ones the user added plus the ones packages came
    /// from, so Sources never hides a repo an extension actually tracks.
    var effectiveSources: [String] {
        var result = Set(sources)
        for package in packages {
            if case .managedGitHub(let repository, _, _) = package.source {
                result.insert(repository)
            }
        }
        return result.sorted()
    }

    // MARK: - Health

    func healthChecks(now: Date = .now) -> [HealthCheckResult] {
        var results: [HealthCheckResult] = []

        results.append(HealthCheckResult(
            id: "health.agents",
            name: "Agent kurulumları",
            outcome: installations.isEmpty ? .failure : .ok,
            detail: installations.isEmpty
                ? "Yönetilebilir agent bulunamadı."
                : installations.map { $0.agent.displayName }.joined(separator: ", "),
            remedy: installations.isEmpty ? "Claude Code veya Codex kur." : nil,
            checkedAt: now
        ))

        let broken = brokenPackages
        results.append(HealthCheckResult(
            id: "health.links",
            name: "Symlink sağlığı",
            outcome: broken.isEmpty ? .ok : .failure,
            detail: broken.isEmpty
                ? "Tüm bağlantılar yerinde."
                : "\(broken.count) extension bozuk bağlantıya sahip.",
            remedy: broken.isEmpty ? nil : "Repair ile onar.",
            checkedAt: now
        ))

        let drift = configDriftCount
        results.append(HealthCheckResult(
            id: "health.drift",
            name: "Config drift",
            outcome: drift == 0 ? .ok : .warning,
            detail: drift == 0 ? "Kayıtla eşleşiyor." : "\(drift) sapma.",
            remedy: drift == 0 ? nil : "Diff'i incele; gerekirse rollback yap.",
            checkedAt: now
        ))

        let blocking = openFindings.filter { $0.severity >= .high }
        results.append(HealthCheckResult(
            id: "health.security",
            name: "Güvenlik bulguları",
            outcome: blocking.isEmpty ? .ok : (blocking.contains { $0.severity == .blocked } ? .failure : .warning),
            detail: openFindings.isEmpty
                ? "Açık bulgu yok."
                : "\(openFindings.count) açık bulgu, \(blocking.count) yüksek.",
            remedy: blocking.isEmpty ? nil : "Security ekranından incele.",
            checkedAt: now
        ))

        // Remote MCP servers have no local git, so an update check does not
        // apply — saying so beats showing them as never-updated.
        let remote = packages.filter {
            if case .remoteMCP = $0.source { return true }
            return false
        }
        if !remote.isEmpty {
            results.append(HealthCheckResult(
                id: "health.remote",
                name: "Remote MCP",
                outcome: .notApplicable,
                detail: "\(remote.count) uzak sunucu; sürüm sunucudan gelir.",
                remedy: nil,
                checkedAt: now
            ))
        }

        return results
    }

    /// Counts the Overview screen shows.
    struct Overview: Equatable {
        var agents: [String] = []
        var managedSkills = 0
        var unmanagedSkills = 0
        var mcpServers = 0
        var pendingUpdates = 0
        var brokenExtensions = 0
        var openFindings = 0
        var configDrift = 0
        var lastBumblebeeScan: Date?
        /// Nil when Bumblebee has never been run — never presented as "clean".
        var bumblebeeSummary: String?
    }

    var overview: Overview {
        Overview(
            agents: installations.map { $0.agent.displayName },
            managedSkills: skills.filter { $0.source.isOwnedByUncoil }.count,
            unmanagedSkills: skills.filter { !$0.source.isOwnedByUncoil }.count,
            mcpServers: mcpServers.count,
            pendingUpdates: updateCandidates.count,
            brokenExtensions: brokenPackages.count,
            openFindings: openFindings.count,
            configDrift: configDriftCount,
            lastBumblebeeScan: findings.filter { $0.origin == .bumblebee }.map(\.foundAt).max(),
            bumblebeeSummary: findings.contains { $0.origin == .bumblebee }
                ? "\(findings.filter { $0.origin == .bumblebee }.count) Bumblebee bulgusu"
                : nil
        )
    }
}
