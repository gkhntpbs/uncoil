import Foundation

/// Line-delimited JSON server on a Unix domain socket.
/// The socket lives under Application Support/Uncoil, so only the current
/// user can connect (directory is user-private).
final class HookServer {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.hook-server")

    /// Called on `queue` for every decoded event.
    var onEvent: ((HookEvent) -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EMFILE) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw POSIXError(.EADDRINUSE)
        }
        // Owner-only, like an SSH socket.
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for (fd, source) in clientSources {
            source.cancel()
            close(fd)
        }
        clientSources.removeAll()
        clientBuffers.removeAll()
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        clientBuffers[fd] = Data()
        source.setEventHandler { [weak self] in self?.readClient(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        clientSources[fd] = source
    }

    private func readClient(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            clientBuffers[fd, default: Data()].append(contentsOf: chunk[0..<count])
            // Bound the buffer so a misbehaving client can't balloon memory.
            if let size = clientBuffers[fd]?.count, size > 4 * 1024 * 1024 {
                dropClient(fd)
                return
            }
            drainLines(fd)
        } else {
            // EOF or error — flush whatever remains as a final line.
            if let rest = clientBuffers[fd], !rest.isEmpty, let event = HookEvent(jsonLine: rest) {
                onEvent?(event)
            }
            dropClient(fd)
        }
    }

    private func drainLines(_ fd: Int32) {
        guard var buffer = clientBuffers[fd] else { return }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty, let event = HookEvent(jsonLine: Data(line)) {
                onEvent?(event)
            }
        }
        clientBuffers[fd] = Data(buffer)
    }

    private func dropClient(_ fd: Int32) {
        clientSources[fd]?.cancel()
        clientSources[fd] = nil
        clientBuffers[fd] = nil
    }
}
