import SwiftUI

/// Asked once, right after a folder becomes a project: how should it start, and
/// what should its agents be given?
///
/// One question is up front and the other is behind a button, because they are
/// not equally weighted. "Which setup is this?" is asked every time; "which of
/// my MCP servers does it need?" is asked by people who have felt the cost of
/// getting it wrong, and it has a sensible default until then.
struct NewProjectSheet: View {
    let project: Project
    @ObservedObject var registry: ExtensionRegistry
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var blueprints = BlueprintStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Which page is showing. The other two replace the content rather than
    /// opening on top of it: a sheet over a sheet is two dismiss buttons and
    /// one confused Escape key.
    private enum Page { case setup, identity, extensions }

    @State private var page: Page = .setup
    @State private var name = ""
    @State private var iconName: String?
    @State private var colorHex: UInt32?
    @State private var blueprintID: String?
    @State private var selection = ProjectExtensionSelection()
    @State private var writingBlueprint: Blueprint?

    private var agents: [ExtensionAgentID] {
        ProjectExtensionPicker.tabAgents(for: settings)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayName: String {
        trimmedName.isEmpty ? project.name : trimmedName
    }

    private var excludedCount: Int {
        selection.axes(among: agents)
            .reduce(0) { $0 + selection.opinionCount(for: $1) }
    }

    var body: some View {
        Group {
            switch page {
            case .setup: setupPage
            case .identity: identityPage
            case .extensions: extensionsPage
            }
        }
        .background(Theme.bg)
        .onAppear {
            name = project.name
            iconName = project.iconName
            colorHex = project.colorHex
        }
        .task {
            registry.discover()
            blueprints.reload()
        }
        .sheet(item: $writingBlueprint) { blueprint in
            BlueprintEditorSheet(blueprint: blueprint, store: blueprints)
        }
    }

    // MARK: - Pages

    private var setupPage: some View {
        SheetScaffold(
            title: String(localized: "Add \(displayName)"),
            subtitle: String(localized: "How should this project start?")
        ) {
            ScrollView {
                VStack(spacing: Theme.Space.snug) {
                    identityRow

                    BlueprintChooser(store: blueprints, selected: $blueprintID) {
                        writingBlueprint = Blueprint(id: "", name: "", prompt: "")
                    }

                    if let blueprintID,
                       let blueprint = blueprints.blueprint(id: blueprintID) {
                        note(blueprint.startsImmediately
                            ? String(localized: "Opens a \(settings.defaultProvider.displayName) session and sends this straight away.")
                            : String(localized: "Opens a \(settings.defaultProvider.displayName) session and types this in for you to read and send."))
                    }

                    extensionsRow
                }
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(maxHeight: 340)
        } actions: {
            Button(String(localized: "Cancel")) { cancel() }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("newProject.cancel")
            Spacer()
            Button(String(localized: "Create")) { create() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("newProject.done")
        }
    }

    private var identityPage: some View {
        SheetScaffold(
            title: String(localized: "Name and Mark"),
            subtitle: String(localized: "What this project is called in the sidebar, and how it is recognised there."),
            onBack: { page = .setup }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                SheetField(label: String(localized: "Name")) {
                    SheetTextField(
                        placeholder: String(localized: "Project name"), text: $name
                    )
                }
                IconColorPicker(iconName: $iconName, colorHex: $colorHex)
            }
            .padding(.horizontal, Theme.Space.section)
        } actions: {
            Spacer()
            Button(String(localized: "Done")) { page = .setup }
                .buttonStyle(AccentButtonStyle())
        }
    }

    private var extensionsPage: some View {
        SheetScaffold(
            title: String(localized: "MCP Servers & Skills"),
            subtitle: String(localized: "What a session in this project may load. Everything is on until you turn it off."),
            onBack: { page = .setup },
            width: 560
        ) {
            ScrollView {
                ProjectExtensionPicker(
                    registry: registry, selection: $selection, agents: agents
                )
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(height: 380)
        } actions: {
            Spacer()
            Button(String(localized: "Done")) { page = .setup }
                .buttonStyle(AccentButtonStyle())
        }
    }

    // MARK: - Rows

    /// The project's identity as a row that opens the editor, rather than a
    /// pencil beside a title. The path belongs on screen — it is the one thing
    /// that says *which* folder this is — and it needs a line of its own.
    private var identityRow: some View {
        Button {
            page = .identity
        } label: {
            HStack(spacing: Theme.Space.snug) {
                BlueprintMark(
                    iconName: iconName, colorHex: colorHex, fallback: "folder.fill"
                )
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Theme.ui(.body, .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(project.rootPath)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Theme.Space.tight)
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newProject.editIdentity")
    }

    private var extensionsRow: some View {
        Button {
            page = .extensions
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP servers & skills")
                        .font(Theme.ui(.body, .medium))
                        .foregroundStyle(Theme.text)
                    Text(excludedCount == 0
                        ? String(localized: "Everything this project's agents already have")
                        : String(localized: "\(excludedCount) turned off for this project"))
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: Theme.Space.tight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newProject.manageExtensions")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.small))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    /// The folder was added the moment it was chosen, so a button that says
    /// "Create" has to be able to un-create — otherwise Cancel would leave
    /// behind exactly the thing it claimed not to make. Only when nothing has
    /// happened in it yet, which is the same rule the onboarding step uses when
    /// someone picks a different folder.
    private func cancel() {
        if projectStore.sessions(for: project.id).isEmpty {
            projectStore.removeProject(project)
        }
        dismiss()
    }

    private func create() {
        projectStore.updateProject(project.id) { stored in
            if !trimmedName.isEmpty { stored.name = trimmedName }
            stored.iconName = iconName
            stored.colorHex = colorHex
        }
        ProjectExtensionPicker.save(
            selection, projectID: project.id, agents: agents, to: registry
        )
        // Read back rather than reused: the blueprint's prompt interpolates the
        // project's name, and it was editable on this very sheet.
        if let blueprintID,
           let blueprint = blueprints.blueprint(id: blueprintID),
           let stored = projectStore.projects.first(where: { $0.id == project.id }) {
            BlueprintRunner.apply(
                blueprint, to: stored, settings: settings,
                sessionStore: sessionStore, projectStore: projectStore
            )
        }
        dismiss()
    }
}
