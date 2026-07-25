import Foundation

/// Wire protocol between Uncoil.app and uncoil-runtimed.
/// Line-delimited JSON over a user-private Unix socket; binary payloads are
/// base64 in `b64`. Both sides send a versioned hello first and must drop the
/// connection on a version mismatch.
enum RuntimeProtocol {
    static let version = 1
    /// Minor revision: additive commands (`peek`/`replay`, then the task-claim
    /// set) that don't break the version-1 handshake. Bumped when such commands
    /// are added.
    static let minor = 2
    /// A task claim is granted for this long and renewed by heartbeat, so an
    /// agent that dies stops holding the task.
    static let taskLeaseDuration: TimeInterval = 15 * 60
    static let socketName = "runtime.sock"
    /// Per-session replay buffer cap inside the daemon.
    static let replayBufferLimit = 512 * 1024
    static let replayDiskLimit = 16 * 1024 * 1024
    static let logFileLimit = 1024 * 1024
    static let logGenerations = 3
    static let sessionIdleThreshold: TimeInterval = 60 * 60

    enum Compatibility: Equatable {
        case compatible(minor: Int)
        case incompatible(String)
    }

    static func negotiate(peerVersion: Int?, peerMinor: Int?) -> Compatibility {
        guard let peerVersion else {
            return .incompatible("Runtime daemon sürüm bilgisi göndermedi.")
        }
        guard peerVersion == version else {
            return .incompatible(
                "Runtime protokolü uyumsuz: uygulama \(version).\(minor), daemon \(peerVersion).\(peerMinor ?? 0)."
            )
        }
        return .compatible(minor: min(minor, peerMinor ?? 0))
    }
}

/// App → daemon.
struct RuntimeCommand: Codable {
    /// hello|launch|attach|input|resize|kill|list|shutdown|upgrade|peek
    /// |task_claim|task_release|task_heartbeat|task_claims
    var cmd: String
    var version: Int?
    var minor: Int?
    var sid: String?
    var shell: String?
    var args: [String]?
    var env: [String]?
    var cwd: String?
    var cols: Int?
    var rows: Int?
    var b64: String?
    /// Claim key: the task's id, scoped by project.
    var task_id: String?
    var project_id: String?
    /// Claiming role, so the daemon can enforce one implementer per task.
    var role: String?
    var duration_s: Double?

    static func hello() -> RuntimeCommand {
        RuntimeCommand(
            cmd: "hello",
            version: RuntimeProtocol.version,
            minor: RuntimeProtocol.minor
        )
    }
}

/// Daemon → app.
struct RuntimeEventMessage: Codable {
    /// hello|sessions|data|exited|error|replay|task_claim|task_claims
    var ev: String
    var version: Int?
    var minor: Int?
    var sid: String?
    var sids: [String]?
    var b64: String?
    var code: Int32?
    var errorCode: String?
    var message: String?
    /// Task-claim replies.
    var task_id: String?
    var granted: Bool?
    var owner_sid: String?
    var role: String?
    var expires_at: Double?
    var generation: Int?
    var claims: [RuntimeTaskClaim]?
}

/// One live claim as the daemon holds it. The daemon is the arbiter because it
/// is the single process that outlives the app and knows when a session's PTY
/// went away — a claim whose session died must not keep a task locked.
struct RuntimeTaskClaim: Codable, Equatable {
    var task_id: String
    var project_id: String?
    var owner_sid: String
    var role: String
    var acquired_at: Double
    var expires_at: Double
    var generation: Int
    var last_heartbeat: Double
    /// True when the daemon owned this session's PTY at claim time. Only then
    /// does the session disappearing release the claim: a session the daemon
    /// never launched (an in-process PTY, a Codex app-server thread) is not
    /// "gone" merely because the daemon cannot see it.
    var session_known: Bool
}

extension Data {
    /// Encodes a message and appends the protocol's line terminator.
    static func runtimeLine<T: Encodable>(_ message: T) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
