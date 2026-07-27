import SwiftUI

/// Writing a new skill from inside Uncoil.
///
/// The description is treated as the important field: it is what an agent reads
/// when deciding whether to use the skill at all, so it is required and the
/// preview shows exactly the SKILL.md that will be written.
struct SkillCreateSheet: View {
    @ObservedObject var registry: ExtensionRegistry
    /// Called with the message to show, or nil when the user cancelled.
    var onFinish: (String?) -> Void

    @State private var draft = SkillAuthoringService.Draft()
    @State private var assigned: Set<ExtensionAgentID> = []
    @State private var error: String?

    private var slug: String { SkillAuthoringService.slug(draft.name) }

    private var canCreate: Bool {
        !slug.isEmpty && !draft.summary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New skill")
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text("Created in Uncoil's own store; attached to the agents you pick.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
            }

            VStack(alignment: .leading, spacing: 8) {
                field(String(localized: "Name")) {
                    TextField("e.g. release-checklist", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(.body))
                        .accessibilityIdentifier("extensions.skills.create.name")
                }
                if !draft.name.isEmpty {
                    Text("Folder name: \(slug.isEmpty ? "invalid" : slug)")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(slug.isEmpty ? Theme.danger : Theme.textFaint)
                }

                field(String(localized: "Description")) {
                    TextField("When should the agent use this?", text: $draft.summary)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(.body))
                        .accessibilityIdentifier("extensions.skills.create.summary")
                }

                field(String(localized: "Contents")) {
                    TextEditor(text: $draft.body)
                        .font(Theme.mono(.body))
                        .frame(height: 150)
                        .scrollContentBackground(.hidden)
                        .uncoilScrollers()
                        .padding(6)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                        .accessibilityIdentifier("extensions.skills.create.body")
                }

                if registry.installedAgents.isEmpty {
                    Text("No installed agent found; the skill is created but attached to nobody.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.warn)
                } else {
                    field(String(localized: "Assign")) {
                        HStack(spacing: 10) {
                            ForEach(registry.installedAgents) { agent in
                                Toggle(agent.displayName, isOn: Binding(
                                    get: { assigned.contains(agent) },
                                    set: { isOn in
                                        if isOn { assigned.insert(agent) } else { assigned.remove(agent) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if let error {
                Text(error)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Create") { create() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canCreate)
                    .accessibilityIdentifier("extensions.skills.create.confirm")
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(Theme.bg)
        .accessibilityIdentifier("extensions.skills.createSheet")
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.mono(.small, .semibold))
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private func create() {
        let service = SkillAuthoringService(layout: registry.layout)
        do {
            let package = try service.create(draft)
            registry.upsert(package)
            registry.record(AuditEvent(
                kind: .skillInstalled, extensionID: package.id,
                detail: String(localized: "Created inside Uncoil")
            ))
            var linked: [String] = []
            for installation in registry.installations
            where assigned.contains(installation.agent) {
                registry.setAgentBinding(true, packageID: package.id, agent: installation.agent)
                if service.link(name: package.name, into: installation) {
                    linked.append(installation.agent.displayName)
                }
            }
            onFinish(
                linked.isEmpty
                    ? "\(package.name) created."
                    : "\(package.name) created and linked: \(linked.joined(separator: ", "))."
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
