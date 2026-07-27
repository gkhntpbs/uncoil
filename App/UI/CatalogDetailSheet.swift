import SwiftUI

/// The detail and install flow for one catalog entry.
///
/// Three stages, always in order: the facts (what it is, what it asks for),
/// the plan (exactly what would change, per agent), and the result (what
/// actually happened, per agent). Nothing is written before the plan stage
/// has been confirmed.
struct CatalogDetailSheet: View {
    let item: CatalogItem
    @ObservedObject var registry: ExtensionRegistry
    @ObservedObject var catalog: CatalogStore
    let scans: BumblebeeScanCoordinator
    @Binding var message: String?
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case detail
        case mcpPlan([CatalogInstallService.MCPAgentPlan], MCPServerDefinition)
        case skillPreview(CatalogInstallService.SkillInstallPlan, bumblebee: String?)
        case results([CatalogInstallService.AgentResult])
    }

    @State private var stage: Stage = .detail
    @State private var full: CatalogItem?
    @State private var facts: CatalogRepoFacts?
    @State private var versions: [CatalogVersionEntry] = []
    @State private var detailError: String?
    @State private var isWorking = false
    @State private var selectedAgents: Set<ExtensionAgentID> = []
    @State private var mcpChoice: CatalogInstallService.MCPInstallChoice?
    @State private var approveExecutables = false

    private var service: CatalogInstallService {
        CatalogInstallService(layout: registry.layout)
    }

    private var current: CatalogItem { full ?? item }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                stageBody
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .uncoilScrollers()
            }
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 640, height: 540)
        .background(Theme.bg)
        .accessibilityIdentifier("extensions.catalog.detail")
        .task { await loadDetail() }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            TablerIcon(
                name: item.kind == .skill ? "sparkles" : "server",
                size: 18, color: Theme.textDim
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(current.displayName)
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text(current.name)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .textSelection(.enabled)
            }
            Spacer()
            if current.isDeprecated {
                CatalogBadge(text: String(localized: "Deprecated"), tint: Theme.warn)
            } else if current.isOfficial {
                CatalogBadge(text: String(localized: "Official registry"), tint: Theme.info)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(footerNote)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(2)
            Spacer()
            switch stage {
            case .detail:
                Button("Close") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button(isWorking ? String(localized: "Preparing…") : installButtonTitle) {
                    Task { await prepareInstall() }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canPrepare || isWorking)
                .accessibilityIdentifier("extensions.catalog.install")
            case .mcpPlan(let plans, let definition):
                Button("Back") { stage = .detail }
                    .buttonStyle(GhostButtonStyle())
                Button(isWorking ? String(localized: "Applying…") : String(localized: "Apply")) {
                    Task { await applyMCP(plans: plans, definition: definition) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(isWorking || plans.allSatisfy { $0.blocked != nil })
                .accessibilityIdentifier("extensions.catalog.apply")
            case .skillPreview(let plan, _):
                Button("Back") {
                    service.discardStaging(plan)
                    stage = .detail
                }
                .buttonStyle(GhostButtonStyle())
                Button(isWorking ? String(localized: "Installing…") : String(localized: "Install")) {
                    Task { await applySkill(plan: plan) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(isWorking || !plan.blockers(userApprovedExecutables: approveExecutables).isEmpty)
                .accessibilityIdentifier("extensions.catalog.apply")
            case .results:
                Button("Close") { dismiss() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(16)
    }

    private var installButtonTitle: String {
        switch CatalogStore.installedState(of: current, packages: registry.packages) {
        case .updateAvailable: String(localized: "Update…")
        case .installed: String(localized: "Reinstall…")
        default: String(localized: "Install…")
        }
    }

    private var footerNote: String {
        switch stage {
        case .detail:
            String(localized: "Listing in a catalog is not a safety guarantee; the plan shows every change first.")
        case .mcpPlan:
            String(localized: "A backup of each config is taken before it is written; one click rolls it back.")
        case .skillPreview:
            String(localized: "The files are staged and scanned; nothing has touched an agent yet.")
        case .results:
            String(localized: "Details are on the Activity screen.")
        }
    }

    // MARK: - Stage bodies

    @ViewBuilder
    private var stageBody: some View {
        switch stage {
        case .detail: detailStage
        case .mcpPlan(let plans, _): mcpPlanStage(plans)
        case .skillPreview(let plan, let bumblebee): skillPreviewStage(plan, bumblebee: bumblebee)
        case .results(let results): resultsStage(results)
        }
    }

    private var detailStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detailError {
                HStack(spacing: 7) {
                    TablerIcon(name: "alert-triangle", size: 12, color: Theme.warn)
                    Text(detailError)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                    Button("Retry") { Task { await loadDetail(force: true) } }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            if let summary = current.summary {
                Text(summary)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            factRows
            if !current.audits.isEmpty { auditRows }
            if item.kind == .mcpServer { mcpRows } else { skillRows }
            agentPicker
        }
    }

    private var factRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let publisher = current.publisher {
                row(String(localized: "Publisher"), publisher)
            }
            if let repository = current.repository {
                row(String(localized: "Repository"), repository)
            } else if let url = current.repositoryURL {
                row(String(localized: "Source"), url)
            }
            if let version = current.version {
                row(String(localized: "Latest version"), version)
            }
            if let installedVersion {
                row(String(localized: "Installed version"), installedVersion)
            }
            if let updated = current.updatedAt {
                row(String(localized: "Updated"), RelativeClock.short(since: updated))
            }
            if let installs = current.installs {
                row(String(localized: "Installs"), "\(installs)")
            }
            if let stars = current.stars {
                row(String(localized: "GitHub stars"), "\(stars)")
            }
            if let sha = current.skill?.commitSHA {
                row(String(localized: "Pinned commit"), String(sha.prefix(12)))
            }
            if !current.topics.isEmpty {
                row(String(localized: "Topics"), current.topics.prefix(6).joined(separator: ", "))
            }
            if let license = current.license ?? facts?.license {
                row(String(localized: "License"), license)
            }
            if let stars = facts?.stars {
                row("GitHub", String(localized: "\(stars) stars")
                    + (facts?.pushedAt.map { " · " + String(localized: "pushed \(RelativeClock.short(since: $0))") } ?? "")
                    + ((facts?.archived == true) ? " · " + String(localized: "archived") : ""))
            }
            if !versions.isEmpty {
                row(
                    String(localized: "Release history"),
                    versions.prefix(5).map { entry in
                        entry.version + (entry.publishedAt.map { " (\(RelativeClock.short(since: $0)))" } ?? "")
                    }.joined(separator: ", ")
                )
            }
        }
        .panel()
    }

    private var installedVersion: String? {
        registry.packages
            .first { $0.kind == current.kind && $0.name == current.installName }?
            .activeRevision.map { revision in
                revision.commitSHA.map { String($0.prefix(12)) } ?? revision.id
            }
    }

    private var auditRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(current.audits.indices, id: \.self) { index in
                let audit = current.audits[index]
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(audit.isFailing ? Theme.danger
                            : audit.status.lowercased() == "warn" ? Theme.warn : Theme.ok)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(audit.provider) · \(audit.status.uppercased())"
                            + (audit.riskLevel.map { " · \($0)" } ?? ""))
                            .font(Theme.mono(.small, .semibold))
                            .foregroundStyle(Theme.text)
                        if let summary = audit.summary {
                            Text(summary)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .panel()
    }

    // MARK: MCP facts

    @ViewBuilder
    private var mcpRows: some View {
        let choices = CatalogInstallService.choices(for: current)
        VStack(alignment: .leading, spacing: 8) {
            Text("Installation method")
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.text)
            if choices.isEmpty {
                Text("This entry offers no package or endpoint Uncoil can install.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.warn)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices) { choice in
                        Button {
                            mcpChoice = choice
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: mcpChoice == choice
                                    ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(mcpChoice == choice ? Theme.highlight : Theme.textFaint)
                                Text(choice.label)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverRow()
                    }
                }
                .panel()
                if case .package(let package) = mcpChoice, !package.environmentVariables.isEmpty {
                    envRows(package.environmentVariables)
                }
                if let definition = try? mcpChoice.flatMap({ try service.definition(for: current, choice: $0) }) {
                    Text("Will run: \(definition.displayTarget)")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func envRows(_ vars: [CatalogEnvVar]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(vars) { env in
                HStack(alignment: .top, spacing: 8) {
                    TablerIcon(
                        name: env.isEffectivelySecret ? "lock" : "variable",
                        size: 11,
                        color: env.isEffectivelySecret ? Theme.warn : Theme.textFaint
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(env.name + (env.isRequired ? " *" : ""))
                            .font(Theme.mono(.small, .medium))
                            .foregroundStyle(Theme.text)
                        if let summary = env.summary {
                            Text(summary)
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    Spacer()
                    if let value = env.defaultValue, !env.isSecret {
                        Text(value)
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Text("Secret values are never written into config; they are provided per server after install and stored in the Keychain.")
                .font(Theme.ui(.micro))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .panel()
    }

    // MARK: Skill facts

    @ViewBuilder
    private var skillRows: some View {
        // A repository is not assumed to be one skill: every directory with a
        // SKILL.md is offered, one selected at a time — the same pattern the
        // MCP install-method picker uses.
        if let available = current.skill?.availableSkills, available.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skills in this repository (\(available.count))")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(available) { location in
                        let isSelected = current.skill?.directory == location.directory
                        Button {
                            Task { await selectSkill(location) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Theme.highlight : Theme.textFaint)
                                Text(location.label)
                                    .font(Theme.mono(.small))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverRow()
                        .disabled(isWorking)
                    }
                }
                .panel()
            }
        }
        skillFileRows
    }

    private func selectSkill(_ location: SkillCatalogDetails.SkillLocation) async {
        guard current.skill?.directory != location.directory else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            full = try await catalog.detail(for: item, location: location)
        } catch {
            detailError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var skillFileRows: some View {
        if let files = current.skill?.files {
            VStack(alignment: .leading, spacing: 8) {
                Text("Files (\(files.count))")
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files.prefix(12)) { file in
                        HStack {
                            Text(file.path)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                            Spacer()
                            Text("\(file.byteCount) B")
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    if files.count > 12 {
                        Text("… and \(files.count - 12) more")
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
                .panel()
                if let pin = current.skill?.pinRef {
                    Text("Pinned to \(CatalogStore.shortHash(pin)) — installs, updates and diffs all compare against exactly this.")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        } else if detailError == nil {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Fetching the file list…")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    // MARK: Agent picker

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install into")
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 0) {
                if registry.installations.isEmpty {
                    Text("No manageable agent was found on this machine.")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                        .padding(12)
                }
                ForEach(ExtensionAgentID.supported.filter { agent in
                    registry.installations.contains { $0.agent == agent }
                }) { agent in
                    let reason = service.incompatibilityReason(
                        agent: agent, item: current,
                        installations: registry.installations, choice: mcpChoice
                    )
                    Button {
                        if selectedAgents.contains(agent) {
                            selectedAgents.remove(agent)
                        } else {
                            selectedAgents.insert(agent)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedAgents.contains(agent)
                                ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12))
                                .foregroundStyle(selectedAgents.contains(agent) ? Theme.highlight : Theme.textFaint)
                            Text(agent.displayName)
                                .font(Theme.mono(.small, .medium))
                                .foregroundStyle(reason == nil ? Theme.text : Theme.textFaint)
                            Spacer()
                            if let reason {
                                Text(reason)
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.warn)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverRow()
                    .disabled(reason != nil)
                    .accessibilityIdentifier("extensions.catalog.agent.\(agent.rawValue)")
                }
            }
            .panel()
        }
    }

    // MARK: - Plan stages

    private func mcpPlanStage(_ plans: [CatalogInstallService.MCPAgentPlan]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exactly this will change — nothing has been written yet:")
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.textDim)
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(plan.agent.displayName)
                            .font(Theme.mono(.body, .semibold))
                            .foregroundStyle(Theme.text)
                        if let path = plan.transaction?.configPath {
                            Text(path)
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                    }
                    if let blocked = plan.blocked {
                        Text(blocked)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.warn)
                    } else if let diff = plan.transaction?.diff {
                        ScrollView(.horizontal) {
                            Text(diff.isEmpty ? String(localized: "No change.") : diff)
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textDim)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(10)
                        .panel()
                    }
                }
            }
        }
    }

    private func skillPreviewStage(
        _ plan: CatalogInstallService.SkillInstallPlan,
        bumblebee: String?
    ) -> some View {
        let preview = plan.preview
        return VStack(alignment: .leading, spacing: 14) {
            Text("Staged and inspected — nothing has touched an agent yet:")
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.textDim)

            VStack(alignment: .leading, spacing: 0) {
                row(String(localized: "Files"), "\(preview.changedFiles.count) will be written")
                row(String(localized: "Pinned version"), CatalogStore.shortHash(plan.pinnedHash))
                if let license = preview.license {
                    row(String(localized: "License"), license)
                }
                if !preview.requestedPermissions.isEmpty {
                    row(String(localized: "Asks for"), preview.requestedPermissions.joined(separator: ", "))
                }
                if let bumblebee {
                    row("Bumblebee", bumblebee)
                }
            }
            .panel()

            if !preview.findings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.findings.prefix(8)) { finding in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(finding.severity >= .high ? Theme.danger
                                    : finding.severity >= .needsReview ? Theme.warn : Theme.textFaint)
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(finding.severity.label) · \(finding.rule)")
                                    .font(Theme.mono(.small, .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(finding.message)
                                    .font(Theme.ui(.small))
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .panel()
            }

            if !plan.structureIssues.isEmpty {
                Text("Package layout: " + plan.structureIssues.joined(separator: "; "))
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.danger)
            }

            if !preview.executables.isEmpty {
                Toggle(isOn: $approveExecutables) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This skill contains executable files; I approve installing them.")
                            .font(Theme.ui(.small, .medium))
                            .foregroundStyle(Theme.text)
                        Text(preview.executables.prefix(4).joined(separator: ", "))
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("extensions.catalog.approveExecutables")
            }
        }
    }

    private func resultsStage(_ results: [CatalogInstallService.AgentResult]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Result")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results) { result in
                    HStack(spacing: 8) {
                        TablerIcon(
                            name: result.success ? "check" : "x",
                            size: 12,
                            color: result.success ? Theme.ok : Theme.danger
                        )
                        Text(result.agent.displayName)
                            .font(Theme.mono(.small, .medium))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text(result.message)
                            .font(Theme.ui(.small))
                            .foregroundStyle(result.success ? Theme.textDim : Theme.danger)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                if results.isEmpty {
                    Text("Nothing was selected.")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                        .padding(12)
                }
            }
            .panel()
        }
        .accessibilityIdentifier("extensions.catalog.results")
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private var canPrepare: Bool {
        guard !selectedAgents.isEmpty else { return false }
        switch item.kind {
        case .mcpServer: return mcpChoice != nil
        case .skill: return current.skill?.files?.isEmpty == false
        }
    }

    private func loadDetail(force: Bool = false) async {
        if force { catalog.invalidateDetails() }
        detailError = nil
        do {
            full = try await catalog.detail(for: item)
        } catch {
            detailError = error.localizedDescription
        }
        if mcpChoice == nil {
            mcpChoice = CatalogInstallService.choices(for: current).first
        }
        async let loadedFacts = catalog.repoFacts(for: current)
        async let loadedVersions = catalog.versions(for: current)
        facts = await loadedFacts
        versions = await loadedVersions
    }

    private func prepareInstall() async {
        isWorking = true
        defer { isWorking = false }
        switch item.kind {
        case .mcpServer:
            guard let choice = mcpChoice else { return }
            do {
                let definition = try service.definition(for: current, choice: choice)
                let plans = service.planMCPInstall(
                    definition: definition,
                    agents: Array(selectedAgents).sorted { $0.rawValue < $1.rawValue },
                    installations: registry.installations,
                    configurations: registry.configurations
                )
                stage = .mcpPlan(plans, definition)
            } catch {
                message = error.localizedDescription
            }
        case .skill:
            do {
                let plan = try service.stageSkill(item: current)
                // The pre-install scan runs on the staged copy, exactly like
                // any other install path.
                let outcome = await scans.scanBeforeInstall(path: plan.stagedPath.path)
                stage = .skillPreview(plan, bumblebee: outcome.message)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func applyMCP(
        plans: [CatalogInstallService.MCPAgentPlan],
        definition: MCPServerDefinition
    ) async {
        isWorking = true
        defer { isWorking = false }
        let results = service.applyMCPInstall(
            item: current, definition: definition, plans: plans, registry: registry
        )
        registry.discover()
        stage = .results(results)
        if results.contains(where: \.success) {
            message = String(localized: "\(definition.name) installed: \(results.filter(\.success).count) agents")
        }
    }

    private func applySkill(plan: CatalogInstallService.SkillInstallPlan) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let results = try service.installSkill(
                plan: plan,
                agents: Array(selectedAgents).sorted { $0.rawValue < $1.rawValue },
                installations: registry.installations,
                registry: registry,
                userApprovedExecutables: approveExecutables
            )
            registry.discover()
            catalog.invalidateDetails()
            stage = .results(results)
            if results.contains(where: \.success) {
                message = String(localized: "\(plan.item.installName) installed: \(results.filter(\.success).count) agents")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
