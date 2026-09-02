import Foundation

/// Just enough YAML for Hermes' `mcp_servers:` mapping in `~/.hermes/config.yaml`.
///
/// Deliberately NOT a general YAML implementation, for the same reason
/// `CodexTOML` is not a general TOML one: the file is the user's, not Uncoil's.
/// Hermes' own `cli-config.yaml.example` is fourteen hundred lines of commented
/// documentation that people copy from and edit in place, and a round-trip
/// through a real parser would come back alphabetised, re-quoted and stripped of
/// every comment that explained why a setting was there. So this reads the one
/// mapping Uncoil manages, rewrites only the lines that mapping occupies, and
/// leaves every other byte exactly as it was found.
///
/// Anything it does not model is kept verbatim rather than dropped: a value
/// shape this reader has no case for still survives a rewrite of its neighbour.
enum HermesYAML {
    static let serversKey = "mcp_servers"

    /// One entry under `mcp_servers:`, with the line span it occupies so a
    /// rewrite can be surgical.
    struct ServerBlock: Equatable {
        var name: String
        var values: [String: Value]
        var environment: [String: String]
        /// Inclusive line indices covered by the entry, including its nested
        /// `env:` mapping and any block sequence under `args:`.
        var lineRange: ClosedRange<Int>
        /// Column the entry's own `name:` key starts at, so an inserted
        /// sibling lines up with the ones already there.
        var indent: Int
    }

    enum Value: Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case array([String])
        /// A shape this reader does not model — an anchor, a nested mapping,
        /// a multi-line block scalar. Kept as written so a rewrite puts it back
        /// untouched rather than guessing at it.
        case verbatim(String)

        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var intValue: Int? {
            if case .integer(let value) = self { return value }
            return nil
        }

        var boolValue: Bool? {
            if case .boolean(let value) = self { return value }
            return nil
        }

