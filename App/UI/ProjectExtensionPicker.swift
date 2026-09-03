import SwiftUI

/// Which MCP servers and skills a project hands to its sessions.
///
/// One view, two homes: the sheet that opens when a project is created and the
/// "MCP & Skills" tab of the customize sheet. Both ask the same question and
/// write the same records, so asking it twice in two shapes would be two places
/// to get it wrong.
///
/// The selection is held as the set of **excluded** package ids rather than the
/// included ones. That is what the store keeps, and it is what makes the
/// default honest: an empty set means "everything", including whatever is
/// installed next week, instead of freezing today's list into every project.
struct ProjectExtensionPicker: View {
    @ObservedObject var registry: ExtensionRegistry
    /// Package ids this project refuses.
    @Binding var excluded: Set<String>
    /// Providers with a session in this project, or all installed ones when
    /// there are none yet — used only to say what can actually be enforced.
    var providers: [AgentProvider]

    private var mcpServers: [ExtensionPackage] {
        registry.packages.filter { $0.kind == .mcpServer && $0.name != ControlPlaneMCPName }
    }

    private var skills: [ExtensionPackage] {
        registry.packages.filter { $0.kind == .skill }
    }

    /// Providers that will load skills regardless of what is chosen here. Named
    /// rather than counted: "not scoped for Claude Code" is actionable, "not
    /// scoped for 1 agent" is not.
    private var skillBlindProviders: [AgentProvider] {
        providers.filter { $0.extensionScoping == .mcpOnly && $0 != .opencode }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(
                title: String(localized: "MCP Servers"),
                detail: String(localized: "Servers a session in this project may load."),
                packages: mcpServers,
                emptyText: String(localized: "No MCP server is configured for any agent yet.")
            )

            section(
                title: String(localized: "Skills"),
                detail: String(localized: "Skills a session in this project may load."),
                packages: skills,
                emptyText: String(localized: "No skill is installed for any agent yet.")
            )

            if !skillBlindProviders.isEmpty, !skills.isEmpty {
                let names = ListFormatter.localizedString(
                    byJoining: skillBlindProviders.map(\.displayName)
                )
                Label(
                    String(localized: "Skills are not scoped for \(names) — the CLI has no per-session skill selection, so it loads all of them. MCP servers are scoped."),
                    systemImage: "info.circle"
                )
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Takes effect on the next session. A session already running keeps what it started with.")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(
        title: String,
        detail: String,
        packages: [ExtensionPackage],
        emptyText: String
    ) -> some View {
        SectionCard(title: title, detail: detail) {
            if packages.isEmpty {
                EmptyRow(text: emptyText)
            } else {
                ForEach(packages) { package in
                    row(for: package)
                    if package.id != packages.last?.id {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
    }

    private func row(for package: ExtensionPackage) -> some View {
        let isOn = !excluded.contains(package.id)
        return Button {
            if isOn {
                excluded.insert(package.id)
            } else {
                excluded.remove(package.id)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Theme.highlight : Theme.textFaint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(package.name)
                        .font(Theme.mono(.body))
                        .foregroundStyle(isOn ? Theme.text : Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = package.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("project.extensions.\(package.id)")
    }
}

extension ProjectExtensionPicker {
    /// The package ids a project currently refuses, read out of its records.
    ///
    /// Only the agent-agnostic records are read, because those are the only
    /// ones this picker writes; a per-agent rule set from the assignment matrix
    /// stays out of view rather than being flattened into a checkbox that
    /// cannot express it.
    static func excludedIDs(
        in bindings: [ProjectBinding],
        projectID: UUID
    ) -> Set<String> {
        Set(
            bindings
                .filter { $0.projectID == projectID && $0.agent == nil && !$0.isEnabled }
                .map(\.extensionID)
        )
    }

    /// The records to store for a selection. Only exclusions are written: an
    /// allowed extension is the absence of a record, which is what keeps a
    /// newly installed one reaching every project that never refused it.
    static func bindings(
        excluding excluded: Set<String>,
        projectID: UUID
    ) -> [ProjectBinding] {
        excluded.sorted().map {
            ProjectBinding(extensionID: $0, projectID: projectID, isEnabled: false)
        }
    }
}
