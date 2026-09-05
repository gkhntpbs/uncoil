import SwiftUI

/// Everything a project is configured with: its identity — name, icon and
/// accent colour — and the MCP servers and skills its sessions are handed.
///
/// The two live behind one Save because they are one answer to "what is this
/// project", and splitting them would put the extension list somewhere the
/// project is not.
struct ProjectSettingsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case identity
        case extensions
        case notifications

        var id: String { rawValue }

        var title: String {
            switch self {
            case .identity: String(localized: "Identity")
            case .extensions: String(localized: "MCP & Skills")
            case .notifications: String(localized: "Notifications")
            }
        }

        /// One line under the title, so the sheet says what this tab decides
        /// rather than leaving the user to infer it from the controls.
        var subtitle: String {
            switch self {
            case .identity:
                String(localized: "How this project is named and recognised in the sidebar.")
            case .extensions:
                String(localized: "What a session in this project may load. Everything is on until you turn it off.")
            case .notifications:
                String(localized: "What this project is allowed to interrupt you for. Anything left alone follows the app's own settings.")
            }
        }
    }

    let project: Project
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = ExtensionRegistry.shared

    @State private var tab: Tab = .identity
    @State private var name: String = ""
    @State private var selectedIcon: String?
    @State private var selectedColor: UInt32?
    @State private var selection = ProjectExtensionSelection()

    private var agents: [ExtensionAgentID] {
        ProjectExtensionPicker.tabAgents(for: settings)
    }

    var body: some View {
        SheetScaffold(
            title: String(localized: "\(project.name) Settings"),
            subtitle: tab.subtitle,
            width: 560
        ) {
            VStack(spacing: Theme.Space.snug) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Theme.Space.section)
                .accessibilityIdentifier("project.settings.tab")

                ScrollView {
                    Group {
                        switch tab {
                        case .extensions:
                            ProjectExtensionPicker(
                                registry: registry, selection: $selection, agents: agents
                            )
                        case .notifications:
                            // The same rows the global Settings window used to
                            // carry a copy of, for every project at once. A
                            // project's override belongs beside the project.
                            Form {
                                Section {
                                    ProjectNotificationRows(project: project)
                                }
                            }
                            .formStyle(.grouped)
                            .scrollDisabled(true)
                            .scrollContentBackground(.hidden)
                        case .identity:
                            identityTab
                        }
                    }
                    .padding(.horizontal, Theme.Space.section)
                }
                .uncoilScrollers()
                .frame(height: 372)
                .task(id: tab) {
                    if tab == .extensions { registry.discover() }
                }
            }
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            Button(String(localized: "Save")) { save() }
                .buttonStyle(AccentButtonStyle())
        }
        .onAppear {
            name = project.name
            selectedIcon = project.iconName
            selectedColor = project.colorHex
            selection = ProjectExtensionSelection.load(
                from: registry.projectBindings, projectID: project.id
            )
        }
    }

    private var identityTab: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SheetField(label: String(localized: "Name")) {
                SheetTextField(
                    placeholder: String(localized: "Project name"), text: $name
                )
            }
            SheetField(
                label: String(localized: "Location"),
                hint: String(localized: "Where the sessions in this project run.")
            ) {
                Text(project.rootPath)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.snug)
                    .padding(.vertical, 9)
                    .background(
                        Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    )
            }
            IconColorPicker(iconName: $selectedIcon, colorHex: $selectedColor)
        }
    }

    private func save() {
        projectStore.updateProject(project.id) { stored in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { stored.name = trimmed }
            stored.iconName = selectedIcon
            stored.colorHex = selectedColor
        }
        ProjectExtensionPicker.save(
            selection, projectID: project.id, agents: agents, to: registry
        )
        dismiss()
    }
}

/// Shared project icon: custom Tabler icon + color, or the default folder.
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 12

    var body: some View {
        if let iconName = project.iconName {
            TablerIcon(name: iconName, size: size + 2, color: project.accentColor)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: size - 1))
                .foregroundStyle(project.colorHex != nil ? project.accentColor : Theme.textDim)
        }
    }
}
