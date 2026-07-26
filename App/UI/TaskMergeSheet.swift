import SwiftUI

/// The merge screen for one task: the diff, the test runs, the review verdict,
/// and everything still standing in the way.
///
/// Nothing merges until the button here is pressed. Every attempt — including a
/// refusal — is recorded, so "why was this not merged?" has an answer.
struct TaskMergeSheet: View {
    let task: ProjectTask
    let project: Project
    let worktreePath: String?
    @ObservedObject var results: TaskResultStore
    /// Called with the note to show after the sheet closes.
    let onFinished: (String) -> Void
    let onCancel: () -> Void

    @State private var snapshot = GitService.Snapshot()
    @State private var conflicted: [String] = []
    @State private var diff = ""
    @State private var loading = true
    @State private var merging = false
    @State private var failure: String?

    private var settings: OrchestratorSettings {
        OrchestratorStore(projectID: project.id).settings
    }

    /// The preview with the user's approval withheld: that is the state the
    /// screen is showing, and the button is what changes it.
    private var preview: TaskCompletionGate.MergePreview {
        results.mergePreview(
            taskID: task.id,
            branch: snapshot.branch,
            changedFiles: snapshot.changedFiles.map(\.path),
            conflictedFiles: conflicted,
            uncommittedChanges: snapshot.changedFiles.count,
            userApproved: false,
            settings: settings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        Text("Reading the worktree…")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textFaint)
                    } else {
                        blockersSection
                        testsSection
                        reviewSection
                        changesSection
                        diffSection
                    }
                }
                .padding(16)
            }
            .uncoilScrollers()
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Theme.bg)
        .task { await load() }
        .accessibilityIdentifier("taskMerge.sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Merge")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.text)
            Text(task.text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
            if let branch = snapshot.branch {
                Text("\(branch) → \(project.name)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.highlight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var blockersSection: some View {
        let blockers = preview.hardBlockers
        VStack(alignment: .leading, spacing: 6) {
            Text(blockers.isEmpty ? "Ready" : "Blockers")
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(blockers.isEmpty ? Theme.ok : Theme.warn)
            if blockers.isEmpty {
                Text("Everything is in place; the merge is only waiting for your word.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
            } else {
                ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                    HStack(spacing: 6) {
                        TablerIcon(name: "alert-triangle", size: 10, color: Theme.warn)
                        Text(blocker.message)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            if let failure {
                Text(failure)
                    .font(Theme.mono(10.5, .semibold))
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("taskMerge.failure")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var testsSection: some View {
        section("Tests") {
            if preview.tests.isEmpty {
                Text("No recorded test run.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                ForEach(preview.tests.reversed()) { test in
                    HStack(spacing: 6) {
                        TablerIcon(
                            name: test.passed ? "flask" : "flask-off",
                            size: 10,
                            color: test.passed ? Theme.ok : Theme.danger
                        )
                        Text(test.command)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textDim)
                        Text(test.summary)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(test.passed ? Theme.ok : Theme.danger)
                        Spacer()
                        if !test.artifacts.isEmpty {
                            Text(test.artifacts.joined(separator: ", "))
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        section("Review") {
            if preview.reviews.isEmpty {
                Text("No review.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                ForEach(preview.reviews.reversed()) { review in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(review.verdict.label)
                            .font(Theme.mono(10.5, .semibold))
                            .foregroundStyle(
                                review.verdict == .changesRequested ? Theme.warn : Theme.ok
                            )
                        ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                            Text("• \(finding)")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var changesSection: some View {
        section("Changed files") {
            if preview.changedFiles.isEmpty {
                Text("No uncommitted changes.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                ForEach(preview.changedFiles, id: \.self) { path in
                    Text(path)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.warn)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var diffSection: some View {
        section("Diff") {
            if diff.isEmpty {
                Text("No diff.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            } else {
                ScrollView(.horizontal) {
                    Text(diff)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .accessibilityIdentifier("taskMerge.diff")
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(Theme.text)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "no worktree")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Button("Cancel") {
                record(outcome: .refused(reason: "you cancelled"), approved: false)
                onCancel()
            }
            .buttonStyle(GhostButtonStyle())
            Button(merging ? "Merging…" : "Approve and merge") { merge() }
                .buttonStyle(AccentButtonStyle())
                .disabled(loading || merging || !preview.hardBlockers.isEmpty)
                .accessibilityIdentifier("taskMerge.approve")
        }
        .padding(16)
    }

    // MARK: - Actions

    private func load() async {
        guard let worktree = worktreePath else {
            loading = false
            failure = "The task has no worktree; there is no branch to merge."
            return
        }
        let read = await Task.detached(priority: .userInitiated) {
            (
                snapshot: GitService.snapshot(repoPath: worktree),
                conflicted: GitService.conflictedFiles(repoPath: worktree),
                diff: GitService.diff(repoPath: worktree)
            )
        }.value
        snapshot = read.snapshot
        conflicted = read.conflicted
        diff = read.diff
        loading = false
    }

    private func merge() {
        guard let branch = snapshot.branch else {
            failure = "The branch name could not be read; cannot merge."
            return
        }
        merging = true
        let root = project.rootPath
        let text = task.text
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                GitService.merge(
                    repoPath: root, branch: branch,
                    message: "Merge task: \(text)"
                )
            }.value
            merging = false
            switch result {
            case .success(let commit):
                record(outcome: .merged(commit: commit), approved: true)
                onFinished(
                    "\(branch) → \(project.name) merge edildi"
                        + (commit.map { " (\($0))" } ?? "")
                )
            case .failure(let error):
                record(outcome: .failed(message: error.message), approved: true)
                failure = error.message
            }
        }
    }

    private func record(outcome: TaskMergeRecord.Outcome, approved: Bool) {
        results.record(merge: TaskMergeRecord(
            taskID: task.id,
            branch: snapshot.branch,
            worktreePath: worktreePath,
            outcome: outcome,
            approvedByUser: approved
        ))
    }
}
