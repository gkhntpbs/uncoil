import Foundation

/// Who shares a working tree.
///
/// A git working tree has exactly one checkout, so every session running in the
/// same directory is on the same branch whether it knows it or not — two
/// sessions in one worktree cannot be on different branches. That makes a
/// checkout everyone's business: the files move under all of them at once, not
/// only under the session whose header was clicked.
enum WorkingTree {
    /// Sessions of `project` whose working directory is `path`.
    ///
    /// Paths are standardised before comparing, so a trailing slash or a
    /// symlinked root does not split one tree into two.
    static func sessions(
        at path: String, in project: Project, from all: [SessionRecord]
    ) -> [SessionRecord] {
        let tree = normalise(path)
        return all.filter {
            $0.projectID == project.id && normalise($0.workingDirectory(in: project)) == tree
        }
    }

    static func normalise(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension AgentSessionStatus {
    /// True while the agent has work in flight — the states where replacing the
    /// files beneath it interrupts something.
    var isWorking: Bool {
        switch self {
        case .thinking, .running, .waitingForPermission, .waitingForInput: true
        case .idle, .completed, .terminated: false
        }
    }
}