        var arrayValue: [String]? {
            if case .array(let value) = self { return value }
            return nil
        }
    }

    // MARK: - Reading

    /// The line span of the top-level `mcp_servers:` mapping, and the column
    /// its entries are indented to.
    ///
    /// `entryIndent` is read from the first entry rather than assumed to be
    /// two: a file indented with four spaces is perfectly ordinary YAML, and
    /// appending a two-space entry into it would silently move the new server
    /// out of the mapping.
    struct Section: Equatable {
        var headerLine: Int
        /// Inclusive span of the entries below the header. Empty when the
        /// mapping exists with nothing under it.
        var bodyRange: ClosedRange<Int>?
        var entryIndent: Int
    }

    /// `mcp_servers:` is one top-level block; `hooks:` is another. Both are
    /// found the same way, so the lookup takes the key rather than assuming it.
    static func section(_ key: String, in text: String) -> Section? {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { isKeyLine($0, key: key, atIndent: 0) })
        else { return nil }

        var last: Int?
        var entryIndent: Int?
        var index = header + 1
        while index < lines.count {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let indent = indentation(of: line)
            // Back at column zero: the mapping ended at the previous entry.
            if indent == 0 { break }
            if entryIndent == nil { entryIndent = indent }
            last = index
            index += 1
        }
        return Section(
            headerLine: header,
            bodyRange: last.map { (header + 1)...$0 },
            entryIndent: entryIndent ?? 2
        )
    }

    static func serversSection(in text: String) -> Section? {
        section(serversKey, in: text)
    }

    static func serverBlocks(in text: String) -> [ServerBlock] {
        guard let section = serversSection(in: text), let body = section.bodyRange else { return [] }
        let lines = text.components(separatedBy: "\n")
        var blocks: [ServerBlock] = []

        var index = body.lowerBound
        while index <= body.upperBound {
            let line = lines[index]
            if isBlankOrComment(line) || indentation(of: line) != section.entryIndent {
                index += 1
                continue
            }
            guard let name = mappingKey(line) else {
                index += 1
                continue
            }
            // Everything indented deeper than the entry key belongs to it,
            // blank lines and comments included, up to the next sibling.
            var end = index
            var scan = index + 1
            while scan <= body.upperBound {
                let candidate = lines[scan]
                if isBlankOrComment(candidate) {
                    scan += 1
                    continue
                }
                guard indentation(of: candidate) > section.entryIndent else { break }
                end = scan
                scan += 1
            }
            blocks.append(
                parseEntry(name: name, lines: lines, range: index...end, indent: section.entryIndent)
            )
            index = scan
        }
        return blocks
    }

    /// Reads one entry's own keys. `args:` is accepted both as a flow sequence
    /// on the key line and as a block sequence beneath it, because Hermes'
    /// documentation shows the first and `hermes mcp add` writes the second.
    private static func parseEntry(
        name: String,
        lines: [String],
        range: ClosedRange<Int>,
        indent: Int
    ) -> ServerBlock {
        var values: [String: Value] = [:]
        var environment: [String: String] = [:]
        var index = range.lowerBound + 1

        while index <= range.upperBound {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let lineIndent = indentation(of: line)
            // Only the entry's own children; anything deeper was consumed by
            // whichever child claimed it.
            guard lineIndent > indent, let pair = keyValue(line) else {
                index += 1
                continue
            }
            let childIndent = lineIndent

            if pair.value == nil {
                // A key with nothing after the colon: a nested collection.
                let (nested, next) = collectNested(
                    lines: lines, after: index, limit: range.upperBound, parentIndent: childIndent
                )
                switch pair.key {
                case "env":
                    for line in nested {
                        if let entry = keyValue(line), let value = entry.value {
                            environment[entry.key] = value.stringValue ?? rendered(value)
                        }
                    }
                case "args":
                    let items = nested.compactMap(sequenceItem)
                    values["args"] = items.isEmpty && !nested.isEmpty
                        ? .verbatim(nested.joined(separator: "\n"))
                        : .array(items)
                default:
                    values[pair.key] = .verbatim(nested.joined(separator: "\n"))
                }
                index = next
                continue
            }
            values[pair.key] = pair.value
            index += 1
        }
        return ServerBlock(
            name: name, values: values, environment: environment, lineRange: range, indent: indent
        )
    }

    /// Lines belonging to a collection opened by a bare `key:`, plus the index
    /// to resume scanning at.
    private static func collectNested(
        lines: [String],
        after keyIndex: Int,
        limit: Int,
        parentIndent: Int
    ) -> ([String], Int) {
        var collected: [String] = []
        var index = keyIndex + 1
        while index <= limit {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            guard indentation(of: line) > parentIndent else { break }
            collected.append(line)
            index += 1
        }
        return (collected, index)
    }

    static func servers(in text: String) -> [MCPServerDefinition] {
        serverBlocks(in: text).map { block in
            let split = AgentAdapterSupport.partitionEnvironment(block.environment)
            let url = block.values["url"]?.stringValue
            return MCPServerDefinition(
                id: "hermes:\(block.name)",
                name: block.name,
                transport: url == nil ? .stdio : .http,
                command: block.values["command"]?.stringValue,
                arguments: block.values["args"]?.arrayValue ?? [],
                url: url,
                environmentKeys: split.secretKeys,
                environment: split.plain,
                // Hermes treats a missing `enabled` as on; only an explicit
                // false turns a server off.
                isEnabled: block.values["enabled"]?.boolValue ?? true,
                startupTimeoutSeconds: block.values["timeout"]?.intValue
            )
        }
    }

    // MARK: - Writing

    /// Replaces, appends or removes one entry under `mcp_servers:`, leaving
    /// every other line byte-identical.
    ///
    /// `block` is rendered at whatever indent the file already uses, so this
    /// never reformats a config indented differently from Uncoil's own output.
    static func rewrite(
        _ text: String,
        name: String,
        with definition: MCPServerDefinition?
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        let section = serversSection(in: text)
        let indent = section?.entryIndent ?? 2

        if let existing = serverBlocks(in: text).first(where: { $0.name == name }) {
            // Trailing blank lines inside the span belong to whatever follows,
            // not to the entry being replaced: swallowing them would close up a
            // gap the user put there on purpose, and removing an entry would
            // eat the separator before the next one.
            var upper = existing.lineRange.upperBound
            while upper > existing.lineRange.lowerBound,
                  lines[upper].trimmingCharacters(in: .whitespaces).isEmpty {
                upper -= 1
            }
            let range = existing.lineRange.lowerBound...upper
            if let definition {
                lines.replaceSubrange(
                    range, with: render(definition, indent: indent).components(separatedBy: "\n")
                )
                return lines.joined(separator: "\n")
            }
            lines.removeSubrange(range)
            let remaining = serverBlocks(in: lines.joined(separator: "\n"))
            guard remaining.isEmpty, let header = section?.headerLine else {
                return lines.joined(separator: "\n")
            }
            // The last server is gone. `mcp_servers:` with nothing under it
            // parses as null, which Hermes already treats as "no servers" — but
            // leaving it invites the next hand-edit to add an entry at some
            // other indent, so the header goes too.
            if header < lines.count, isKeyLine(lines[header], key: serversKey, atIndent: 0) {
                lines.remove(at: header)
            }
            return lines.joined(separator: "\n")
        }

        guard let definition else { return text }
        let rendered = render(definition, indent: indent)

        guard let section else {
            // No mapping at all yet — this is also the empty-file case, which
            // is the normal one: `~/.hermes/config.yaml` is not written until
            // Hermes has something to put in it.
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            if !result.isEmpty { result += "\n" }
            return result + "\(serversKey):\n" + rendered + "\n"
        }
        // Append after the last entry, not after the header: inserting at the
        // top would put the new server above a comment written about the one
        // below it.
        let insertAt = (section.bodyRange?.upperBound).map { $0 + 1 } ?? section.headerLine + 1
        lines.insert(contentsOf: rendered.components(separatedBy: "\n"), at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Replaces, inserts or removes a whole top-level block — `hooks:` is the
    /// one this exists for, `mcp_servers:` having its own entry-level surgery.
    ///
    /// `body` is the block's indented lines without the `key:` header, or nil
    /// to remove the block entirely. Everything outside the block's own span
    /// comes back byte-identical, which is the same promise `rewrite` makes.
    static func rewriteBlock(_ text: String, key: String, body: [String]?) -> String {
        var lines = text.components(separatedBy: "\n")

        if let existing = section(key, in: text) {
            var upper = existing.bodyRange?.upperBound ?? existing.headerLine
            // Trailing blank lines belong to whatever follows, not to the block
            // being replaced.
            while upper > existing.headerLine,
                  lines[upper].trimmingCharacters(in: .whitespaces).isEmpty {
                upper -= 1
            }
            let span = existing.headerLine...upper
            if let body {
                lines.replaceSubrange(span, with: ["\(key):"] + body)
            } else {
                lines.removeSubrange(span)
            }
            return lines.joined(separator: "\n")
        }

        guard let body else { return text }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + "\(key):\n" + body.joined(separator: "\n") + "\n"
    }

    /// The raw lines of a top-level block's body, without the header. Empty
    /// when the block is absent or has nothing under it.
    static func blockBody(_ key: String, in text: String) -> [String] {
        guard let section = section(key, in: text), let body = section.bodyRange else { return [] }
        let lines = text.components(separatedBy: "\n")
        return Array(lines[body])
    }

    /// Renders one server as YAML. Secret env VALUES are never rendered; only
    /// non-secret pairs reach the file, exactly as in `CodexTOML.render`.
    static func render(_ definition: MCPServerDefinition, indent: Int = 2) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent * 2)
        var lines = ["\(pad)\(quoteKeyIfNeeded(definition.name)):"]
        switch definition.transport {
        case .stdio:
            if let command = definition.command {
                lines.append("\(inner)command: \(quote(command))")
            }
            lines.append("\(inner)args: [\(definition.arguments.map(quote).joined(separator: ", "))]")
        case .http:
            if let url = definition.url {
                lines.append("\(inner)url: \(quote(url))")
            }
        }
        if let timeout = definition.startupTimeoutSeconds {
            lines.append("\(inner)timeout: \(timeout)")
        }
        if !definition.isEnabled {
            lines.append("\(inner)enabled: false")
        }
        // A secret VALUE never reaches an agent config even if a caller put one
        // in `environment`: the launcher injects it from the Keychain instead.
        let safeEnvironment = definition.environment.filter {
            !AgentAdapterSupport.isSecretKey($0.key)
        }
        if !safeEnvironment.isEmpty {
            lines.append("\(inner)env:")
            let deepest = String(repeating: " ", count: indent * 3)
            for key in safeEnvironment.keys.sorted() {
                lines.append("\(deepest)\(quoteKeyIfNeeded(key)): \(quote(safeEnvironment[key] ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lexing helpers

    static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// True for `key:` or `key: value` at exactly `indent`, and — importantly —
    /// false for a tab-indented line, which YAML forbids as indentation.
    static func isKeyLine(_ line: String, key: String, atIndent indent: Int) -> Bool {
        guard indentation(of: line) == indent else { return false }
        guard let found = mappingKey(line) else { return false }
        return found == key
    }

    /// The key of a mapping line, or nil when the line is not one.
    static func mappingKey(_ line: String) -> String? {
        keyValue(line)?.key
    }

    /// Splits `key: value` at the first structural colon. The value is nil for
    /// a bare `key:` opening a nested collection.
    static func keyValue(_ line: String) -> (key: String, value: Value?)? {
        let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty, !stripped.hasPrefix("-"), !stripped.hasPrefix("#") else { return nil }
        guard let separator = colonIndex(in: stripped) else { return nil }
        let key = unquote(String(stripped[..<separator]).trimmingCharacters(in: .whitespaces))
        guard !key.isEmpty else { return nil }
        let raw = String(stripped[stripped.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, raw.isEmpty ? nil : value(raw))
    }

    /// The first `:` that separates a key from a value — one followed by a
    /// space or ending the line. A colon inside `http://…` or inside quotes is
    /// not one, which is why this is not `firstIndex(of: ":")`.
    static func colonIndex(in text: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inDouble {
                escaped = true
            } else if character == "'", !inDouble {
                inSingle.toggle()
            } else if character == "\"", !inSingle {
                inDouble.toggle()
            } else if character == ":", !inSingle, !inDouble {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The scalar of a block-sequence line (`- value`), or nil.
    static func sequenceItem(_ line: String) -> String? {
        let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard stripped == "-" || stripped.hasPrefix("- ") else { return nil }
        let raw = String(stripped.dropFirst()).trimmingCharacters(in: .whitespaces)
        return unquote(raw)
    }

    static func value(_ raw: String) -> Value {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return .string(unescapeDouble(String(raw.dropFirst().dropLast())))
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return .string(String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        // Hermes loads its config with PyYAML's safe_load, which is YAML 1.1:
        // `yes`, `no`, `on` and `off` are booleans there, not strings. Reading
        // only `true`/`false` would report a server the user disabled with
        // `enabled: no` as enabled.
        switch raw.lowercased() {
        case "true", "yes", "on": return .boolean(true)
        case "false", "no", "off": return .boolean(false)
        default: break
        }
        if let integer = Int(raw) { return .integer(integer) }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            let items = splitTopLevel(inner)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .array(items.map(unquote))
        }
        // A bare scalar: `command: uvx`. Ordinary YAML, and the shape Hermes'
        // own examples use, so it is a string rather than something unmodelled.
        if raw.hasPrefix("{") || raw.hasPrefix("&") || raw.hasPrefix("*")
            || raw.hasPrefix("|") || raw.hasPrefix(">") {
            return .verbatim(raw)
        }
        return .string(raw)
    }

    static func rendered(_ value: Value) -> String {
        switch value {
        case .string(let text): text
        case .integer(let number): String(number)
        case .boolean(let flag): flag ? "true" : "false"
        case .array(let items): "[\(items.joined(separator: ", "))]"
        case .verbatim(let text): text
        }
    }

    /// Drops a trailing `#` comment. YAML only starts a comment at the start of
    /// a line or after whitespace, so `args: ["a#b"]` and a bare `a#b` both
    /// survive.
    static func stripComment(_ line: String) -> String {
        var result = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                previous = character
                continue
            }
            switch character {
            case "\\" where inDouble:
                result.append(character)
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                result.append(character)
            case "\"" where !inSingle:
                inDouble.toggle()
                result.append(character)
            case "#" where !inSingle && !inDouble && (previous == nil || previous == " "):
                return result
            default:
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inDouble:
                current.append(character)
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                current.append(character)
            case "\"" where !inSingle:
                inDouble.toggle()
                current.append(character)
            case "," where !inSingle && !inDouble:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return unescapeDouble(String(text.dropFirst().dropLast()))
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return text
    }

    /// Everything Uncoil writes is double-quoted. A value like `${VAR}`, `- 5`
    /// or `yes` changes meaning unquoted, and quoting unconditionally is one
    /// rule instead of a list of exceptions to get wrong.
    static func quote(_ text: String) -> String {
        "\"\(escapeDouble(text))\""
    }

    static func quoteKeyIfNeeded(_ key: String) -> String {
        let bare = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return bare && !key.isEmpty ? key : quote(key)
    }

    static func escapeDouble(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescapeDouble(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
