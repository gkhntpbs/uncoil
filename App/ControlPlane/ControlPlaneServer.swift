import Foundation

/// Line-delimited JSON control socket at <AppSupport>/Uncoil/control.sock.
/// 0600 + LOCAL_PEERCRED euid check (unlike HookServer, which relies only on
/// the user-private directory). Each request is decoded, routed on the main
/// actor, and the envelope written back on the same connection.
/// Safe to mark `@unchecked Sendable`: all mutable socket bookkeeping is
/// confined to the private serial `queue`; only immutable references escape.
final class ControlPlaneServer: @unchecked Sendable {
    private let socketPath: String
    private let router: CapabilityRouter
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private var ownsSocket = false
    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.control-server")

    init(socketPath: String, router: CapabilityRouter) {
        self.socketPath = socketPath
        self.router = router
    }

    static func defaultSocketPath() -> String {
        ProjectStore.defaultDirectory().appendingPathComponent(ControlProtocol.socketName).path
    }

    func start() throws {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EMFILE) }

        var address = try socketAddress()
        var bindResult = bindSocket(listenFD, address: &address)
        if bindResult != 0, errno == EADDRINUSE {
            if existingServerIsReachable(address: &address) {
                close(listenFD)
                listenFD = -1
                throw POSIXError(.EADDRINUSE)
            }
            unlink(socketPath)
            bindResult = bindSocket(listenFD, address: &address)
        }
        guard bindResult == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            listenFD = -1
            throw POSIXError(.EADDRINUSE)
        }
        chmod(socketPath, 0o600)
        ownsSocket = true

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return address
    }

    private func bindSocket(_ fd: Int32, address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func existingServerIsReachable(address: inout sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for (fd, source) in clientSources { source.cancel(); close(fd) }
        clientSources.removeAll()
        clientBuffers.removeAll()
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        if ownsSocket {
            unlink(socketPath)
            ownsSocket = false
        }
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard peerIsCurrentUser(fd) else { close(fd); return }
        clientBuffers[fd] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        clientSources[fd] = source
    }

    private func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, &cred, &length) == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    private func readClient(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            clientBuffers[fd, default: Data()].append(contentsOf: chunk[0..<count])
            if let size = clientBuffers[fd]?.count, size > 8 * 1024 * 1024 {
                dropClient(fd)
                return
            }
            drainLines(fd)
        } else {
            dropClient(fd)
        }
    }

    private func drainLines(_ fd: Int32) {
        guard var buffer = clientBuffers[fd] else { return }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { dispatch(Data(line), from: fd) }
            if clientSources[fd] == nil { return }
        }
        clientBuffers[fd] = Data(buffer)
    }

    private func dispatch(_ line: Data, from fd: Int32) {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            let envelope = ControlEnvelope(
                ok: false, capability: "?", action: "?", request_id: UUID().uuidString,
                error: ControlErrorBody(code: .invalidArgument, message: "malformed request"))
            send(envelope, to: fd)
            return
        }
        let router = self.router
        Task { @MainActor in
            let envelope = await router.handle(request)
            self.queue.async { self.send(envelope, to: fd) }
        }
    }

    private func send(_ envelope: ControlEnvelope, to fd: Int32) {
        guard clientSources[fd] != nil, let data = Data.controlLine(envelope) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func dropClient(_ fd: Int32) {
        clientSources[fd]?.cancel()
        clientSources[fd] = nil
        clientBuffers[fd] = nil
    }
}
