import SwiftUI

/// Asked once, right after a folder becomes a project: which MCP servers and
/// skills should its sessions get?
///
/// The project already exists by the time this appears — choosing the folder
/// was the act of creating it — so dismissing the sheet is not a cancel. It is
/// "keep everything", which is exactly what the project would have done before
/// this sheet existed, and the whole selection stays editable afterwards from
/// the project's own customize sheet.
struct NewProjectSheet: View {
    let project: Project
    @ObservedObject var registry: ExtensionRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var excluded: Set<String> = []

    private var installedProviders: [AgentProvider] {
        registry.installedAgents.compactMap(\.provider)
    }

    private var keptCount: Int {
        registry.packages.filter {
            $0.name != ControlPlaneMCPName && !excluded.contains($0.id)
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProjectIcon(project: project, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(Theme.mono(.large, .medium))
                        .foregroundStyle(Theme.text)
                    Text(project.rootPath)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(12)
            .background(Theme.panel)

            Divider().overlay(Theme.border)

            ScrollView {
                ProjectExtensionPicker(
                    registry: registry,
                    excluded: $excluded,
                    providers: installedProviders
                )
                .padding(14)
            }
            .uncoilScrollers()
            .frame(maxHeight: 420)

            Divider().overlay(Theme.border)

            HStack(spacing: 8) {
                Button("Keep All") {
                    excluded = []
                    save()
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("newProject.keepAll")

                Button("None") {
                    excluded = Set(
                        registry.packages
                            .filter { $0.name != ControlPlaneMCPName }
                            .map(\.id)
                    )
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("newProject.none")

                Spacer()

                Text("\(keptCount) kept")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)

                Button("Done") { save() }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("newProject.done")
            }
            .padding(12)
        }
        .frame(width: 460)
        .background(Theme.bg)
        .task { registry.discover() }
    }

    private func save() {
        registry.setProjectBindings(
            ProjectExtensionPicker.bindings(excluding: excluded, projectID: project.id),
            forProject: project.id
        )
        dismiss()
    }
}
