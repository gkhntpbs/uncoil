import SwiftUI

/// Committing what an agent (or the user) changed for one task.
///
/// The file list is explicit: only what is ticked is staged, the message is
/// editable with the task-derived default, and nothing touches git until the
/// commit button. The PR path lives here too, so "iş bitti → commit → PR" is
/// one surface instead of a terminal trip.
struct TaskCommitSheet: View {
    let task: ProjectTask
    /// Repo the changes live in: the task's worktree when it has one.
    let repoRoot: String
    let onDone: (String) -> Void
    let onCancel: () -> Void

    private let actions = TaskGitActions()
    @State private var files: [String] = []
    @State private var selected: Set<String> = []
    @State private var commitMessage = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Commit — \(task.text)")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(repoRoot)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider().overlay(Theme.border)

            if files.isEmpty {
                Text(didLoad ? "Commit edilecek değişiklik yok." : "Değişiklikler okunuyor…")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.self) { file in
                            fileRow(file)
                        }
                    }
                    .uncoilScrollers()
                }
                .frame(maxHeight: 220)
            }

            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit mesajı")
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.textFaint)
                TextField("", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(11.5))
                    .accessibilityIdentifier("tasks.commit.message")
            }
            .padding(14)

            if let error {
                Text(error)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                Text("\(selected.count)/\(files.count) dosya")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Vazgeç", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Commit + PR aç") { commit(openPR: true) }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(selected.isEmpty || isWorking)
                    .accessibilityIdentifier("tasks.commit.pr")
                Button("Commit") { commit(openPR: false) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(selected.isEmpty || isWorking)
                    .accessibilityIdentifier("tasks.commit.confirm")
            }
            .padding(14)
        }
        .frame(width: 560)
        .background(Theme.bg)
        .onAppear(perform: load)
        .accessibilityIdentifier("tasks.commitSheet")
    }

    private func fileRow(_ file: String) -> some View {
        let isOn = selected.contains(file)
        return Button {
            if isOn { selected.remove(file) } else { selected.insert(file) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? Theme.highlight : Theme.textFaint)
                Text(file)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard !didLoad else { return }
        commitMessage = TaskGitActions.defaultCommitMessage(for: task)
        let root = repoRoot
        Task {
            let changed = await Task.detached(priority: .utility) {
                TaskGitActions().changedFiles(repoRoot: root)
            }.value
            files = changed
            // Everything preselected: the common case is "commit what the agent
            // just did", and narrowing down is the exception.
            selected = Set(changed)
            didLoad = true
        }
    }

    private func commit(openPR: Bool) {
        isWorking = true
        error = nil
        let picked = files.filter { selected.contains($0) }
        let root = repoRoot
        let message = commitMessage
        let task = task
        Task {
            do {
                let hash = try await Task.detached(priority: .userInitiated) {
                    try TaskGitActions().commit(
                        task: task, files: picked, repoRoot: root, message: message
                    )
                }.value
                if openPR {
                    let url = try await TaskGitActions()
                        .createPullRequest(task: task, repoRoot: root)
                    NSWorkspace.shared.open(url)
                    onDone("Commit \(hash) yapıldı, PR açıldı: \(url.absoluteString)")
                } else {
                    onDone("Commit \(hash) yapıldı (\(picked.count) dosya).")
                }
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
