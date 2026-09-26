import Foundation

/// Wire protocol between the bundled `uncoil-mcp` stdio server and the
/// in-app control plane (`control.sock`). Line-delimited JSON over a
/// user-private Unix socket, mirroring the runtime/hook socket pattern.
///
/// Compiled into BOTH the `Uncoil` app target and the `uncoil-mcp` tool so
/// the request/response shapes stay identical on both ends.
enum ControlProtocol {
    /// The request shape this build speaks.
    ///
    /// Version 2 added `session_token` and `client` to the request, both
    /// optional. The rule for every version after it is the same: fields are
    /// added, never renamed or repurposed, so a server decodes any request from
    /// `minimumVersion` up and a client can talk to a newer server unchanged.
    static let version = 2
    /// The oldest request shape the server still accepts.
    static let minimumVersion = 1
    static let socketName = "control.sock"
    /// Default per-call timeout the MCP server enforces.
    static let defaultTimeout: TimeInterval = 30
    /// The longest a single call may wait on the app — the ceiling on every
    /// action's own `timeout_s`, plus the time it takes to answer.
    static let maximumTimeout: TimeInterval = 330

    /// How long the MCP server waits for the app to answer one call: the
    /// action's own wait, when it has one, plus a margin to report it.
    ///
    /// A fixed 30 s used to cut every longer wait short — `wait_for_children`
    /// defaults to 120 s, so it could only ever end in a client-side TIMEOUT
    /// while the app went on waiting for nobody.
    static func callTimeout(args: [String: JSONValue]) -> TimeInterval {
        let requested = args["timeout_s"]?.doubleValue
            ?? args["wait_s"]?.doubleValue
            ?? 0
        return min(maximumTimeout, max(defaultTimeout, requested + 15))
    }

    /// Environment the MCP server reads its session from. One set of names for
    /// every provider: a provider's own config only decides how they arrive.
    enum Environment {
        static let sessionID = "UNCOIL_SESSION_ID"
        static let sessionToken = "UNCOIL_SESSION_TOKEN"
        static let projectID = "UNCOIL_PROJECT_ID"
        static let controlSocket = "UNCOIL_CONTROL_SOCKET"
    }
}

// MARK: - JSON value

/// A minimal, dependency-free JSON value used for the permissive `args`
/// object and free-form `data`/`details` payloads. Integers are preserved
/// where they round-trip exactly.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // Convenience accessors used by handlers.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    /// Accepts an int too: JSON has one number type, and a duration that
    /// happens to land on a whole second decodes as `.int`.
    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

// MARK: - Request

/// MCP → app. One line-JSON request per `tools/call`.
struct ControlRequest: Codable, Equatable {
    var version: Int
    var capability: String
    var action: String
    var args: [String: JSONValue]
    var caller_session_id: String?
    /// Proof that the caller is the session it names. Issued by the app when
    /// it launches the session; see `SessionCredentials`. Absent from
    /// version-1 clients, which are treated as unverified.
    var session_token: String?
    /// Who is on the other end, for the audit log: `uncoil-mcp/2`.
    var client: String?
    var request_id: String

    init(
        version: Int = ControlProtocol.version,
        capability: String,
        action: String,
        args: [String: JSONValue] = [:],
        caller_session_id: String? = nil,
        session_token: String? = nil,
        client: String? = nil,
        request_id: String = UUID().uuidString
    ) {
        self.version = version
        self.capability = capability
        self.action = action
        self.args = args
        self.caller_session_id = caller_session_id
        self.session_token = session_token
        self.client = client
        self.request_id = request_id
    }

    private enum CodingKeys: String, CodingKey {
        case version, capability, action, args, caller_session_id, session_token, client, request_id
    }

    /// Only `capability` and `action` are required. Everything else has a
    /// meaning when absent, so a minimal or older client is read rather than
    /// refused: no version is version 1, no args is none, no id gets one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        capability = try container.decode(String.self, forKey: .capability)
        action = try container.decode(String.self, forKey: .action)
        args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        caller_session_id = try container.decodeIfPresent(String.self, forKey: .caller_session_id)
        session_token = try container.decodeIfPresent(String.self, forKey: .session_token)
        client = try container.decodeIfPresent(String.self, forKey: .client)
        request_id = try container.decodeIfPresent(String.self, forKey: .request_id) ?? UUID().uuidString
    }
}

// MARK: - Response envelope

