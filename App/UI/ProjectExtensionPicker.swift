import SwiftUI

/// A project's answer on every axis at once: what it refuses for all agents,
/// and where one agent is treated differently.
///
/// Each axis holds only the extensions it has an *opinion* about. Silence is
/// the default and it inherits: an agent with nothing to say about `figma`
/// follows the all-agents rule, and an extension nobody mentions is allowed.
/// That is what keeps a project honest as the world changes around it — a
/// server installed next week reaches every project that never refused it,
/// rather than being missing from a frozen allow-list.
///
/// Both verdicts are recordable per agent, not just refusals. "Off everywhere,
/// but on for Codex" is a thing people want to say, and `ProjectBinding`
/// already carries `isEnabled` for exactly that; storing only exclusions would
/// have made the agent tabs able to subtract and never to restore.
///
/// The axis is keyed by raw value rather than by `ExtensionAgentID?` so the
/// all-agents row is a real key instead of an optional one — dictionaries with
/// optional keys read badly at every use site.
struct ProjectExtensionSelection: Equatable {
    static let allAgentsKey = ""

    /// axis → extension id → allowed.
    private var byAxis: [String: [String: Bool]] = [:]

    static func key(for agent: ExtensionAgentID?) -> String {
        agent?.rawValue ?? allAgentsKey
    }

    /// What the all-agents rule says, ignoring every exception.
    private func allAgentsVerdict(_ id: String) -> Bool {
        byAxis[Self.allAgentsKey]?[id] ?? true
    }

    /// Whether this extension is allowed as seen from one tab — the agent's own
    /// record if it has one, otherwise the all-agents rule.
    func isAllowed(_ id: String, for agent: ExtensionAgentID?) -> Bool {
        guard let agent else { return allAgentsVerdict(id) }
        return byAxis[agent.rawValue]?[id] ?? allAgentsVerdict(id)
    }

    /// How many exceptions an agent tab holds, for the badge on the tab.
    func opinionCount(for agent: ExtensionAgentID?) -> Int {
        byAxis[Self.key(for: agent)]?.count ?? 0
    }

    mutating func toggle(_ id: String, for agent: ExtensionAgentID?) {
        let wanted = !isAllowed(id, for: agent)
        let key = Self.key(for: agent)
        var axis = byAxis[key] ?? [:]
        // A record is only worth keeping when it says something the layer
        // beneath it does not. Dropping the redundant one is what lets an agent
        // start inheriting again after the all-agents rule catches up with it.
        let inherited = agent == nil ? true : allAgentsVerdict(id)
        if wanted == inherited {
            axis.removeValue(forKey: id)
        } else {
            axis[id] = wanted
        }
        byAxis[key] = axis
    }

    /// Agents that answer differently from the all-agents rule for one
    /// extension, so the All tab can name its own exceptions rather than hiding
    /// them behind a tab nobody thought to open.
    func disagreements(with id: String, among agents: [ExtensionAgentID]) -> [ExtensionAgentID] {
        let all = allAgentsVerdict(id)
        return agents.filter { agent in
            guard let own = byAxis[agent.rawValue]?[id] else { return false }
            return own != all
        }
    }

    /// Reads a project's stored records back into a selection.
    static func load(from bindings: [ProjectBinding], projectID: UUID) -> Self {
        var selection = Self()
        for binding in bindings where binding.projectID == projectID {
            var axis = selection.byAxis[key(for: binding.agent)] ?? [:]
            axis[binding.extensionID] = binding.isEnabled
            selection.byAxis[key(for: binding.agent)] = axis
        }
        return selection
    }

    /// Every axis that has to be written back, emptied ones included — an axis
    /// whose last exception was removed still needs a write, or the old records
    /// would survive the save.
    func axes(among agents: [ExtensionAgentID]) -> [ExtensionAgentID?] {
        [nil] + agents
    }

    /// The records to store for one axis.
    func bindings(for agent: ExtensionAgentID?, projectID: UUID) -> [ProjectBinding] {
        (byAxis[Self.key(for: agent)] ?? [:])
            .sorted { $0.key < $1.key }
            .map { id, isEnabled in
                ProjectBinding(
                    extensionID: id, projectID: projectID,
                    agent: agent, isEnabled: isEnabled
                )
            }
    }
}

