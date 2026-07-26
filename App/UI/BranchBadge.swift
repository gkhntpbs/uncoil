import AppKit
import SwiftUI

/// What to call a working tree in the interface.
///
/// The project's own checkout has no folder name worth showing — it is just the
/// project — so it is named for what it is. Everything else is the worktree's
/// folder, which is what the worktree list and the branch chip both show.
enum WorktreeNaming {
    static func name(forTreeAt path: String, projectRoot: String) -> String {
        let tree = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        return tree == root
            ? String(localized: "main copy")
            : URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Opens the branch list as a real `NSMenu`, anchored under a custom label.
///
/// SwiftUI's `Menu` renders its own control around the label, and with a
/// borderless style on macOS it kept the icon while dropping the branch name
/// beside it — the one thing the chip exists to show. Popping an `NSMenu` from
/// a plain `Button` leaves the label entirely ours, and gives the menu AppKit's
/// own keyboard handling for free.
struct BranchMenuButton<Label: View>: View {
    let repoPath: String
    let current: String
    var onSwitched: (() -> Void)?
    @ViewBuilder var label: Label

    @State private var branches: [GitService.Branch] = []
    @State private var failure: String?
    @State private var anchor: NSView?

    var body: some View {
        Button(action: present) { label }
            .buttonStyle(.plain)
            .background(AnchorView(view: $anchor))
            // Branches appear under the app's hands — an agent creating one, a
            // worktree being cut — so the list is already current when the menu
            // opens rather than being read at click time.
            .task(id: repoPath) {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC)
                }
            }
    }

    private func load() async {
        let path = repoPath
        let found = await Task.detached { GitService.branches(repoPath: path) }.value
        if branches != found { branches = found }
    }

    private func present() {
        guard let anchor else { return }
        let menu = NSMenu()

        if branches.isEmpty {
            let item = NSMenuItem(
                title: String(localized: "Reading branches…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for candidate in branches {
            // A branch another worktree holds names that tree instead of failing
            // once it is picked: git allows a branch in one tree at a time.
            let title = candidate.heldBy.map {
                String(localized: "\(candidate.name) — open in \(shortPath($0))")
            } ?? candidate.name
            let item = NSMenuItem(
                title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.state = candidate.isCurrent ? .on : .off
            item.isEnabled = candidate.isSwitchable
            item.target = MenuTarget.shared
            item.representedObject = MenuTarget.Pick(branch: candidate.name) { name in
                switchTo(name)
            }
            menu.addItem(item)
        }

        if let failure {
            menu.addItem(.separator())
            let item = NSMenuItem(title: failure, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: String(localized: "Refresh"),
            action: #selector(MenuTarget.pick(_:)), keyEquivalent: "r")
        refresh.target = MenuTarget.shared
        refresh.representedObject = MenuTarget.Pick(branch: "") { _ in
            Task { await load() }
        }
        menu.addItem(refresh)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.height + 4),
            in: anchor)
    }

    private func switchTo(_ name: String) {
        failure = nil
        let path = repoPath
        Task { @MainActor in
            let result = await Task.detached {
                GitService.checkout(repoPath: path, branch: name)
            }.value
            switch result {
            case .success:
                // git refuses a switch that would lose work, so reaching here
                // means the tree really moved.
                onSwitched?()
                await load()
            case .failure(let error):
                failure = error.message
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// `NSMenuItem` needs an ObjC target; this is the one the app keeps.
@MainActor
private final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    final class Pick: NSObject {
        let branch: String
        let run: (String) -> Void
        init(branch: String, run: @escaping (String) -> Void) {
            self.branch = branch
            self.run = run
        }
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        pick.run(pick.branch)
    }
}

/// Hands back the `NSView` a menu can be anchored to.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { view = probe.superview ?? probe }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
    /// The working tree the branch is checked out in, when it is worth naming.
    ///
    /// A branch alone does not say *where* it is checked out, and with task
    /// worktrees open that is the difference between the project and a copy of
    /// it.
    var worktreeName: String?
    var onSwitched: (() -> Void)?
    /// Longest name shown before it is cut; a chip is not the place to read a
    /// forty-character branch.
    var maximumCharacters = 22

    var body: some View {
        Group {
            if let repoPath {
                BranchMenuButton(
                    repoPath: repoPath, current: branch, onSwitched: onSwitched
                ) {
                    chip
                }
            } else {
                chip
            }
        }
        .help(helpText)
        .accessibilityIdentifier("branch.badge")
    }

    private var chip: some View {
        HStack(spacing: 5) {
            TablerIcon(name: "git-branch", size: 12, color: Theme.textFaint)
            Text(shortened)
                .font(Theme.mono(.body, .medium))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            if let worktreeName {
                Text("·")
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textFaint)
                Text(worktreeName)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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

    private var helpText: String {
        if let worktreeName {
            return String(localized: "\(branch) in \(worktreeName) — click to switch")
        }
        return repoPath == nil
            ? String(localized: "Active branch: \(branch)")
            : String(localized: "Active branch: \(branch) — click to switch")
    }

    private var shortened: String {
        branch.count > maximumCharacters
            ? branch.prefix(maximumCharacters - 1) + "…"
            : branch
    }
}
