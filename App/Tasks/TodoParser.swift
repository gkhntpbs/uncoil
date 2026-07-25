import CryptoKit
import Foundation

/// A parsed `TODO.md`. Blocks cover the whole file in order, so rendering is
/// simply "put the source back" — the parser can never lose or reformat anything
/// it did not understand.
struct TaskDocument: Equatable {
    var path: String
    /// The file exactly as it was read.
    var raw: String
    var blocks: [ProjectTaskBlock]
    var tasks: [ProjectTask]
    var headings: [ProjectTaskHeading]

    var contentHash: String {
        SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var openTasks: [ProjectTask] { tasks.filter { !$0.isDone } }

    func task(id: String) -> ProjectTask? { tasks.first { $0.id == id } }

    /// Reassembles the file from its blocks. Byte-identical to `raw` for an
    /// unmodified document — the round-trip guarantee everything else rests on.
    func render() -> String {
        let bytes = Array(raw.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for block in blocks.sorted(by: { $0.range.startByte < $1.range.startByte }) {
            output.append(contentsOf: bytes[block.range.startByte..<block.range.endByte])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Tasks directly under a heading chain, in file order.
    func tasks(under headingPath: [String]) -> [ProjectTask] {
        tasks.filter { $0.headingPath == headingPath }
    }
}

/// Lossless `TODO.md` parser.
///
/// It recognises checkbox tasks, headings and their nesting, and treats
/// everything else — prose, fenced code, tables, blockquotes, HTML comments — as
/// passthrough it must not touch. A checkbox inside a fenced code block is text,
/// not a task.
enum TodoParser {
    /// A source line with its byte range, so offsets never have to be recomputed.
    private struct Line {
        var text: String
        var startByte: Int
        /// Includes the trailing newline when the line had one.
        var endByte: Int
        var number: Int
        var hasNewline: Bool
    }

    static func parse(_ raw: String, path: String) -> TaskDocument {
        let lines = split(raw)
        var blocks: [ProjectTaskBlock] = []
        var headings: [ProjectTaskHeading] = []
        var tasks: [ProjectTask] = []

        var headingStack: [(level: Int, text: String)] = []
        var orderCounters: [String: Int] = [:]
        /// Open nested tasks: (indent width, task index in `tasks`).
        var openParents: [(indent: Int, index: Int)] = []
        var passthroughStart: Int?
        var index = 0

        func flushPassthrough(upTo endByte: Int) {
            guard let start = passthroughStart, endByte > start else {
                passthroughStart = nil
                return
            }
            blocks.append(ProjectTaskBlock(
                kind: .passthrough,
                range: range(from: start, to: endByte, in: lines)
            ))
            passthroughStart = nil
        }

        func emitHeading(_ heading: (level: Int, text: String), from startByte: Int, to endByte: Int) {
            let headingRange = range(from: startByte, to: endByte, in: lines)
            headings.append(ProjectTaskHeading(
                level: heading.level, text: heading.text, range: headingRange
            ))
            blocks.append(ProjectTaskBlock(kind: .heading, range: headingRange))
            while let last = headingStack.last, last.level >= heading.level {
                headingStack.removeLast()
            }
            headingStack.append((heading.level, heading.text))
            // Order and nesting are scoped to a heading.
            openParents.removeAll()
        }

        // YAML frontmatter is delimited by the same `---` a setext heading uses,
        // so it is consumed up front rather than guessed at line by line.
        if let end = frontmatterEnd(in: lines) {
            passthroughStart = 0
            index = end
        }

        while index < lines.count {
            let line = lines[index]

            // A fence opens a region the parser must not interpret at all.
            if let fence = fenceToken(line.text) {
                if passthroughStart == nil { passthroughStart = line.startByte }
                index += 1
                while index < lines.count {
                    let inner = lines[index]
                    index += 1
                    if closesFence(inner.text, token: fence) { break }
                }
                continue
            }

            if let heading = headingComponents(line.text) {
                flushPassthrough(upTo: line.startByte)
                emitHeading(heading, from: line.startByte, to: line.endByte)
                index += 1
                continue
            }

            // Setext: a plain paragraph line underlined with `===` or `---`. The
            // heading block covers both lines so the underline is never orphaned.
            if index + 1 < lines.count,
               let level = setextLevel(lines[index + 1].text),
               canBeSetextTitle(line.text) {
                flushPassthrough(upTo: line.startByte)
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                emitHeading(
                    (level: level, text: text),
                    from: line.startByte,
                    to: lines[index + 1].endByte
                )
                index += 2
                continue
            }

            guard let checkbox = checkboxComponents(line.text) else {
                if passthroughStart == nil { passthroughStart = line.startByte }
                index += 1
                continue
            }

            flushPassthrough(upTo: line.startByte)

            // The block runs to the end of this task's own continuation.
            let blockEnd = endOfTaskBlock(startingAt: index, indent: checkbox.indentWidth, in: lines)
            let blockRange = range(from: line.startByte, to: blockEnd.endByte, in: lines)
            let lineRange = range(from: line.startByte, to: line.endByte, in: lines)
            let rawBlock = substring(of: raw, range: blockRange)

            let headingPath = headingStack.map(\.text)
            let headingKey = headingPath.joined(separator: "\u{1}")
            let order = orderCounters[headingKey] ?? 0
            orderCounters[headingKey] = order + 1

            while let last = openParents.last, last.indent >= checkbox.indentWidth {
                openParents.removeLast()
            }
            let parentIndex = openParents.last?.index

            let markerRange = range(
                from: line.startByte + checkbox.markerByteOffset,
                to: line.startByte + checkbox.markerByteOffset + checkbox.markerByteLength,
                in: lines
            )

            let fingerprint = TaskFingerprint(
                filePath: path,
                headingPath: headingPath,
                normalizedText: TaskFingerprint.normalize(checkbox.text),
                rawHash: TaskFingerprint.hash(rawBlock),
                previousText: tasks.last.map { TaskFingerprint.normalize($0.text) },
                nextText: nil,
                orderUnderHeading: order
            )

            let task = ProjectTask(
                id: fingerprint.strongKey,
                sourcePath: path,
                checkbox: ProjectTaskCheckboxState(
                    mark: checkbox.isDone ? .done : .open,
                    listMarker: checkbox.listMarker,
                    markerCharacter: checkbox.markerCharacter,
                    indent: checkbox.indent,
                    markerRange: markerRange
                ),
                text: checkbox.text,
                blockRange: blockRange,
                lineRange: lineRange,
                rawBlock: rawBlock,
                headingPath: headingPath,
                depth: openParents.count,
                parentID: parentIndex.map { tasks[$0].id },
                childIDs: [],
                orderUnderHeading: order,
                fingerprint: fingerprint
            )
            tasks.append(task)
            let taskIndex = tasks.count - 1
            if let parentIndex {
                tasks[parentIndex].childIDs.append(task.id)
            }
            openParents.append((checkbox.indentWidth, taskIndex))

            blocks.append(ProjectTaskBlock(
                kind: .task, range: blockRange, taskID: task.id
            ))
            index = blockEnd.nextIndex
        }

        flushPassthrough(upTo: Array(raw.utf8).count)

        // `nextText` needs the following task, so it is filled in afterwards.
        for taskIndex in tasks.indices.dropLast() {
            tasks[taskIndex].fingerprint.nextText =
                TaskFingerprint.normalize(tasks[taskIndex + 1].text)
        }

        return TaskDocument(
            path: path, raw: raw, blocks: blocks, tasks: tasks, headings: headings
        )
    }

    // MARK: - Line scanning

    /// Splits on UTF-8 bytes, not Characters.
    ///
    /// Swift treats `\r\n` as a single Character, so a Character-based scan never
    /// sees a newline in a CRLF file and collapses the whole thing into one line.
    /// Splitting on the `\n` byte keeps any `\r` inside the line's own text, which
    /// is also what preserves the file's line-ending style through an edit.
    private static func split(_ raw: String) -> [Line] {
        let bytes = Array(raw.utf8)
        var lines: [Line] = []
        var start = 0
        var number = 1
        for index in bytes.indices where bytes[index] == 0x0A {
            lines.append(Line(
                text: String(decoding: bytes[start..<index], as: UTF8.self),
                startByte: start,
                endByte: index + 1,
                number: number,
                hasNewline: true
            ))
            number += 1
            start = index + 1
        }
        if start < bytes.count {
            lines.append(Line(
                text: String(decoding: bytes[start..<bytes.count], as: UTF8.self),
                startByte: start,
                endByte: bytes.count,
                number: number,
                hasNewline: false
            ))
        }
        return lines
    }

    private static func range(from startByte: Int, to endByte: Int, in lines: [Line]) -> TaskSourceRange {
        let startLine = lines.last { $0.startByte <= startByte }?.number ?? 1
        let endLine = lines.last { $0.startByte < max(endByte, startByte + 1) }?.number ?? startLine
        let lineStart = lines.first { $0.number == startLine }?.startByte ?? startByte
        return TaskSourceRange(
            startByte: startByte,
            endByte: endByte,
            startLine: startLine,
            endLine: endLine,
            startColumn: startByte - lineStart + 1
        )
    }

    private static func substring(of raw: String, range: TaskSourceRange) -> String {
        let bytes = Array(raw.utf8)
        guard range.startByte >= 0, range.endByte <= bytes.count,
              range.startByte < range.endByte else { return "" }
        return String(decoding: bytes[range.startByte..<range.endByte], as: UTF8.self)
    }

    /// Where a task's block ends: its own line plus any continuation that is
    /// indented past the marker, including a fenced block that belongs to it.
    /// Trailing blank lines are left to passthrough so blank-line style survives.
    private static func endOfTaskBlock(
        startingAt index: Int,
        indent: Int,
        in lines: [Line]
    ) -> (endByte: Int, nextIndex: Int) {
        var endByte = lines[index].endByte
        var nextIndex = index + 1
        var cursor = index + 1
        var pendingBlank = false

        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                // A blank line only stays inside the block if indented content
                // follows it.
                pendingBlank = true
                cursor += 1
                continue
            }
            // A nested task is its own block, not continuation.
            if checkboxComponents(line.text) != nil { break }
            if headingComponents(line.text) != nil { break }
            let lineIndent = indentWidth(line.text)
            guard lineIndent > indent else { break }

            if let fence = fenceToken(line.text) {
                cursor += 1
                while cursor < lines.count {
                    let inner = lines[cursor]
                    cursor += 1
                    endByte = inner.endByte
                    if closesFence(inner.text, token: fence) { break }
                }
                nextIndex = cursor
                pendingBlank = false
                continue
            }

            endByte = line.endByte
            cursor += 1
            nextIndex = cursor
            pendingBlank = false
        }
        _ = pendingBlank
        return (endByte, nextIndex)
    }

    // MARK: - Token recognition

    struct CheckboxComponents: Equatable {
        var indent: String
        var indentWidth: Int
        var listMarker: String
        var markerCharacter: String
        var isDone: Bool
        var text: String
        /// Byte offset of `[` within the line.
        var markerByteOffset: Int
        /// Byte length of `[x]`.
        var markerByteLength: Int
    }

    /// Characters a checkbox is allowed to hold.
    ///
    /// Beyond the canonical space/`x`, the marks people actually type are `-`
    /// (dropped), and `~` or `/` (in progress). They used to be unreadable, which
    /// meant those lines vanished from the app entirely — worse than showing them
    /// with an approximate state.
    static let checkboxMarkCharacters: Set<Character> = [" ", "x", "X", "-", "~", "/"]

    /// Marks that count as "not open work any more". A dropped task (`-`) is
    /// settled just like a finished one; `~` and `/` are work in flight and stay
    /// open so they keep showing up on the board.
    static let doneMarkCharacters: Set<Character> = ["x", "X", "-"]

    /// `- [ ] text`, `* [x] text`, `+ [X] text`, `1. [ ] text`, `2) [~] text`,
    /// `> - [ ] text`, at any indent and with tabs.
    static func checkboxComponents(_ line: String) -> CheckboxComponents? {
        // A quoted list is still a list. The quote markers are kept inside
        // `indent` so every byte offset below stays counted from the line start.
        let indent = String(line.prefix { $0 == " " || $0 == "\t" || $0 == ">" })
        var rest = Substring(line.dropFirst(indent.count))
        guard let listMarker = listMarkerToken(rest) else { return nil }
        rest = rest.dropFirst(listMarker.count)
        // At least one space is required between the marker and the bracket
        // group in the styles we accept; more is fine.
        let spacesCount = rest.prefix { $0 == " " }.count
        guard spacesCount >= 1 else { return nil }
        rest = rest.dropFirst(spacesCount)
        guard rest.hasPrefix("[") else { return nil }
        let afterBracket = rest.dropFirst()
        guard let markerCharacter = afterBracket.first,
              checkboxMarkCharacters.contains(markerCharacter) else {
            return nil
        }
        let afterCharacter = afterBracket.dropFirst()
        guard afterCharacter.hasPrefix("]") else { return nil }
        let text = afterCharacter.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = indent + listMarker + String(repeating: " ", count: spacesCount)
        return CheckboxComponents(
            indent: indent,
            indentWidth: indentWidth(indent),
            listMarker: listMarker,
            markerCharacter: String(markerCharacter),
            isDone: doneMarkCharacters.contains(markerCharacter),
            text: text,
            markerByteOffset: prefix.utf8.count,
            markerByteLength: 3
        )
    }

    /// The list marker at the start of `rest`: a bullet, or an ordered-list
    /// number with its `.`/`)` delimiter.
    private static func listMarkerToken(_ rest: Substring) -> String? {
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) { return String(first) }
        guard first.isNumber else { return nil }
        let digits = rest.prefix { $0.isNumber }
        // CommonMark caps ordered-list numbers at nine digits; past that it is
        // prose that happens to start with a number.
        guard digits.count <= 9,
              let delimiter = rest.dropFirst(digits.count).first,
              delimiter == "." || delimiter == ")" else { return nil }
        return String(digits) + String(delimiter)
    }

    static func headingComponents(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // `#hashtag` is not a heading.
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The heading level a `===` / `---` underline gives the line above it.
    ///
    /// A single `-` is a list marker, so a dash underline needs at least two
    /// characters before it can mean anything else.
    static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard indentWidth(line) < 4, !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Whether a line may be underlined into a setext heading.
    ///
    /// Only a plain paragraph line qualifies. That restriction is the whole
    /// reason a `---` after a blank line stays a thematic break instead of
    /// turning a file's separators into headings.
    static func canBeSetextTitle(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, indentWidth(line) < 4 else { return false }
        guard headingComponents(line) == nil,
              checkboxComponents(line) == nil,
              fenceToken(line) == nil,
              setextLevel(line) == nil else { return false }
        // Lists, quotes, tables and HTML are structure of their own.
        guard let first = trimmed.first, !">|<".contains(first) else { return false }
        return listMarkerToken(Substring(trimmed)) == nil
    }

    /// The line index just past a leading YAML frontmatter block, if there is
    /// one. Unterminated frontmatter is not frontmatter — the file is just prose
    /// that starts with a rule.
    private static func frontmatterEnd(in lines: [Line]) -> Int? {
        guard let first = lines.first,
              first.text.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }
        for index in 1..<lines.count
        where lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            return index + 1
        }
        return nil
    }

    /// The fence token (``` or ~~~ with its exact length), or nil.
    static func fenceToken(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    static func closesFence(_ line: String, token: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = token.first else { return false }
        let run = trimmed.prefix { $0 == first }
        return run.count >= token.count && trimmed.dropFirst(run.count).isEmpty
    }

    /// Tab counts as four columns, matching how the lists are written.
    ///
    /// Blockquote markers deliberately add no width: a quoted list is read as a
    /// flat list at the top level, which keeps an unquoted `> …` line from being
    /// swallowed as the previous task's continuation.
    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }
}
