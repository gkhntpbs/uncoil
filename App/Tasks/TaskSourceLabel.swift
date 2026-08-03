import Foundation

/// Naming the file a task came from.
///
/// A project may hold several task files, and in practice they are all called
/// `TODO.md` — one at the root, one under `docs/`, one per package. Labelling a
/// task by its last path component therefore says "TODO.md" for every one of
/// them: the user cannot tell two tasks apart, and an agent told to work on
/// "TODO.md" opens the wrong file. Everything here works from the path relative
/// to the project root instead, which is the only part that distinguishes them.
enum TaskSourceLabel {
    /// The project-relative path of a source, preferring what the scan already
    /// recorded.
    ///
    /// The scan carries the relative path through the walk rather than deriving
    /// it, because on macOS an enumerated child comes back under `/private/var`
    /// while the root normalises to `/var` and prefix matching silently fails —
    /// so a recorded `displayPath` is trusted over recomputing one.
    static func displayPath(
        forSourcePath path: String,
        knownSources: [ProjectTaskSource],
        projectRoot: String
    ) -> String {
        if let known = knownSources.first(where: { $0.path == path }) {
            return known.displayPath
        }
        return TodoDiscovery.relativePath(
            of: URL(fileURLWithPath: path),
            from: URL(fileURLWithPath: projectRoot)
        )
    }

    /// A label short enough for a task row but still unambiguous.
    ///
    /// The file name alone is not unique; the full relative path can be long.
    /// The last two components keep the folder that actually distinguishes the
    /// file, and an ellipsis marks what was dropped.
    static func short(displayPath: String) -> String {
        let components = displayPath.split(separator: "/").map(String.init)
        guard components.count > 2 else { return displayPath }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    /// Where a task lives, for a prompt handed to an agent.
    ///
    /// The full relative path, never the shortened form: the agent has to be
    /// able to open exactly this file from the project root.
    static func location(displayPath: String, headingPath: [String]) -> String {
        guard !headingPath.isEmpty else { return displayPath }
        return "\(displayPath) › \(headingPath.joined(separator: " › "))"
    }
}