/// Which MCP servers and skills a project hands to its sessions, per agent.
///
/// One view, three homes: the sheet that opens when a project is created, the
/// "MCP & Skills" tab of the customize sheet, and nothing else — because all
/// three ask the same question and write the same records.
struct ProjectExtensionPicker: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var selection: ProjectExtensionSelection
    /// Agents offered as tabs. Comes from Quick Launch, so the choice is made
    /// among the agents this user actually starts sessions with.
    var agents: [ExtensionAgentID]

    /// nil = the "All agents" tab.
    @State private var tab: ExtensionAgentID?

    private var mcpServers: [ExtensionPackage] {
        registry.packages.filter { $0.kind == .mcpServer && $0.name != ControlPlaneMCPName }
    }

    private var skills: [ExtensionPackage] {
        registry.packages.filter { $0.kind == .skill }
    }

    /// The agents that will load skills whatever is chosen here. Named rather
    /// than counted: "not scoped for Claude Code" is actionable, "not scoped
    /// for 1 agent" is not.
    private var skillBlindAgents: [ExtensionAgentID] {
        let scope = tab.map { [$0] } ?? agents
        return scope.filter { $0.provider?.extensionScoping == .mcpOnly && $0 != .opencode }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            if !agents.isEmpty { tabBar }

            section(
                title: String(localized: "MCP Servers"),
                packages: mcpServers,
                emptyText: String(localized: "No MCP server is configured for any agent yet.")
            )

            section(
                title: String(localized: "Skills"),
                packages: skills,
                emptyText: String(localized: "No skill is installed for any agent yet.")
            )

            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                if !skillBlindAgents.isEmpty, !skills.isEmpty {
                    let names = ListFormatter.localizedString(
                        byJoining: skillBlindAgents.map(\.displayName)
                    )
                    note(String(localized: "Skills are not scoped for \(names) — the CLI has no per-session skill selection, so it loads all of them. MCP servers are scoped."))
                }
                note(String(localized: "Takes effect on the next session. One already running keeps what it started with."))
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.hair) {
                tabButton(nil, title: String(localized: "All agents"))
                ForEach(agents) { agent in
                    tabButton(agent, title: agent.displayName)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
    }

    private func tabButton(_ agent: ExtensionAgentID?, title: String) -> some View {
        let isOn = tab == agent
        let count = selection.opinionCount(for: agent)
        return Button {
            tab = agent
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(Theme.ui(.small, isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Theme.text : Theme.textDim)
                // The count is what makes an exception discoverable: a tab
                // nobody opens still says it has something to say.
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.ui(.micro, .medium))
                        .foregroundStyle(isOn ? Theme.text : Theme.textFaint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.panelActive, in: Capsule())
                }
            }
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 6)
            .background(
                isOn ? Theme.panelActive : Theme.panel,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Theme.border : .clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.extensions.tab.\(agent?.rawValue ?? "all")")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.small))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(
        title: String,
        packages: [ExtensionPackage],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.tight) {
                Text(title)
                    .font(Theme.ui(.small, .semibold))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                if !packages.isEmpty {
                    let on = packages.filter { selection.isAllowed($0.id, for: tab) }.count
                    Text("\(on)/\(packages.count)")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }

            if packages.isEmpty {
                Text(emptyText)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.tight)
            } else {
                VStack(spacing: 0) {
                    ForEach(packages) { package in
                        row(for: package)
                        if package.id != packages.last?.id {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
        }
    }

    private func row(for package: ExtensionPackage) -> some View {
        let isOn = selection.isAllowed(package.id, for: tab)
        // Only on the All tab, and only for rows an agent disagrees about.
        let exceptions = tab == nil
            ? selection.disagreements(with: package.id, among: agents)
            : []
        return Button {
            selection.toggle(package.id, for: tab)
        } label: {
            HStack(spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(package.name)
                        .font(Theme.ui(.body))
                        .foregroundStyle(isOn ? Theme.text : Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !exceptions.isEmpty {
                        let names = ListFormatter.localizedString(
                            byJoining: exceptions.map(\.displayName)
                        )
                        Text(isOn ? "off for \(names)" : "on for \(names)")
                            .font(Theme.ui(.small))
                            .foregroundStyle(Theme.warn)
                            .lineLimit(1)
                    } else if let summary = package.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: Theme.Space.tight)
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { _ in selection.toggle(package.id, for: tab) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.extensions.\(package.id)")
    }
}

extension ProjectExtensionPicker {
    /// The agents to offer as tabs: what the user chose for Quick Launch, minus
    /// the terminal. A plain shell has no configuration to scope, and the
    /// agents someone actually launches are the ones worth asking about.
    @MainActor
    static func tabAgents(for settings: SettingsStore) -> [ExtensionAgentID] {
        settings.launcherProviders
            .filter { $0 != .terminal }
            .compactMap(\.extensionAgent)
    }

    /// Writes a whole selection back, one axis at a time.
    @MainActor
    static func save(
        _ selection: ProjectExtensionSelection,
        projectID: UUID,
        agents: [ExtensionAgentID],
        to registry: ExtensionRegistry
    ) {
        for agent in selection.axes(among: agents) {
            registry.setProjectBindings(
                selection.bindings(for: agent, projectID: projectID),
                forProject: projectID,
                agent: agent
            )
        }
    }
}
