// uncoil-hook — agent hook forwarder.
// Usage (installed by Uncoil): uncoil-hook <socket-path> [event-name]
// Reads the hook JSON from stdin and writes it as one line to Uncoil's
// Unix socket. Must never block the agent: every failure path exits 0 fast.
//
// The optional event name is for agents that do not name the event inside the
// payload. Claude Code sends `hook_event_name` itself and is forwarded byte for
// byte — the argument is absent there, and nothing below touches its JSON.
// Hermes says which event fired only by which config key the command sits
// under, so Uncoil passes the name in and this stamps it on.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let socketPath = arguments[1]
let eventName = arguments.count >= 3 && !arguments[2].isEmpty ? arguments[2] : nil

// Read stdin with a hard cap so a runaway payload can't stall the hook.
var payload = Data()
let stdinHandle = FileHandle.standardInput
while let chunk = try? stdinHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
    payload.append(chunk)
    if payload.count > 2 * 1024 * 1024 { break }
}
guard !payload.isEmpty else { exit(0) }

/// Adds what the payload does not carry, for agents that need it.
///
/// Two fields, both required by Uncoil's reducer and neither sent by Hermes:
/// the event name, which only the caller knows, and the working directory,
/// which is how Uncoil works out *which project and session* an event belongs
/// to. A hook runs as a child of the agent, so this process's own working
/// directory is the agent's — which is the directory Uncoil launched it in.
///
/// Only ever called when an event name was passed. A payload that already names
/// its own event, or its own cwd, keeps what it had; and Claude Code's path
/// never reaches this function at all, so its bytes stay untouched.
func stamped(_ payload: Data, event: String) -> Data {
    guard
        var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else { return payload }
    if object["hook_event_name"] == nil {
        object["hook_event_name"] = event
    }
    if (object["cwd"] as? String)?.isEmpty != false {
        object["cwd"] = FileManager.default.currentDirectoryPath
    }
    // A payload that cannot be re-encoded is forwarded as it came rather than
    // dropped: the reducer will ignore it, which is no worse than this failing.
    guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return payload }
    return encoded
}

if let eventName {
    payload = stamped(payload, event: eventName)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
defer { close(fd) }

// 1-second send timeout: if Uncoil is wedged, drop the event, never block.
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
}

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }  // Uncoil not running — fail safe.

payload.append(UInt8(ascii: "\n"))
payload.withUnsafeBytes { raw in
    _ = write(fd, raw.baseAddress, raw.count)
}
exit(0)
