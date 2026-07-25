import Foundation

struct CodexAppServerMessage: Equatable {
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONValue?

    init(data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = value.objectValue else {
            throw CodexAppServerProtocolError.invalidEnvelope
        }
        id = object["id"]
        method = object["method"]?.stringValue
        params = object["params"]
        result = object["result"]
        error = object["error"]
    }
}

enum CodexAppServerProtocolError: LocalizedError {
    case invalidEnvelope
    case invalidResponse
    case server(String)
    case incompatibleVersion(String)
    case processLaunch(String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            "Codex app-server geçersiz bir JSONL mesajı gönderdi."
        case .invalidResponse:
            "Codex app-server yanıtı beklenen alanları içermiyor."
        case .server(let message):
            message
        case .incompatibleVersion(let version):
            "Codex \(version) structured protokolü desteklenmiyor."
        case .processLaunch(let message):
            message
        }
    }
}

struct CodexAppServerCompatibility: Equatable {
    static let schemaVersion = "0.145.0"
    static let minimumMinor = 145
    static let maximumMinor = 145

    let version: String
    let isSupported: Bool

    static func evaluate(_ output: String) -> CodexAppServerCompatibility {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let versionRange = Range(match.range(at: 0), in: output),
              let majorRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let major = Int(output[majorRange]),
              let minor = Int(output[minorRange]) else {
            return CodexAppServerCompatibility(version: output.trimmingCharacters(in: .whitespacesAndNewlines), isSupported: false)
        }
        let version = String(output[versionRange])
        return CodexAppServerCompatibility(
            version: version,
            isSupported: major == 0 && minor >= minimumMinor && minor <= maximumMinor
        )
    }
}

enum CodexAppServerJSON {
    static func data(id: Int, method: String, params: JSONValue) throws -> Data {
        try line(.object([
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ]))
    }

    static func notification(method: String, params: JSONValue = .object([:])) throws -> Data {
        try line(.object([
            "method": .string(method),
            "params": params,
        ]))
    }

    static func response(id: JSONValue, result: JSONValue) throws -> Data {
        try line(.object([
            "id": id,
            "result": result,
        ]))
    }

    private static func line(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}

enum CodexStructuredFormatter {
    static func history(from result: JSONValue) -> String {
        guard let object = result.objectValue else { return "" }
        let turns = object["initialTurnsPage"]?.objectValue?["data"]?.arrayValue
            ?? object["thread"]?.objectValue?["turns"]?.arrayValue
            ?? []
        return turns.flatMap { turn in
            turn.objectValue?["items"]?.arrayValue ?? []
        }
        .compactMap { itemText($0, includeAgentMessage: true) }
        .joined()
    }

    static func startedItem(_ item: JSONValue) -> String? {
        itemText(item, includeAgentMessage: false)
    }

    static func completedItem(_ item: JSONValue, agentMessageWasStreamed: Bool) -> String? {
        guard let object = item.objectValue,
              let type = object["type"]?.stringValue else { return nil }
        if type == "agentMessage", agentMessageWasStreamed {
            return "\r\n"
        }
        return itemText(item, includeAgentMessage: true)
    }

    static func itemID(_ item: JSONValue) -> String? {
        item.objectValue?["id"]?.stringValue
    }

    private static func itemText(_ item: JSONValue, includeAgentMessage: Bool) -> String? {
        guard let object = item.objectValue,
              let type = object["type"]?.stringValue else { return nil }
        switch type {
        case "userMessage":
            guard let text = messageText(object), !text.isEmpty else { return nil }
            return "\r\n\u{001B}[1;36m›\u{001B}[0m \(text)\r\n"
        case "agentMessage":
            guard includeAgentMessage,
                  let text = object["text"]?.stringValue ?? messageText(object),
                  !text.isEmpty else { return nil }
            return "\(text)\r\n"
        case "reasoning":
            let text = object["summary"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: "\n")
                ?? object["text"]?.stringValue
            guard let text, !text.isEmpty else { return nil }
            return "\r\n\u{001B}[2m\(text)\u{001B}[0m\r\n"
        case "commandExecution":
            let command = object["command"]?.stringValue ?? object["aggregatedOutput"]?.stringValue
            guard let command, !command.isEmpty else { return nil }
            return "\r\n\u{001B}[1;33m$ \(command)\u{001B}[0m\r\n"
        case "fileChange":
            let changes = object["changes"]?.arrayValue?
                .compactMap { $0.objectValue?["path"]?.stringValue }
                .joined(separator: ", ")
            guard let changes, !changes.isEmpty else { return "\r\n\u{001B}[1;35mDosya değişikliği\u{001B}[0m\r\n" }
            return "\r\n\u{001B}[1;35mDosya değişikliği:\u{001B}[0m \(changes)\r\n"
        case "mcpToolCall":
            let server = object["server"]?.stringValue ?? "MCP"
            let tool = object["tool"]?.stringValue ?? object["name"]?.stringValue ?? "tool"
            return "\r\n\u{001B}[1;34m\(server) › \(tool)\u{001B}[0m\r\n"
        case "dynamicToolCall":
            let tool = object["tool"]?.stringValue ?? object["name"]?.stringValue ?? "tool"
            return "\r\n\u{001B}[1;34mTool › \(tool)\u{001B}[0m\r\n"
        case "collabAgentToolCall":
            let tool = object["tool"]?.stringValue ?? "agent"
            return "\r\n\u{001B}[1;34mAgent › \(tool)\u{001B}[0m\r\n"
        default:
            return nil
        }
    }

    private static func messageText(_ object: [String: JSONValue]) -> String? {
        if let text = object["text"]?.stringValue { return text }
        return object["content"]?.arrayValue?
            .compactMap { content in
                let value = content.objectValue
                return value?["text"]?.stringValue ?? value?["value"]?.stringValue
            }
            .joined()
    }
}

extension JSONValue {
    var displayString: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return nil
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
