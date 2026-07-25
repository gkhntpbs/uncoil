import Foundation

/// Just enough TOML for Codex's `[mcp_servers.*]` tables.
///
/// Deliberately NOT a general TOML implementation: it reads the MCP tables and
/// rewrites only those, leaving every other line — including comments,
/// ordering and formatting — exactly as the user wrote it. Anything it does not
/// understand is reported rather than silently dropped.
enum CodexTOML {
    static let serversTable = "mcp_servers"

    /// One `[mcp_servers.<name>]` (plus its `[mcp_servers.<name>.env]`) block,
    /// with the line range it occupies so a rewrite can be surgical.
    struct ServerBlock: Equatable {
        var name: String
        var values: [String: Value]
        var environment: [String: String]
        /// Inclusive line indices covered by the server table and its env table.
        var lineRange: ClosedRange<Int>
    }

    enum Value: Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case array([String])
        /// A value this reader does not model; kept verbatim so a rewrite can
        /// put it back untouched.
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

        var rendered: String {
            switch self {
            case .string(let value): "\"\(escape(value))\""
            case .integer(let value): String(value)
            case .boolean(let value): value ? "true" : "false"
            case .array(let values): "[\(values.map { "\"\(escape($0))\"" }.joined(separator: ", "))]"
            case .verbatim(let value): value
            }
        }
    }

    // MARK: - Reading

    static func serverBlocks(in text: String) -> [ServerBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String: ServerBlock] = [:]
        var order: [String] = []
        var current: (name: String, isEnv: Bool)?

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                guard let header = tableHeader(line) else { continue }
                let path = header.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard path.first == serversTable, path.count >= 2 else { continue }
                let name = unquote(path[1])
                let isEnv = path.count == 3 && path[2] == "env"
                guard path.count == 2 || isEnv else { continue }
                if var existing = blocks[name] {
                    existing.lineRange = min(existing.lineRange.lowerBound, index)...index
                    blocks[name] = existing
                } else {
                    blocks[name] = ServerBlock(
                        name: name, values: [:], environment: [:], lineRange: index...index
                    )
                    order.append(name)
                }
                current = (name, isEnv)
                continue
            }
            guard let current, var block = blocks[current.name] else { continue }
            block.lineRange = block.lineRange.lowerBound...max(block.lineRange.upperBound, index)
            if let pair = keyValue(line) {
                if current.isEnv {
                    block.environment[pair.key] = pair.value.stringValue ?? pair.value.rendered
                } else {
                    block.values[pair.key] = pair.value
                }
            }
            blocks[current.name] = block
        }
        return order.compactMap { blocks[$0] }
    }

    static func servers(in text: String) -> [MCPServerDefinition] {
        serverBlocks(in: text).map { block in
            let split = AgentAdapterSupport.partitionEnvironment(block.environment)
            let url = block.values["url"]?.stringValue
            return MCPServerDefinition(
                id: "codex:\(block.name)",
                name: block.name,
                transport: url == nil ? .stdio : .http,
                command: block.values["command"]?.stringValue,
                arguments: block.values["args"]?.arrayValue ?? [],
                url: url,
                environmentKeys: split.secretKeys,
                environment: split.plain,
                isEnabled: block.values["enabled"]?.boolValue ?? true,
                startupTimeoutSeconds: block.values["startup_timeout_sec"]?.intValue
            )
        }
    }

    // MARK: - Writing

    /// Replaces (or appends, or removes) one server block, leaving all other
    /// lines byte-identical.
    static func rewrite(
        _ text: String,
        name: String,
        with block: String?
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        if let existing = serverBlocks(in: text).first(where: { $0.name == name }) {
            // Trim trailing blank lines from the replaced span so removing a
            // block does not leave a growing gap.
            var upper = existing.lineRange.upperBound
            while upper > existing.lineRange.lowerBound,
                  lines[upper].trimmingCharacters(in: .whitespaces).isEmpty {
                upper -= 1
            }
            let range = existing.lineRange.lowerBound...upper
            if let block {
                lines.replaceSubrange(range, with: block.components(separatedBy: "\n"))
            } else {
                lines.removeSubrange(range)
                while let first = lines.first, lines.count > 1,
                      first.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.removeFirst()
                }
            }
            return lines.joined(separator: "\n")
        }
        guard let block else { return text }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + block + "\n"
    }

    /// Renders a server as a TOML block. Secret env VALUES are never rendered;
    /// only non-secret pairs reach the file.
    static func render(_ definition: MCPServerDefinition) -> String {
        var lines = ["[\(serversTable).\(quoteIfNeeded(definition.name))]"]
        switch definition.transport {
        case .stdio:
            if let command = definition.command {
                lines.append("command = \(Value.string(command).rendered)")
            }
            lines.append("args = \(Value.array(definition.arguments).rendered)")
        case .http:
            if let url = definition.url {
                lines.append("url = \(Value.string(url).rendered)")
            }
        }
        if let timeout = definition.startupTimeoutSeconds {
            lines.append("startup_timeout_sec = \(timeout)")
        }
        if !definition.isEnabled {
            lines.append("enabled = false")
        }
        // Secret VALUES never reach an agent config, even if a caller put one in
        // `environment`: the launcher injects them from the Keychain instead.
        let safeEnvironment = definition.environment.filter {
            !AgentAdapterSupport.isSecretKey($0.key)
        }
        if !safeEnvironment.isEmpty {
            lines.append("")
            lines.append("[\(serversTable).\(quoteIfNeeded(definition.name)).env]")
            for key in safeEnvironment.keys.sorted() {
                lines.append("\(key) = \(Value.string(safeEnvironment[key] ?? "").rendered)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lexing helpers

    static func tableHeader(_ line: String) -> String? {
        guard line.hasPrefix("["), !line.hasPrefix("[[") else { return nil }
        guard let end = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<end])
    }

    static func keyValue(_ line: String) -> (key: String, value: Value)? {
        let stripped = stripComment(line)
        guard !stripped.isEmpty, let separator = stripped.firstIndex(of: "=") else { return nil }
        let key = unquote(String(stripped[..<separator]).trimmingCharacters(in: .whitespaces))
        let raw = String(stripped[stripped.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !raw.isEmpty else { return nil }
        return (key, value(raw))
    }

    static func value(_ raw: String) -> Value {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return .string(unescape(String(raw.dropFirst().dropLast())))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if let integer = Int(raw) { return .integer(integer) }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            let items = splitTopLevel(inner)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard items.allSatisfy({ $0.hasPrefix("\"") && $0.hasSuffix("\"") }) else {
                return .verbatim(raw)
            }
            return .array(items.map { unescape(String($0.dropFirst().dropLast())) })
        }
        return .verbatim(raw)
    }

    /// Drops a trailing `#` comment, respecting quoted strings.
    static func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                result.append(character)
                escaped = true
            case "\"":
                inString.toggle()
                result.append(character)
            case "#" where !inString:
                return result.trimmingCharacters(in: .whitespaces)
            default:
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                current.append(character)
                escaped = true
            case "\"":
                inString.toggle()
                current.append(character)
            case "," where !inString:
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
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return unescape(String(text.dropFirst().dropLast()))
    }

    static func quoteIfNeeded(_ name: String) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return bare && !name.isEmpty ? name : "\"\(escape(name))\""
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
