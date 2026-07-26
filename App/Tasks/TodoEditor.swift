import Foundation

/// Edits a `TODO.md` by replacing byte ranges, never by regenerating the file.
///
/// Every edit is expressed as one or more `Patch`es against ranges the parser
/// produced, so anything outside those ranges — headings, blank lines,
/// indentation, comments, code fences, line endings, the final-newline choice,
/// the encoding — comes out exactly as it went in.
enum TodoEditor {
    /// One byte-range replacement.
    struct Patch: Equatable {
        var range: TaskSourceRange
        var replacement: String
        /// Shown in the diff, so a user sees what an edit will do.
        var summary: String
    }

    enum EditError: LocalizedError, Equatable {
        case unknownTask(String)
        case staleFile(path: String)
        case rangeOutOfBounds
        case overlappingPatches
        case conflict(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownTask(let id):
                "Task not found: \(id)"
            case .staleFile(let path):
                "\(path) changed outside Uncoil."
            case .rangeOutOfBounds:
                "The patch range falls outside the file."
            case .overlappingPatches:
                "Overlapping patch ranges."
            case .conflict(let detail):
                "Clash: \(detail)"
            case .writeFailed(let detail):
                "The file could not be written: \(detail)"
            }
        }
    }

    /// What a write attempt did.
    enum WriteOutcome: Equatable {
        case written(newHash: String)
        /// The file moved on and the edit was recomputed against it.
        case recomputed(newHash: String)
        /// The file moved on in the very block being edited: the user decides.
        case conflict(detail: String)

        var didWrite: Bool {
            switch self {
            case .written, .recomputed: true
            case .conflict: false
            }
        }
    }

    // MARK: - Building patches

    /// Toggling touches only the three bytes of `[ ]`, so the marker, indent,
    /// text and everything after stay literally untouched.
    static func togglePatch(for task: ProjectTask) -> Patch {
        let character = task.checkbox.toggledCharacter()
        return Patch(
            range: task.checkbox.markerRange,
            replacement: "[\(character)]",
            summary: task.isDone
                ? "\(task.text): clearing the done marker"
                : "\(task.text): marking it done"
        )
    }

    /// Renaming replaces only the task's own text, leaving the marker, checkbox
    /// and any continuation lines alone.
    static func renamePatch(for task: ProjectTask, to newText: String) -> Patch? {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.text else { return nil }
        // The text starts right after "[x] " on the task's own line.
        let textStart = task.checkbox.markerRange.endByte + 1
        let lineEnd = endOfContent(of: task.lineRange, in: task.rawBlock, taskStart: task.blockRange.startByte)
        return Patch(
            range: TaskSourceRange(
                startByte: textStart,
                endByte: lineEnd,
                startLine: task.lineRange.startLine,
                endLine: task.lineRange.startLine,
                startColumn: task.checkbox.markerRange.startColumn + 4
            ),
            replacement: trimmed,
            summary: "\(task.text) → \(trimmed)"
        )
    }

    /// Editing the description replaces the continuation lines only; the task's
    /// own line is not rewritten.
    static func descriptionPatch(for task: ProjectTask, to newBody: String) -> Patch? {
        guard task.blockRange.endByte > task.lineRange.endByte else {
            // No continuation yet: insert one, indented to sit inside the block.
            let body = normalizedBody(newBody, indent: task.checkbox.indent)
            guard !body.isEmpty else { return nil }
            return Patch(
                range: TaskSourceRange(
                    startByte: task.lineRange.endByte,
                    endByte: task.lineRange.endByte,
                    startLine: task.lineRange.endLine,
                    endLine: task.lineRange.endLine,
                    startColumn: 1
                ),
                replacement: body,
                summary: "\(task.text): adding a description"
            )
        }
        let body = normalizedBody(newBody, indent: task.checkbox.indent)
        return Patch(
            range: TaskSourceRange(
                startByte: task.lineRange.endByte,
                endByte: task.blockRange.endByte,
                startLine: task.lineRange.endLine + 1,
                endLine: task.blockRange.endLine,
                startColumn: 1
            ),
            replacement: body,
            summary: "\(task.text): updating the description"
        )
    }

    /// Moving cuts the task's whole raw block — its children and description
    /// included, since they live inside the same range — and re-inserts it under
    /// another heading.
    static func movePatches(
        task: ProjectTask,
        to headingPath: [String],
        in document: TaskDocument
    ) throws -> [Patch] {
        guard document.task(id: task.id) != nil else {
            throw EditError.unknownTask(task.id)
        }
        let block = blockWithDescendants(of: task, in: document)
        guard let insertion = insertionPoint(forHeading: headingPath, in: document) else {
            throw EditError.conflict("target heading not found: \(headingPath.joined(separator: " › "))")
        }
        guard !block.range.overlaps(insertion.range) else {
            throw EditError.conflict("the task is already under this heading")
        }

        var moved = block.text
        if !moved.hasSuffix("\n") { moved += "\n" }

        let cut = Patch(
            range: block.range,
            replacement: "",
            summary: "\(task.text): removing it from its old position"
        )
        let paste = Patch(
            range: insertion.range,
            replacement: separator(before: insertion.range.startByte, in: document.raw) + moved,
            summary: "\(task.text) → \(headingPath.joined(separator: " › "))"
        )
        return [cut, paste]
    }

    /// A brand-new task under a heading (or at the file's end for the root),
    /// written the way an agent would write it: the same indent and list marker
    /// as the sibling above it, `- [ ]` when it is the first one there.
    ///
    /// An ordered sibling gets the next number rather than a copy of the same
    /// one, so `3.` is followed by `4.` — Markdown would render a duplicate
    /// fine, but the file is the user's and it should read right raw.
    static func insertTaskPatch(
        text: String,
        under headingPath: [String],
        in document: TaskDocument
    ) throws -> Patch {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else {
            throw EditError.conflict("the task's text cannot be empty")
        }
        guard let insertion = insertionPoint(forHeading: headingPath, in: document) else {
            throw EditError.conflict(
                "target heading not found: \(headingPath.joined(separator: " › "))"
            )
        }
        let sibling = document.tasks(under: headingPath).last
        let indent = sibling?.checkbox.indent ?? ""
        let marker = sibling.map { nextListMarker(after: $0.checkbox.listMarker) } ?? "-"
        var line = "\(indent)\(marker) [ ] \(title)\n"
        if insertion.isEmptyHeading {
            // The first task directly after a heading line reads better with a
            // blank line between them, which is also how agents write it.
            line = "\n" + line
        }
        return Patch(
            range: insertion.range,
            replacement: separator(before: insertion.range.startByte, in: document.raw) + line,
            summary: "new task: \(title)"
        )
    }

    /// `-`/`*`/`+` stay as they are; `3.` → `4.`, `7)` → `8)`.
    static func nextListMarker(after marker: String) -> String {
        guard let last = marker.last, last == "." || last == ")" else { return marker }
        guard let number = Int(marker.dropLast()) else { return marker }
        return "\(number + 1)\(last)"
    }

    /// The newline a paste at `byte` has to bring with it.
    ///
    /// A file whose last line has no trailing newline is common, and pasting a
    /// block at its end without this would glue the block onto that line —
    /// silently destroying it.
    static func separator(before byte: Int, in raw: String) -> String {
        guard byte > 0 else { return "" }
        let bytes = Array(raw.utf8)
        guard byte <= bytes.count, bytes[byte - 1] != 0x0A else { return "" }
        return "\n"
    }

    // MARK: - Applying

    /// Applies patches to a source string. Pure: the caller decides what to do
    /// with the result.
    static func apply(_ patches: [Patch], to raw: String) throws -> String {
        guard !patches.isEmpty else { return raw }
        let bytes = Array(raw.utf8)
        let sorted = patches.sorted { $0.range.startByte < $1.range.startByte }
        for (index, patch) in sorted.enumerated() {
            guard patch.range.startByte >= 0, patch.range.endByte <= bytes.count,
                  patch.range.startByte <= patch.range.endByte else {
                throw EditError.rangeOutOfBounds
            }
            if index > 0, sorted[index - 1].range.endByte > patch.range.startByte {
                throw EditError.overlappingPatches
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0
        for patch in sorted {
            output.append(contentsOf: bytes[cursor..<patch.range.startByte])
            output.append(contentsOf: Array(patch.replacement.utf8))
            cursor = patch.range.endByte
        }
        output.append(contentsOf: bytes[cursor...])
        return String(decoding: output, as: UTF8.self)
    }

    /// Human-readable diff of what the patches will change.
    static func diff(_ patches: [Patch], in raw: String) -> String {
        let bytes = Array(raw.utf8)
        return patches
            .sorted { $0.range.startByte < $1.range.startByte }
            .map { patch in
                let before = patch.range.startByte < patch.range.endByte
                    ? String(decoding: bytes[patch.range.startByte..<patch.range.endByte], as: UTF8.self)
                    : ""
                var lines = ["@@ line \(patch.range.startLine) @@ \(patch.summary)"]
                lines.append(contentsOf: before
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .map { "-\($0)" })
                lines.append(contentsOf: patch.replacement
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .map { "+\($0)" })
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    // MARK: - Safe write

    /// Reads, verifies, writes atomically — and refuses to clobber a file that
    /// changed under us.
    ///
    /// When the file moved on, the edit is rebuilt against the current content
    /// via `rebuild`. If the change landed in the very block being edited, the
    /// result is a conflict for the user to settle rather than a guess.
    @discardableResult
    static func write(
        patches: [Patch],
        to path: String,
        expectedHash: String,
        rebuild: ((TaskDocument) -> [Patch]?)? = nil,
        backupDirectory: URL? = nil
    ) throws -> WriteOutcome {
        let currentRaw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let currentDocument = TodoParser.parse(currentRaw, path: path)

        var effectivePatches = patches
        var recomputed = false
        if currentDocument.contentHash != expectedHash {
            guard let rebuild, let rebuilt = rebuild(currentDocument) else {
                throw EditError.staleFile(path: path)
            }
            guard !rebuilt.isEmpty else {
                return .conflict(detail: "The edited task block changed in the file.")
            }
            effectivePatches = rebuilt
            recomputed = true
        }

        let updated = try apply(effectivePatches, to: currentRaw)
        guard updated != currentRaw else {
            return .written(newHash: currentDocument.contentHash)
        }

        if let backupDirectory {
            try? FileManager.default.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true
            )
            let name = "\(URL(fileURLWithPath: path).lastPathComponent).bak"
            try? Data(currentRaw.utf8).write(
                to: backupDirectory.appendingPathComponent(name), options: .atomic
            )
        }

        // Atomic replacement: a failed write leaves the original in place.
        let url = URL(fileURLWithPath: path)
        do {
            try Data(updated.utf8).write(to: url, options: .atomic)
        } catch {
            throw EditError.writeFailed(error.localizedDescription)
        }
        let newHash = TodoParser.parse(updated, path: path).contentHash
        return recomputed ? .recomputed(newHash: newHash) : .written(newHash: newHash)
    }

    /// Rebuilds a task edit against a changed document by re-finding the task.
    /// Returns nil when the task is gone, and an empty array when it is still
    /// there but its block changed — which is the case a user must settle.
    static func rebuilder(
        for task: ProjectTask,
        makePatches: @escaping (ProjectTask) -> [Patch]
    ) -> (TaskDocument) -> [Patch]? {
        { document in
            switch TaskRelinker.resolve(task.fingerprint, in: document.tasks) {
            case .exact(let id):
                // Same block: the change was elsewhere in the file, so the edit
                // still applies verbatim.
                guard let current = document.task(id: id) else { return nil }
                return makePatches(current)
            case .positional, .similar:
                // The block itself moved on; do not guess what the user meant.
                return []
            case .ambiguous, .missing:
                return nil
            }
        }
    }

    // MARK: - Helpers

    /// End of the task's own text on its first line, excluding the newline, so a
    /// rename never eats the line ending.
    private static func endOfContent(
        of lineRange: TaskSourceRange,
        in rawBlock: String,
        taskStart: Int
    ) -> Int {
        let bytes = Array(rawBlock.utf8)
        let lineLength = lineRange.endByte - lineRange.startByte
        guard lineLength > 0, lineLength <= bytes.count else { return lineRange.endByte }
        var end = lineLength
        while end > 0, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D {
            end -= 1
        }
        return lineRange.startByte + end
    }

    /// Indents a description body to sit inside the task's block.
    private static func normalizedBody(_ body: String, indent: String) -> String {
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return lines.map { "\(indent)  \($0)" }.joined(separator: "\n") + "\n"
    }

    /// A task's block plus every nested task under it, as one contiguous range —
    /// which is what "move the task with its children" means in a file.
    static func blockWithDescendants(
        of task: ProjectTask,
        in document: TaskDocument
    ) -> (range: TaskSourceRange, text: String) {
        var endByte = task.blockRange.endByte
        var endLine = task.blockRange.endLine
        for candidate in document.tasks
        where candidate.blockRange.startByte >= task.blockRange.endByte
            && candidate.depth > task.depth {
            // Stop at the first task that is not deeper than this one.
            guard candidate.blockRange.startByte <= endByte
                || isDescendant(candidate, of: task, in: document) else { break }
            endByte = max(endByte, candidate.blockRange.endByte)
            endLine = max(endLine, candidate.blockRange.endLine)
        }
        let bytes = Array(document.raw.utf8)
        let range = TaskSourceRange(
            startByte: task.blockRange.startByte,
            endByte: min(endByte, bytes.count),
            startLine: task.blockRange.startLine,
            endLine: endLine,
            startColumn: task.blockRange.startColumn
        )
        return (
            range,
            String(decoding: bytes[range.startByte..<range.endByte], as: UTF8.self)
        )
    }

    private static func isDescendant(
        _ candidate: ProjectTask,
        of task: ProjectTask,
        in document: TaskDocument
    ) -> Bool {
        var current: ProjectTask? = candidate
        while let parentID = current?.parentID {
            if parentID == task.id { return true }
            current = document.task(id: parentID)
        }
        return false
    }

    /// Where a new task block goes under a heading: after the heading's last
    /// existing task, or immediately after the heading line.
    private static func insertionPoint(
        forHeading headingPath: [String],
        in document: TaskDocument
    ) -> (range: TaskSourceRange, isEmptyHeading: Bool)? {
        let existing = document.tasks(under: headingPath)
        if let last = existing.last {
            let point = TaskSourceRange(
                startByte: last.blockRange.endByte,
                endByte: last.blockRange.endByte,
                startLine: last.blockRange.endLine,
                endLine: last.blockRange.endLine,
                startColumn: 1
            )
            return (point, false)
        }
        guard let heading = document.headings.last(where: { $0.text == headingPath.last }) else {
            return headingPath.isEmpty
                ? (
                    TaskSourceRange(
                        startByte: document.raw.utf8.count,
                        endByte: document.raw.utf8.count,
                        startLine: max(1, document.headings.last?.range.endLine ?? 1),
                        endLine: max(1, document.headings.last?.range.endLine ?? 1),
                        startColumn: 1
                    ),
                    true
                )
                : nil
        }
        let point = TaskSourceRange(
            startByte: heading.range.endByte,
            endByte: heading.range.endByte,
            startLine: heading.range.endLine,
            endLine: heading.range.endLine,
            startColumn: 1
        )
        return (point, true)
    }
}
