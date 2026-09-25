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
            "The Codex app-server sent an invalid JSONL message."
        case .invalidResponse:
            "The Codex app-server's reply is missing expected fields."
        case .server(let message):
            message
        case .incompatibleVersion(let version):
            "Codex \(version) does not support the structured protocol."
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
