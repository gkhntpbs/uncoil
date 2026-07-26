import Foundation

/// Git state of one `TODO.md`, as the Tasks screen shows it.
enum TaskFileGitStatus: Equatable {
    case clean
    case modified
    case untracked
    /// Unresolved merge conflict: the file is read-only until it is settled.
    case conflict(markers: [ConflictRegion])
    case ignored
    /// Not a git repository at all.
    case notTracked

    var label: String {
        switch self {
        case .clean: "Clean"
        case .modified: "Modified"
        case .untracked: "Untracked"
        case .conflict: "Conflict"
        case .ignored: "Ignored"
        case .notTracked: "Not a git repo"
        }
    }

    /// Editing is refused while a conflict is unresolved: patching a file with
    /// conflict markers in it would write nonsense into the user's work.
    var isEditable: Bool {
        switch self {
        case .conflict: false
        case .clean, .modified, .untracked, .ignored, .notTracked: true
        }
    }

    var conflicts: [ConflictRegion] {
        if case .conflict(let markers) = self { return markers }
        return []
    }

    /// One `<<<<<<< / ======= / >>>>>>>` region, with the lines it spans so the
    /// UI can point at it.
    struct ConflictRegion: Equatable, Identifiable {
        var startLine: Int
        var separatorLine: Int?
        var endLine: Int
        var ourLabel: String
        var theirLabel: String

        var id: Int { startLine }

        var lineCount: Int { endLine - startLine + 1 }
    }

    /// Reads the status from git's porcelain code plus the file's own content.
    ///
    /// The content check matters: a file can carry conflict markers while git
    /// has already been told the conflict is resolved, and editing it then would
    /// still corrupt the user's work.
    static func from(
        porcelainCode: String?,
        contents: String?,
        isIgnored: Bool = false,
        isRepository: Bool = true
    ) -> TaskFileGitStatus {
        guard isRepository else { return .notTracked }
        if isIgnored { return .ignored }
        let regions = contents.map(conflictRegions) ?? []
        if !regions.isEmpty { return .conflict(markers: regions) }
        guard let code = porcelainCode?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
            return .clean
        }
        // Both-modified and friends are what git reports for a conflict.
        if ["UU", "AA", "DU", "UD", "AU", "UA", "DD"].contains(code) {
            return .conflict(markers: regions)
        }
        if code.contains("?") { return .untracked }
        if code.contains("!") { return .ignored }
        return .modified
    }

    /// Finds conflict regions by their markers.
    static func conflictRegions(in contents: String) -> [ConflictRegion] {
        var regions: [ConflictRegion] = []
        var open: (start: Int, label: String, separator: Int?)?
        for (index, line) in contents.components(separatedBy: "\n").enumerated() {
            let number = index + 1
            if line.hasPrefix("<<<<<<<") {
                open = (number, String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces), nil)
            } else if line.hasPrefix("======="), var current = open {
                current.separator = number
                open = current
            } else if line.hasPrefix(">>>>>>>"), let current = open {
                regions.append(ConflictRegion(
                    startLine: current.start,
                    separatorLine: current.separator,
                    endLine: number,
                    ourLabel: current.label.isEmpty ? "ours" : current.label,
                    theirLabel: String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                ))
                open = nil
            }
        }
        return regions
    }
}

/// Reads the git state of a project's task sources.
///
/// Split in two: the pure `statuses(codes:…)` that the tests drive, and a
/// blocking wrapper that shells out to git.
enum TaskGitStatusReader {
    /// Blocking; call from a background task.
    static func statuses(
        repoRoot: String,
        contentsByPath: [String: String]
    ) -> [String: TaskFileGitStatus] {
        let isRepository = GitService.isRepository(repoRoot)
        let relatives = contentsByPath.keys.reduce(into: [String: String]()) { map, path in
            map[relativePath(of: path, under: repoRoot)] = path
        }
        let codes = isRepository
            ? GitService.fileStatuses(repoPath: repoRoot, relativePaths: Array(relatives.keys))
            : [:]
        return statuses(
            codes: codes,
            relativePaths: relatives,
            contentsByPath: contentsByPath,
            isRepository: isRepository
        )
    }

    /// Pure: `relativePaths` maps repo-relative path → absolute path.
    static func statuses(
        codes: [String: String],
        relativePaths: [String: String],
        contentsByPath: [String: String],
        isRepository: Bool
    ) -> [String: TaskFileGitStatus] {
        var result: [String: TaskFileGitStatus] = [:]
        for (relative, absolute) in relativePaths {
            let code = codes[relative]
            result[absolute] = TaskFileGitStatus.from(
                porcelainCode: code,
                contents: contentsByPath[absolute],
                isIgnored: code?.contains("!") == true,
                isRepository: isRepository
            )
        }
        return result
    }

    /// Repo-relative path, or the absolute path when it sits outside the repo —
    /// git would report nothing for it either way, so it reads as clean.
    static func relativePath(of path: String, under root: String) -> String {
        let root = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count))
    }
}

/// Follows the conflict state of task sources between refreshes.
///
/// A conflict that clears has to trigger a reparse and a relink: the file the UI
/// is showing was frozen while the conflict lasted, and the tasks in it may have
/// moved, been reworded or vanished during the merge.
struct TaskConflictTracker: Equatable {
    enum Transition: Equatable {
        case becameConflicted(path: String)
        case resolved(path: String)
    }

