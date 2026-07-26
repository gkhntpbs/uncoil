import SwiftUI

/// The list of branches a working tree can move to, as menu content.
///
/// Split out from the chip so the project header and a session header offer the
/// same switch from two very different-looking controls. `repoPath` is whichever
/// tree the surrounding view is looking at: for a task session that is its
/// worktree, and switching there must not move the project's checkout.
struct BranchSwitchMenu: View {
    let repoPath: String
    let current: String
    /// Called after a successful switch, so the caller can re-read its state.
    var onSwitched: (() -> Void)?

    @State private var branches: [GitService.Branch] = []
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        Group {
            if branches.isEmpty {
                Text(isLoading ? "Reading branches…" : "No other branch")
            } else {
                ForEach(branches) { candidate in
                    Button { switchTo(candidate) } label: {
                        // The current branch keeps a tick; a branch another
                        // worktree holds says so rather than failing when it is
                        // picked, because git allows a branch in one tree only.
                        if candidate.isCurrent {
                            Label(candidate.name, systemImage: "checkmark")
                        } else if let holder = candidate.heldBy {
                            Text("\(candidate.name) — open in \(shortPath(holder))")
                        } else {
                            Text(candidate.name)
                        }
                    }
                    .disabled(!candidate.isSwitchable)
                }
            }
            if let failure {
                Divider()
                Text(failure)
            }
            Divider()
            Button("Refresh") { reload() }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        guard !isLoading else { return }
        isLoading = true
        let path = repoPath
        Task {
            let found = await Task.detached { GitService.branches(repoPath: path) }.value
            await MainActor.run {
                branches = found
                isLoading = false
            }
        }
    }

    private func switchTo(_ candidate: GitService.Branch) {
        guard candidate.isSwitchable else { return }
        failure = nil
        let path = repoPath
        Task {
            let result = await Task.detached {
                GitService.checkout(repoPath: path, branch: candidate.name)
            }.value
            await MainActor.run {
                switch result {
                case .success:
                    // git refuses a switch that would lose work, so reaching
                    // here means the tree really moved.
                    onSwitched?()
                    reload()
                case .failure(let error):
                    failure = error.message
                }
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// "This is the branch the work lands on" — and the way to change it.
///
/// Sized like the control blocks it sits between: 22pt of content inside a 3pt
/// inset, one 8pt-radius bordered box. It hugs its text rather than taking a
/// flexible width, because a flexible frame in the header stretched the chip
/// across whatever room was left.
struct BranchBadge: View {
    let branch: String
    /// The working tree this chip speaks for. Nil makes the chip read-only,
    /// which is what a view without a repo path should show.
    var repoPath: String?
    var onSwitched: (() -> Void)?
    /// Longest name shown before it is cut; a chip is not the place to read a
    /// forty-character branch.
    var maximumCharacters = 22

    var body: some View {
        Group {
            if let repoPath {
                Menu {
                    BranchSwitchMenu(
                        repoPath: repoPath, current: branch, onSwitched: onSwitched)
                } label: {
                    chip
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Active branch: \(branch) — click to switch")
            } else {
                chip.help("Active branch: \(branch)")
            }
        }
        .accessibilityIdentifier("branch.badge")
    }

    private var chip: some View {
        HStack(spacing: 5) {
            TablerIcon(name: "git-branch", size: 12, color: Theme.textFaint)
            Text(shortened)
                .font(Theme.mono(.body, .medium))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .padding(3)
        .fixedSize()
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var shortened: String {
        branch.count > maximumCharacters
            ? branch.prefix(maximumCharacters - 1) + "…"
            : branch
    }
}
