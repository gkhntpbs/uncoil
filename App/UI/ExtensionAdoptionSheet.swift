import SwiftUI

/// Adopting an extension Uncoil did not install: the file diff and the backup
/// come first, and the button is the only thing that copies anything.
struct ExtensionAdoptionSheet: View {
    let plan: ExtensionAdoptionService.Plan
    let onAdopt: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Uncoil'e devral")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.text)
                Text("\(plan.name) · \(plan.kind.label) · \(plan.summary)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textDim)
                Text(plan.externalPath)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if plan.changedFiles.isEmpty {
                        Text("Dosya farkı yok; devralma yalnızca yönetimi devreder.")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                    ForEach(plan.changedFiles) { change in
                        HStack(spacing: 7) {
                            Text(marker(change.kind))
                                .font(Theme.mono(10, .bold))
                                .foregroundStyle(color(change.kind))
                                .frame(width: 12)
                            Text(change.path)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textDim)
                            Spacer()
                            Text(label(change.kind))
                                .font(Theme.mono(9))
                                .foregroundStyle(color(change.kind))
                        }
                    }
                    if !plan.agentCopies.isEmpty {
                        Divider().overlay(Theme.border).padding(.vertical, 6)
                        Text("Ortak kopyaya alınacak agent klasörleri")
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.textFaint)
                        ForEach(plan.agentCopies) { copy in
                            HStack(spacing: 6) {
                                TablerIcon(name: "link", size: 10, color: Theme.highlight)
                                Text("\(copy.agent.displayName): \(copy.path)")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                            }
                        }
                        Text("Her klasör önce yedeklenir, sonra tek kopyaya symlink olur.")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                    if !plan.findings.isEmpty {
                        Divider().overlay(Theme.border).padding(.vertical, 6)
                        ForEach(plan.findings) { finding in
                            HStack(alignment: .top, spacing: 6) {
                                TablerIcon(
                                    name: "shield-lock",
                                    size: 10,
                                    color: finding.severity >= .high ? Theme.danger : Theme.warn
                                )
                                Text("\(finding.severity.label): \(finding.message)")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .uncoilScrollers()
            }
            .accessibilityIdentifier("adoption.changes")

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yedek: \(plan.backupPath ?? "alınamadı")")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(plan.backupPath == nil ? Theme.danger : Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !plan.blocksAdoption.isEmpty {
                        Text("Blocked bulgu devralmayı engelliyor.")
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
                Button("Vazgeç", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Devral", action: onAdopt)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!plan.isAdoptable)
                    .accessibilityIdentifier("adoption.adopt")
            }
            .padding(16)
        }
        .frame(width: 620, height: 470)
        .background(Theme.bg)
        .accessibilityIdentifier("adoption.sheet")
    }

    private func marker(_ kind: ExtensionAdoptionService.FileChange.Kind) -> String {
        switch kind {
        case .added: "+"
        case .modified: "~"
        case .removed: "-"
        case .unchanged: " "
        }
    }

    private func label(_ kind: ExtensionAdoptionService.FileChange.Kind) -> String {
        switch kind {
        case .added: "eklenecek"
        case .modified: "üzerine yazılacak"
        case .removed: "geride kalacak"
        case .unchanged: "aynı"
        }
    }

    private func color(_ kind: ExtensionAdoptionService.FileChange.Kind) -> Color {
        switch kind {
        case .added: Theme.ok
        case .modified: Theme.warn
        case .removed: Theme.danger
        case .unchanged: Theme.textFaint
        }
    }
}

/// Attaching a GitHub source to a local extension, so it can be updated from
/// then on. What to track is the user's choice, not a default guess.
struct RepositoryLinkSheet: View {
    let packageName: String
    let onLink: (String, ExtensionSource.TrackingMode) -> Void
    let onCancel: () -> Void

    @State private var repository = ""
    @State private var mode = Mode.branch
    @State private var reference = "main"

    private enum Mode: String, CaseIterable, Identifiable {
        case branch, tag, commit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .branch: "Branch"
            case .tag: "Tag"
            case .commit: "Commit"
            }
        }
    }

    private var tracking: ExtensionSource.TrackingMode {
        switch mode {
        case .branch: .branch(reference)
        case .tag: .tag(reference)
        case .commit: .pinnedCommit(reference)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub kaynağına bağla")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.text)
            Text("\(packageName) şu an unmanaged. Bir depoya bağlanınca güncellenebilir olur.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            TextField("owner/repo", text: $repository)
                .font(Theme.mono(11))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("repositoryLink.repository")

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(mode == .commit ? "commit SHA" : "referans", text: $reference)
                .font(Theme.mono(11))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("repositoryLink.reference")

            HStack(spacing: 9) {
                Spacer()
                Button("Vazgeç", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Bağla") { onLink(repository, tracking) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(
                        !repository.contains("/")
                            || reference.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                    .accessibilityIdentifier("repositoryLink.link")
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.bg)
        .accessibilityIdentifier("repositoryLink.sheet")
    }
}
