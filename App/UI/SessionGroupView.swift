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
            "\(targetIDs.count) oturum silinsin mi?",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button("Oturumları Sil", role: .destructive) { deleteTargets() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Çalışan süreçler kapatılır ve kayıtlar geri alınamaz.")
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
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("group.backButton")

            TablerIcon(name: "folder", size: 18, color: Theme.codex)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(records.count) oturum · \(project.name)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button("Grubu Sil") {
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
                    Text("TOPLU YÖNETİM")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(0.6)
                    Text(selectedSessionIDs.isEmpty
                         ? "İşlemler gruptaki tüm oturumlara uygulanır."
                         : "İşlemler seçili \(targetIDs.count) oturuma uygulanır.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button(selectedSessionIDs.isEmpty ? "Tümünü Seç" : "Seçimi Temizle") {
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
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(8)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .accessibilityIdentifier("group.prompt")

            HStack(spacing: 8) {
                Button("Tümüne Gönder") { sendPrompt() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || targetIDs.isEmpty)
                    .accessibilityIdentifier("group.send")
                Button("Kes") { interruptTargets() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("group.interrupt")
                Button("Yeniden Başlat") { restartTargets() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(targetIDs.isEmpty)
                    .accessibilityIdentifier("group.restart")
                Spacer()
                Button("Sil", role: .destructive) { showDelete = true }
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
                Text("OTURUMLAR")
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(0.6)
                Spacer()
                Text("\(records.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(12)

            if records.isEmpty {
                Text("Bu grupta oturum yok. Kenar çubuğundan oturumları buraya sürükleyebilirsin.")
                    .font(Theme.mono(11))
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
                    .foregroundStyle(selected ? Theme.codex : Theme.textFaint)
            }
            .buttonStyle(.plain)
            ProviderMark(provider: record.provider, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(sessionStore.detail(of: record.id)
                     ?? sessionStore.status(of: record.id).label)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            StatusOrb(status: sessionStore.status(of: record.id), size: 11)
            Button("Aç") {
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
            .help("Gruptan çıkar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            selected ? Theme.panelActive : Theme.panel.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8)
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