    private(set) var conflicted: Set<String> = []

    init(conflicted: Set<String> = []) {
        self.conflicted = conflicted
    }

    /// Applies a fresh status map and reports what changed. Paths that dropped
    /// out of the map entirely count as resolved: a file that is gone is no
    /// longer a conflict to sit and wait on.
    mutating func apply(_ statuses: [String: TaskFileGitStatus]) -> [Transition] {
        let now = Set(statuses.filter { !$0.value.isEditable }.keys)
        let appeared = now.subtracting(conflicted)
        let cleared = conflicted.subtracting(now)
        conflicted = now
        return (appeared.sorted().map { Transition.becameConflicted(path: $0) }
            + cleared.sorted().map { Transition.resolved(path: $0) })
    }

    func isConflicted(_ path: String) -> Bool { conflicted.contains(path) }
}

/// Checks that a task edit changed only what it claimed to.
///
/// The whole point of patching byte ranges is that nothing else moves. This
/// verifies it after the fact, so a bug that reformats the user's file is caught
/// as an error rather than shipped quietly.
enum TaskDiffAudit {
    struct Finding: Equatable {
        enum Kind: Equatable {
            /// Lines changed outside the task's own block.
            case changedOutsideBlock(lines: [Int])
            /// Almost every line differs: the file was regenerated.
            case wholeFileRewritten(changedLines: Int, totalLines: Int)
            /// Line count changed although the edit should not have added or
            /// removed lines.
            case unexpectedLineCountChange(before: Int, after: Int)
        }

        var kind: Kind
        var message: String
    }

    /// What an edit was supposed to touch.
    enum Expectation: Equatable {
        case checkbox
        case title
        case description
        case move
        case delete

        /// Whether this kind of edit may change how many lines the file has.
        var mayChangeLineCount: Bool {
            switch self {
            case .checkbox, .title: false
            case .description, .move, .delete: true
            }
        }

        var label: String {
            switch self {
            case .checkbox: "checkbox"
            case .title: "heading"
            case .description: "description"
            case .move: "move"
            case .delete: "silme"
            }
        }
    }

    /// Verifies an edit. `allowedLines` are the 1-based line numbers the task's
    /// block occupied before the edit; for a move, both the old and new spans.
    static func verify(
        before: String,
        after: String,
        expectation: Expectation,
        allowedLines: Set<Int>
    ) -> [Finding] {
        guard before != after else { return [] }
        let beforeLines = before.components(separatedBy: "\n")
        let afterLines = after.components(separatedBy: "\n")
        var findings: [Finding] = []

        if !expectation.mayChangeLineCount, beforeLines.count != afterLines.count {
            findings.append(Finding(
                kind: .unexpectedLineCountChange(
                    before: beforeLines.count, after: afterLines.count
                ),
                message: "The \(expectation.label) edit changed the number of lines."
            ))
        }

        // Content-based, so a rewrite is caught whether the file grew, shrank or
        // stayed the same length: comparing line numbers pairwise missed a
        // regenerating writer that also shortened the file.
        let afterSet = Set(afterLines)
        let allowedContent = Set(allowedLines.compactMap { line -> String? in
            guard line >= 1, line <= beforeLines.count else { return nil }
            return beforeLines[line - 1]
        })
        let outsideBefore = beforeLines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !allowedContent.contains($0) }
        let unexpectedlyVanished = outsideBefore.filter { !afterSet.contains($0) }

        // A rewrite is not "many lines changed" — an edit is allowed to change
        // its own block completely. It is "most of what the edit had no business
        // touching is gone". Stated as a ratio rather than a line count so it
        // holds for a ten-line file as well as a thousand-line one; two lines is
        // the floor, because a single stray line is an outside-block edit, not a
        // regenerated file.
        if unexpectedlyVanished.count >= 2,
           unexpectedlyVanished.count * 2 >= outsideBefore.count {
            findings.append(Finding(
                kind: .wholeFileRewritten(
                    changedLines: unexpectedlyVanished.count, totalLines: beforeLines.count
                ),
                message: "Most of the file was rewritten: outside the block "
                    + "\(unexpectedlyVanished.count) of \(outsideBefore.count) lines disappeared."
            ))
        }

        if expectation.mayChangeLineCount {
            // A move or delete shifts every following line, so line numbers say
            // nothing; only content that disappeared from outside the block does.
            if !unexpectedlyVanished.isEmpty {
                findings.append(Finding(
                    kind: .changedOutsideBlock(lines: []),
                    message: "\(unexpectedlyVanished.count) lines changed outside the task block."
                ))
            }
            return findings
        }

        var changed: [Int] = []
        for index in 0..<min(beforeLines.count, afterLines.count)
        where beforeLines[index] != afterLines[index] {
            changed.append(index + 1)
        }
        let outside = changed.filter { !allowedLines.contains($0) }
        if !outside.isEmpty {
            findings.append(Finding(
                kind: .changedOutsideBlock(lines: outside),
                message: "Lines changed outside the task block: "
                    + outside.prefix(5).map(String.init).joined(separator: ", ")
            ))
        }
        return findings
    }

    /// The lines a task's block occupies, for `verify`.
    static func allowedLines(for task: ProjectTask) -> Set<Int> {
        Set(task.blockRange.startLine...task.blockRange.endLine)
    }
}
