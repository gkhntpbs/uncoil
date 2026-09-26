import CryptoKit
import Foundation

/// Proof that an MCP call comes from the session it names.
///
/// `UNCOIL_SESSION_ID` alone is a claim: any process of the same user can put
/// any id in a request, and until now whatever it named, it got. Each session
/// is launched with a token next to its id — an HMAC of the id under a secret
/// only the app holds — and a call is only that session's when the two agree.
///
/// Derived rather than stored: the token for a session is always the same, so
/// it survives an app restart without a table of issued tokens, and a session
/// launched by an earlier run of the app still proves itself to this one.
final class SessionCredentials: @unchecked Sendable {
    static let shared = SessionCredentials(directory: ProjectStore.defaultDirectory())

    private let secretURL: URL
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    init(directory: URL) {
        secretURL = directory.appendingPathComponent("control-secret")
    }

    /// The token a session is launched with.
    func token(for sessionID: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(sessionID.uuidString.lowercased().utf8), using: key())
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time: a token is compared as a secret, not as a string.
    func verify(_ token: String, for sessionID: UUID) -> Bool {
        let expected = Array(self.token(for: sessionID).utf8)
        let given = Array(token.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ given[index] }
        return difference == 0
    }

    private func key() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key: SymmetricKey
        if let data = try? Data(contentsOf: secretURL), data.count == 32 {
            key = SymmetricKey(data: data)
        } else {
            key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try? FileManager.default.createDirectory(
                at: secretURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: secretURL.path, contents: data,
                attributes: [.posixPermissions: 0o600])
        }
        cachedKey = key
        return key
    }
}

/// How sure the control plane is that a call comes from the session it names.
enum CallerVerification: String, Equatable {
    /// The session's token matched.
    case verified
    /// An id with no token: a session launched before tokens existed, or a
    /// process that only knows an id. It may read; it may not act.
    case unverified
    /// A token that does not belong to the id. Refused outright.
    case mismatched
    /// No id at all, or one no session has.
    case anonymous
}

/// Who is calling, resolved once per request.
///
/// Every handler used to rediscover the caller from the raw request — look
/// up the id, compute the grants, decide for itself what an unknown id means.
/// This is that answer, computed in one place, before any handler runs.
struct ControlCallContext {
    let requestID: String
    let verification: CallerVerification
    /// The calling session's record. Nil for an anonymous call.
    let caller: SessionRecord?
    /// Grants the caller holds — empty for an anonymous call.
    let grants: Set<String>
    /// The request's own version, so a handler can shape a reply for an
    /// older client.
    let protocolVersion: Int

    var callerSessionID: UUID? { caller?.id }
    var provider: AgentProvider? { caller?.provider }
    var projectID: UUID? { caller?.projectID }
    var accountID: UUID? { caller?.accountID }
    /// Only a verified caller may cause effects.
    var mayAct: Bool { verification == .verified && caller != nil }

    var asJSON: JSONValue {
        .object([
            "caller_session_id": .string(optional: caller?.id.uuidString),
            "verification": .string(verification.rawValue),
            "provider": .string(optional: caller?.provider.rawValue),
            "project_id": .string(optional: caller?.projectID.uuidString),
            "account_id": .string(optional: caller?.accountID?.uuidString),
            "grants": .array(grants.sorted().map(JSONValue.string)),
            "may_act": .bool(mayAct),
        ])
    }

    /// Pure, so every identity outcome is a unit test away.
    static func resolve(
        _ request: ControlRequest,
        sessions: [SessionRecord],
        credentials: SessionCredentials
    ) -> ControlCallContext {
        guard let raw = request.caller_session_id,
              let id = UUID(uuidString: raw),
              let record = sessions.first(where: { $0.id == id }) else {
            return ControlCallContext(
                requestID: request.request_id, verification: .anonymous,
                caller: nil, grants: [], protocolVersion: request.version)
        }
        let verification: CallerVerification
        if let token = request.session_token, !token.isEmpty {
            verification = credentials.verify(token, for: id) ? .verified : .mismatched
        } else {
            verification = .unverified
        }
        // A mismatched token claims someone else's identity; it gets nothing
        // of theirs, not even their read grants.
        guard verification != .mismatched else {
            return ControlCallContext(
                requestID: request.request_id, verification: .mismatched,
                caller: nil, grants: [], protocolVersion: request.version)
        }
        return ControlCallContext(
            requestID: request.request_id, verification: verification,
            caller: record, grants: PolicyEngine.grants(for: record),
            protocolVersion: request.version)
    }
}

extension ControlProtocol {
    /// The MCP server's environment for one session — the same names in every
    /// provider's config, so registration differs only in how it is written.
    static func mcpEnvironment(
        for record: SessionRecord,
        socketPath: String,
        credentials: SessionCredentials = .shared
    ) -> [String: String] {
        [
            Environment.sessionID: record.id.uuidString,
            Environment.sessionToken: credentials.token(for: record.id),
            Environment.projectID: record.projectID.uuidString,
            Environment.controlSocket: socketPath,
        ]
    }
}