/// Stable error codes shared across the whole control plane. Raw values are
/// part of the public contract — never rename an existing case's string.
enum ControlErrorCode: String, Codable, CaseIterable {
    case unknownProject = "UNKNOWN_PROJECT"
    case unknownSession = "UNKNOWN_SESSION"
    case sessionNotRunning = "SESSION_NOT_RUNNING"
    case capabilityDisabled = "CAPABILITY_DISABLED"
    case permissionRequired = "PERMISSION_REQUIRED"
    case permissionDenied = "PERMISSION_DENIED"
    case invalidRelationship = "INVALID_RELATIONSHIP"
    case invalidPath = "INVALID_PATH"
    case browserUnavailable = "BROWSER_UNAVAILABLE"
    case computerUnavailable = "COMPUTER_UNAVAILABLE"
    case staleElementReference = "STALE_ELEMENT_REFERENCE"
    case staleWindowBinding = "STALE_WINDOW_BINDING"
    case targetChanged = "TARGET_CHANGED"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"
    case dependencyVersionMismatch = "DEPENDENCY_VERSION_MISMATCH"
    case unsupportedPlatform = "UNSUPPORTED_PLATFORM"
    case invalidAction = "INVALID_ACTION"
    case invalidStateTransition = "INVALID_STATE_TRANSITION"
    case controlPlaneUnavailable = "CONTROL_PLANE_UNAVAILABLE"
    case invalidArgument = "INVALID_ARGUMENT"
    case ioError = "IO_ERROR"
    case internalError = "INTERNAL_ERROR"
    /// The caller could not be shown to be the session it names — no token, a
    /// wrong one, or no session at all. `details.reason` says which.
    case identityUnverified = "IDENTITY_UNVERIFIED"
    /// The session exists and is running, but does not offer this operation.
    /// Read `sessions capabilities` instead of retrying.
    case unsupportedCapability = "UNSUPPORTED_CAPABILITY"
    /// The session's agent cannot take the call right now: not connected yet,
    /// crashed, or restarting. Retryable.
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    /// An `idempotency_key` was reused with different arguments.
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    /// The request's `version` is newer than this app understands.
    case unsupportedVersion = "UNSUPPORTED_VERSION"
}

struct ControlErrorBody: Codable, Equatable {
    var code: String
    var message: String
    var retryable: Bool
    var details: JSONValue?

    init(code: ControlErrorCode, message: String, retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code.rawValue
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

/// The single response shape. `ok == true` carries `data`; `ok == false`
/// carries `error`. Both forms echo `capability`/`action`/`request_id`.
struct ControlEnvelope: Codable, Equatable {
    var ok: Bool
    var capability: String
    var action: String
    var request_id: String
    var project_id: String?
    var caller_session_id: String?
    var target_session_id: String?
    var data: JSONValue?
    var artifacts: [JSONValue]
    var warnings: [String]
    var next_actions: [String]
    var error: ControlErrorBody?

    init(
        ok: Bool,
        capability: String,
        action: String,
        request_id: String,
        project_id: String? = nil,
        caller_session_id: String? = nil,
        target_session_id: String? = nil,
        data: JSONValue? = nil,
        artifacts: [JSONValue] = [],
        warnings: [String] = [],
        next_actions: [String] = [],
        error: ControlErrorBody? = nil
    ) {
        self.ok = ok
        self.capability = capability
        self.action = action
        self.request_id = request_id
        self.project_id = project_id
        self.caller_session_id = caller_session_id
        self.target_session_id = target_session_id
        self.data = data
        self.artifacts = artifacts
        self.warnings = warnings
        self.next_actions = next_actions
        self.error = error
    }

    static func success(
        _ request: ControlRequest,
        data: JSONValue? = nil,
        project_id: String? = nil,
        target_session_id: String? = nil,
        artifacts: [JSONValue] = [],
        warnings: [String] = [],
        next_actions: [String] = []
    ) -> ControlEnvelope {
        ControlEnvelope(
            ok: true, capability: request.capability, action: request.action,
            request_id: request.request_id, project_id: project_id,
            caller_session_id: request.caller_session_id,
            target_session_id: target_session_id, data: data,
            artifacts: artifacts, warnings: warnings, next_actions: next_actions
        )
    }

    static func failure(
        _ request: ControlRequest,
        code: ControlErrorCode,
        message: String,
        retryable: Bool = false,
        details: JSONValue? = nil,
        target_session_id: String? = nil
    ) -> ControlEnvelope {
        ControlEnvelope(
            ok: false, capability: request.capability, action: request.action,
            request_id: request.request_id,
            caller_session_id: request.caller_session_id,
            target_session_id: target_session_id,
            error: ControlErrorBody(code: code, message: message, retryable: retryable, details: details)
        )
    }
}

// MARK: - Line framing

extension Data {
    /// Encodes a control message and appends the newline terminator.
    static func controlLine<T: Encodable>(_ message: T) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
