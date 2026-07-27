import SwiftUI

struct SessionGroupView: View {
    let group: SessionGroup
    let project: Project
    @Binding var selection: MainSelection?
    @Binding var selectedSessionIDs: Set<UUID>
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var prompt = ""
    @State private var showDelete = false

    private var records: [SessionRecord] {
        projectStore.sessions(in: group.id)
    }

    private var targetIDs: Set<UUID> {
        let withinGroup = selectedSessionIDs.intersection(Set(records.map(\.id)))
        return withinGroup.isEmpty ? Set(records.map(\.id)) : withinGroup
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    managementPanel
                    sessionsPanel
                }
                .padding(16)
                .uncoilScrollers()
            }
        }
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group.container")
        .confirmationDialog(
            "Delete \(targetIDs.count) sessions?",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Sessions", role: .destructive) { deleteTargets() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running processes are closed and the recordings cannot be recovered.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                selectedSessionIDs.removeAll()
                selection = .project(project.id)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 22, height: 22)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("group.backButton")

            TablerIcon(name: "folder", size: 18, color: Theme.highlight)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(records.count) sessions · \(project.name)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button("Delete Group") {
                projectStore.removeGroup(group.id)
                selectedSessionIDs.removeAll()
                selection = .project(project.id)
            }
            .buttonStyle(GhostButtonStyle())
            .accessibilityIdentifier("group.deleteGroup")
        }
        .padding(16)
        .background(Theme.panel.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var managementPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BULK MANAGEMENT")
                        .font(Theme.mono(.small, .semibold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(0.6)
                    Text(selectedSessionIDs.isEmpty
                         ? "Actions apply to every session in the group."
                         : "Actions apply to the \(targetIDs.count) selected sessions.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button(selectedSessionIDs.isEmpty ? "Select All" : "Clear Selection") {
                    if selectedSessionIDs.isEmpty {
                        selectedSessionIDs = Set(records.map(\.id))
                    } else {
                        selectedSessionIDs.removeAll()
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("group.selectAll")
            }

            TextEditor(text: $prompt)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .uncoilScrollers()
                .frame(minHeight: 64, maxHeight: 110)
                .padding(8)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .accessibilityIdentifier("group.prompt")

            HStack(spacing: 8) {
                Button("Send to All") { sendPrompt() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || targetIDs.isEmpty)
                    .accessibilityIdentifier("group.send")
                Button("Interrupt") { interruptTargets() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("group.interrupt")
                Button("Restart") { restartTargets() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("group.restart")
                Spacer()
                Button("Delete", role: .destructive) { showDelete = true }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("group.deleteSessions")
            }
        }
        .padding(14)
        .panel(radius: 12)
    }

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SESSIONS")
                    .font(Theme.mono(.small, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(0.6)
                Spacer()
                Text("\(records.count)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(12)

            if records.isEmpty {
                Text("No sessions in this group. Drag sessions here from the sidebar.")
                    .font(Theme.ui(.body))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        groupSessionRow(record)
                    }
                }
                .padding(6)
            }
        }
        .panel(radius: 12)
    }

    private func groupSessionRow(_ record: SessionRecord) -> some View {
        let selected = selectedSessionIDs.contains(record.id)
        return HStack(spacing: 10) {
            Button {
                if selected {
                    selectedSessionIDs.remove(record.id)
                } else {
                    selectedSessionIDs.insert(record.id)
                }
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.highlight : Theme.textFaint)
            }
            .buttonStyle(.plain)
            ProviderMark(provider: record.provider, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(sessionStore.detail(of: record.id)
                     ?? sessionStore.status(of: record.id).label)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            StatusOrb(status: sessionStore.status(of: record.id), size: 11)
            Button("Open") {
                selectedSessionIDs.removeAll()
                selection = .session(record.id)
            }
            .buttonStyle(GhostButtonStyle())
            Button {
                projectStore.assignSessions([record.id], to: nil)
                selectedSessionIDs.remove(record.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Remove from group")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            selected ? Theme.panelActive : Theme.panel.opacity(0.35),
            in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
        )
        .accessibilityIdentifier("group.session.\(record.title)")
    }

    private func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let targets = records.filter { targetIDs.contains($0.id) }
        prompt = ""
        for record in targets {
            Task { @MainActor in
                await TerminalRegistry.shared.submitText(
                    text,
                    for: record.id,
                    provider: record.provider
                )
            }
        }
    }

    private func interruptTargets() {
        for id in targetIDs {
            TerminalRegistry.shared.interrupt(id)
        }
    }

    private func restartTargets() {
        for id in targetIDs {
            TerminalRegistry.shared.closeTerminal(for: id)
            projectStore.updateSession(id) { $0.lastActivityAt = .now }
            sessionStore.bumpRestart(id)
        }
    }

    private func deleteTargets() {
        let ids = targetIDs
        for id in ids {
            TerminalRegistry.shared.closeTerminal(for: id)
        }
        projectStore.removeSessions(ids)
        selectedSessionIDs.subtract(ids)
    }
}
