import Foundation

/// Wire protocol between Uncoil.app and uncoil-runtimed.
/// Line-delimited JSON over a user-private Unix socket; binary payloads are
/// base64 in `b64`. Both sides send a versioned hello first and must drop the
/// connection on a version mismatch.
enum RuntimeProtocol {
    static let version = 1
    /// Minor revision: additive commands (`peek`/`replay`) that don't break
    /// the version-1 handshake. Bumped when such commands are added.
    static let minor = 1
    static let socketName = "runtime.sock"
    /// Per-session replay buffer cap inside the daemon.
    static let replayBufferLimit = 512 * 1024
}

/// App → daemon.
struct RuntimeCommand: Codable {
    var cmd: String        // hello|launch|attach|input|resize|kill|list|shutdown|peek
    var version: Int?
    var sid: String?
    var shell: String?
    var args: [String]?
    var env: [String]?
    var cwd: String?
    var cols: Int?
    var rows: Int?
    var b64: String?

    static func hello() -> RuntimeCommand {
        RuntimeCommand(cmd: "hello", version: RuntimeProtocol.version)
    }
}

/// Daemon → app.
struct RuntimeEventMessage: Codable {
    var ev: String         // hello|sessions|data|exited|error|replay
    var version: Int?
    var sid: String?
    var sids: [String]?
    var b64: String?
    var code: Int32?
    var message: String?
}

extension Data {
    /// Encodes a message and appends the protocol's line terminator.
    static func runtimeLine<T: Encodable>(_ message: T) -> Data? {
        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
