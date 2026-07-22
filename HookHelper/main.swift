// uncoil-hook — Claude Code hook forwarder.
// Usage (installed by Uncoil): uncoil-hook <socket-path>
// Reads the hook JSON from stdin and writes it as one line to Uncoil's
// Unix socket. Must never block Claude: every failure path exits 0 fast.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let socketPath = arguments[1]

// Read stdin with a hard cap so a runaway payload can't stall the hook.
var payload = Data()
let stdinHandle = FileHandle.standardInput
while let chunk = try? stdinHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
    payload.append(chunk)
    if payload.count > 2 * 1024 * 1024 { break }
}
guard !payload.isEmpty else { exit(0) }

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
