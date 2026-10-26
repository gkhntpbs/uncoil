import SwiftUI

/// Bringing in conversations an agent CLI already has for a project — work
/// done in Claude Code or Codex before Uncoil, or beside it.
///
/// Nothing is copied and nothing is launched: the list is read from the CLIs'
/// own stores, and what is imported arrives as sleeping sessions that resume
/// their conversation when woken.
struct SessionImportSheet: View {
    let project: Project
    /// Called with what was imported, after the sheet has recorded it.
    let onImported: ([SessionRecord]) -> Void

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var found: [ImportableSession]?
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var provider: AgentProvider?

    /// Conversations some session already points at. Read once per render
    /// from the store, so a session imported elsewhere meanwhile shows here.
    private var alreadyImported: Set<String> { projectStore.importedConversationKeys }

    private var visible: [ImportableSession] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (found ?? []).filter { session in
            (provider == nil || session.provider == provider)
                && (needle.isEmpty || session.title.lowercased().contains(needle)
                    || session.providerSessionID.lowercased().hasPrefix(needle))
        }
    }

    private var importable: [ImportableSession] {
        visible.filter { !alreadyImported.contains($0.id) }
    }

    private var chosen: [ImportableSession] {
        (found ?? []).filter { selected.contains($0.id) && !alreadyImported.contains($0.id) }
    }

    private var providersFound: [AgentProvider] {
        let present = Set((found ?? []).map(\.provider))
        return [AgentProvider.claude, .codex].filter(present.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if let found, !found.isEmpty {
                filters
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                list
            } else {
                placeholder
            }
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 640, height: 520)
        .background(Theme.bg)
        .accessibilityIdentifier("sessionImport.sheet")
        .task { await scan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Import Sessions")
                .font(Theme.mono(.large, .bold))
                .foregroundStyle(Theme.text)
            Text("Conversations Claude Code and Codex already have for \(project.name). Imported sessions start asleep; waking one resumes its conversation.")
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text(project.rootPath)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                TablerIcon(name: "search", size: 12, color: Theme.textFaint)
                TextField("Search by title or ID…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("sessionImport.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .panel()

            if providersFound.count > 1 {
                Picker("", selection: $provider) {
                    Text("All").tag(AgentProvider?.none)
                    ForEach(providersFound) { provider in
                        Text(provider.displayName).tag(AgentProvider?.some(provider))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("sessionImport.provider")
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { session in
                    SessionImportRow(
                        session: session,
                        isImported: alreadyImported.contains(session.id),
                        isSelected: selected.contains(session.id)
                    ) {
                        if selected.contains(session.id) {
                            selected.remove(session.id)
                        } else {
                            selected.insert(session.id)
                        }
                    }
                }
                if visible.isEmpty {
                    Text("Nothing matches the search.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .uncoilScrollers()
        }
        .accessibilityIdentifier("sessionImport.list")
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if found == nil {
                ProgressView().controlSize(.small)
                Text("Looking for conversations…")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
            } else {
                TablerIcon(name: "history", size: 20, color: Theme.textFaint)
                Text("No conversations found for this project.")
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.textDim)
                Text("Uncoil reads ~/.claude, ~/.codex and the config folder of each account profile, and lists conversations held in the project folder or one of its git worktrees.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sessionImport.placeholder")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if !importable.isEmpty {
                let allChosen = importable.allSatisfy { selected.contains($0.id) }
                Button(allChosen ? "Select None" : "Select All") {
                    if allChosen {
                        selected.subtract(importable.map(\.id))
                    } else {
                        selected.formUnion(importable.map(\.id))
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .accessibilityIdentifier("sessionImport.selectAll")
            }
            if let found, !found.isEmpty {
                Text("\(found.count) found · \(found.filter { alreadyImported.contains($0.id) }.count) already imported")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            Button(chosen.isEmpty ? "Import" : "Import \(chosen.count)") { importChosen() }
                .buttonStyle(AccentButtonStyle())
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sessionImport.import")
        }
        .padding(16)
    }

    /// Off the main thread: a year of Codex rollouts is hundreds of files to
    /// open, and the sheet should be drawn while they are read.
    private func scan() async {
        let root = project.rootPath
        let sources = SessionImportSource.all(settings: settings)
        let result = await Task.detached(priority: .userInitiated) {
            SessionImportScanner.scan(projectRoot: root, sources: sources)
        }.value
        found = result
    }

    private func importChosen() {
        let records = projectStore.importSessions(chosen, into: project.id)
        // The store records them asleep; the status has to say so too, or the
        // rows read as terminated until the next launch restores it.
        for record in records {
            sessionStore.setStatus(.hibernated, origin: .lifecycle, for: record.id)
        }
        onImported(records)
        dismiss()
    }
}

private struct SessionImportRow: View {
    let session: ImportableSession
    let isImported: Bool
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isImported || isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isImported ? Theme.textFaint : isSelected ? Theme.highlight : Theme.textFaint)
                    .frame(width: 14)
                ProviderMark(provider: session.provider, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MarkdownInline.plain(session.title))
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(isImported ? Theme.textDim : Theme.text)
                        .lineLimit(1)
                    Text(details)
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isImported {
                    Text("Imported")
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text(session.lastActivityAt, format: .relative(presentation: .named))
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                hovering && !isImported ? Theme.highlightMuted.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isImported)
        .onHover { hovering = $0 }
        .help(session.title)
        .accessibilityIdentifier("sessionImport.row.\(session.providerSessionID)")
    }

    private var details: String {
        var parts = [
            session.startedAt.formatted(date: .abbreviated, time: .shortened),
            session.sourceName,
        ]
        if let worktree = session.worktreePath {
            parts.append("worktree \(URL(fileURLWithPath: worktree).lastPathComponent)")
        }
        parts.append(String(session.providerSessionID.prefix(8)))
        return parts.joined(separator: " · ")
    }
}
