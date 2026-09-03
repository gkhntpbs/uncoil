import SwiftUI
import UniformTypeIdentifiers

/// Settings → Agents → Blueprints: the saved prompts a project can be set up
/// from, and the three ways to write one.
struct BlueprintsSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var store = BlueprintStore.shared

    @State private var editing: Blueprint?
    @State private var message: String?
    @State private var isImporting = false
    @State private var exporting: Blueprint?

    var body: some View {
        SettingsPage(
            title: String(localized: "Blueprints"),
            subtitle: String(localized: "A blueprint is the prompt you always write when you start a project of a certain shape. Pick one when you add a project and Uncoil hands it to an agent — it creates nothing itself, so what gets built is the agent's work, done the way you asked.")
        ) {
            Section("Blueprints") {
                if store.blueprints.isEmpty {
                    SettingsNote(String(localized: "None yet. Write one below, or let an agent write it with you."))
                } else {
                    ForEach(store.blueprints) { blueprint in
                        row(blueprint)
                    }
                }
            }

            Section("Add") {
                SettingsActionRow(note: message) {
                    Button(String(localized: "New Blueprint…")) {
                        editing = Blueprint(id: "", name: "", prompt: "")
                    }
                    .accessibilityIdentifier("blueprints.new")

                    Button(String(localized: "Write One With an Agent…")) { writeWithAgent() }
                        .accessibilityIdentifier("blueprints.withAgent")

                    Button(String(localized: "Import…")) { isImporting = true }
                }
                SettingsNote(String(localized: "Blueprints are markdown files in ~/.uncoil/blueprints. Sending one to someone else is sending them the file."))
            }
        }
        .sheet(item: $editing) { blueprint in
            BlueprintEditorSheet(blueprint: blueprint, store: store)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try store.importBlueprint(from: url)
                message = String(localized: "Imported “\(imported.name)”. Open it to check what it says before you use it.")
            } catch {
                message = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exporting != nil },
                set: { if !$0 { exporting = nil } }
            ),
            document: exporting.map { BlueprintDocument(text: $0.markdown()) },
            contentType: UTType(filenameExtension: "md") ?? .plainText,
            defaultFilename: exporting?.id
        ) { _ in exporting = nil }
    }

    private func row(_ blueprint: Blueprint) -> some View {
        AdaptiveRow {
            HStack(spacing: 8) {
                if let icon = blueprint.iconName {
                    TablerIcon(
                        name: icon, size: 15,
                        color: blueprint.colorHex.map { Color(hex: $0) } ?? Theme.textDim
                    )
                } else {
                    Image(systemName: "square.dashed")
                        .foregroundStyle(Theme.textDim)
                }
                SettingsLabel(
                    title: blueprint.name,
                    detail: blueprint.needsReview
                        ? String(localized: "Draft — written outside this editor. Open it to check what it says; it will not start on its own until you do.")
                        : (blueprint.startsImmediately
                            ? String(localized: "Sends its prompt as soon as the session opens.")
                            : String(localized: "Types its prompt in and waits for you to send it."))
                )
            }
        } control: {
            HStack(spacing: 8) {
                if blueprint.needsReview {
                    Text("draft")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.warn)
                }
                Button(String(localized: "Edit")) { editing = blueprint }
                    .accessibilityIdentifier("blueprints.edit.\(blueprint.id)")
                Menu {
                    Button(String(localized: "Duplicate")) { duplicate(blueprint) }
                    Button(String(localized: "Export…")) { exporting = blueprint }
                    Divider()
                    Button(String(localized: "Delete"), role: .destructive) {
                        try? store.delete(id: blueprint.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
    }

    private func duplicate(_ blueprint: Blueprint) {
        let name = String(localized: "\(blueprint.name) copy")
        try? store.save(Blueprint(
            id: store.availableID(for: name),
            name: name,
            iconName: blueprint.iconName,
            colorHex: blueprint.colorHex,
            prompt: blueprint.prompt,
            startsImmediately: blueprint.startsImmediately
        ))
    }

    /// Opens a session whose one job is to write a blueprint with the user.
    ///
    /// It runs in the scratch workspace, because a blueprint belongs to no
    /// project, and it is the only session that gets `blueprints.write` — the
    /// grant is opt-in precisely so that it belongs to the session the user
    /// opened for this and to nothing else.
    private func writeWithAgent() {
        let provider = settings.defaultProvider
        let record = projectStore.createScratchSession(
            provider: provider,
            accountID: settings.defaultAccount(for: provider)?.id
        )
        projectStore.updateSession(record.id) {
            $0.capabilities = Array(PolicyEngine.defaultGrants) + ["blueprints.write"]
            $0.title = String(localized: "\(provider.rawValue): write a blueprint")
        }
        guard let launched = projectStore.sessions.first(where: { $0.id == record.id }),
              let project = projectStore.projects.first(where: { $0.id == record.projectID })
        else { return }

        MainRoute.shared.request(.session(launched.id))
        SessionPromptDelivery.deliver(
            Self.authoringPrompt(language: settings.language.resolvedAgent()),
            to: launched, project: project,
            settings: settings, sessionStore: sessionStore, projectStore: projectStore,
            // Typed in, not sent. This one is worth reading before it runs —
            // it is the brief for a conversation about how you work, and the
            // first thing anyone will want to do is adjust it.
            autoStart: false
        )
        message = String(localized: "Opened a session in the main window with the brief typed in. Adjust it, send it, and it will save the blueprint back here.")
    }

    /// What the authoring session is told to do.
    ///
    /// It interviews rather than guesses: the whole value of a blueprint is
    /// that it encodes how *this* person works, and an agent that invents a
    /// folder layout has produced something its author will not recognise.
    static func authoringPrompt(language: PromptLanguage = .english) -> String {
        var prompt = """
        Help me write an Uncoil blueprint, then save it.

        A blueprint is a stored prompt that gets handed to an agent when I start \
        a new project — it is how I set the same kind of project up every time. \
        Uncoil creates no files itself; whatever the blueprint says is what an \
        agent will do in an empty project folder.

        First interview me. Ask about the folder layout I use, which files belong \
        at the root (CLAUDE.md, AGENTS.md, README, changelog…), what goes in them, \
        the stack, and anything I always do first. Ask one thing at a time and \
        keep it short. Do not guess a layout for me.

        Then write the prompt as instructions addressed to an agent that will do \
        the work, not as a description of a project. Use {{project_name}} and \
        {{project_path}} where the project's own name and path belong. Show it to \
        me before saving.

        Save it with uncoil_projects {"action":"save_blueprint", "name":"…", \
        "prompt":"…"}. Read {"action":"help"} first if you need the exact shape. \
        It will be stored as a draft for me to review, which is expected.
        """
        if let directive = language.directive {
            prompt += "\n\(directive)"
        }
        return prompt
    }
}

/// The file `fileExporter` writes. Blueprints are plain markdown, so this
/// carries text and nothing else.
private struct BlueprintDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Name, look, prompt and whether it starts by itself.
struct BlueprintEditorSheet: View {
    let blueprint: Blueprint
    @ObservedObject var store: BlueprintStore
    @Environment(\.dismiss) private var dismiss

    private enum Page { case prompt, mark }

    @State private var page: Page = .prompt
    @State private var name = ""
    @State private var iconName: String?
    @State private var colorHex: UInt32?
    @State private var prompt = ""
    @State private var startsImmediately = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    private var isNew: Bool { blueprint.id.isEmpty }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(
            title: page == .mark
                ? String(localized: "Mark")
                : (isNew
                    ? String(localized: "New Blueprint")
                    : String(localized: "Edit \(blueprint.name)")),
            subtitle: page == .mark
                ? String(localized: "How this blueprint is recognised in the list.")
                : String(localized: "The instructions an agent gets when a project starts from this."),
            onBack: page == .mark ? { page = .prompt } : nil,
            width: 560
        ) {
            ScrollView {
                Group {
                    if page == .mark {
                        IconColorPicker(iconName: $iconName, colorHex: $colorHex)
                    } else {
                        promptPage
                    }
                }
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(height: 380)
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            if page == .prompt {
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("blueprints.save")
            } else {
                Button(String(localized: "Done")) { page = .prompt }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .onAppear {
            name = blueprint.name
            iconName = blueprint.iconName
            colorHex = blueprint.colorHex
            prompt = blueprint.prompt
            startsImmediately = blueprint.startsImmediately
        }
    }

    private var promptPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.snug) {
                SheetField(label: String(localized: "Name")) {
                    SheetTextField(
                        placeholder: String(localized: "Full-stack workspace"),
                        text: $name
                    )
                }
                Button {
                    page = .mark
                } label: {
                    VStack(spacing: 3) {
                        BlueprintMark(
                            iconName: iconName, colorHex: colorHex, size: 17
                        )
                        Text("Mark")
                            .font(Theme.ui(.micro))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .frame(width: 52, height: 46)
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
                .padding(.top, 15)
                .accessibilityIdentifier("blueprints.mark")
            }

            SheetField(
                label: String(localized: "Prompt"),
                hint: String(localized: "\(Blueprint.projectNamePlaceholder) and \(Blueprint.projectPathPlaceholder) are filled in when it runs. Write it as instructions to an agent — Uncoil creates no files itself.")
            ) {
                TextEditor(text: $prompt)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .focused($promptFocused)
                    .frame(height: 168)
                    .padding(Theme.Space.tight)
                    .background(
                        Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .strokeBorder(
                                promptFocused ? Theme.highlight.opacity(0.5) : Theme.border,
                                lineWidth: 1
                            )
                    )
            }

            Toggle(isOn: $startsImmediately) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send as soon as the session opens")
                        .font(Theme.ui(.body))
                        .foregroundStyle(Theme.text)
                    Text("Off means the prompt is typed in and left for you to read and send.")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("blueprints.startsImmediately")

            if let error {
                Text(error)
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private func save() {
        do {
            try store.save(Blueprint(
                id: isNew ? store.availableID(for: trimmedName) : blueprint.id,
                name: trimmedName,
                iconName: iconName,
                colorHex: colorHex,
                prompt: prompt,
                startsImmediately: startsImmediately
                // needsReview is not carried over: saving from this editor IS
                // the review, so a draft stops being one the moment it is kept.
            ))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
