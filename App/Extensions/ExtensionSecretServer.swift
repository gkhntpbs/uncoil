import Darwin
import Foundation

/// Serves MCP secrets to `uncoil-extension` over a 0600, euid-checked Unix
/// socket. One line of JSON in, one out, and nothing but the environment for the
/// extension that was asked about — so a secret value never lands on disk and
/// never travels further than the process that needs it.
///
/// Safe to mark `@unchecked Sendable`: socket bookkeeping stays on `queue`, and
/// the resolver hop to the main actor is explicit.
final class ExtensionSecretServer: @unchecked Sendable {
    /// Answers a request for an extension's environment. Injected so the store
    /// (and its Keychain access) stays on the main actor.
    typealias Resolver = @MainActor (String) -> ExtensionSecretProtocol.Response

    private let socketPath: String
    private let resolve: Resolver
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "com.gokhantopbas.uncoil.extension-secrets")

    init(socketPath: String, resolve: @escaping Resolver) {
        self.socketPath = socketPath
        self.resolve = resolve
    }

    static func defaultSocketPath() -> String {
        ProjectStore.defaultDirectory()
            .appendingPathComponent(ExtensionSecretProtocol.socketName).path
    }

    func start() throws {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EMFILE) }
        var address = try socketAddress()
        // A leftover socket from a crashed run is ours to clear; a live one is
        // another instance's and must not be stolen.
        if bindSocket(&address) != 0 {
            guard errno == EADDRINUSE, !existingServerIsReachable(address: &address) else {
                close(listenFD)
                listenFD = -1
                throw POSIXError(.EADDRINUSE)
            }
            unlink(socketPath)
            guard bindSocket(&address) == 0 else {
                close(listenFD)
                listenFD = -1
                throw POSIXError(.EADDRINUSE)
            }
        }
        guard listen(listenFD, 8) == 0 else {
            close(listenFD)
            listenFD = -1
            throw POSIXError(.EADDRINUSE)
        }
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        clientSources.values.forEach { $0.cancel() }
        clientSources.removeAll()
        clientBuffers.removeAll()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(socketPath)
        }
    }

    // MARK: - Socket plumbing

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

    private func bindSocket(_ address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func existingServerIsReachable(address: inout sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private func accept() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        // Only this user's processes may ask for secrets.
        var credentials = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        let ok = getsockopt(clientFD, 0, LOCAL_PEERCRED, &credentials, &size) == 0
            && credentials.cr_uid == geteuid()
        guard ok else {
            close(clientFD)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.read(clientFD) }
        source.setCancelHandler { close(clientFD) }
        clientSources[clientFD] = source
        clientBuffers[clientFD] = Data()
        source.resume()
    }

    private func read(_ clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(clientFD, &buffer, buffer.count)
        guard count > 0 else {
            disconnect(clientFD)
            return
        }
        var pending = clientBuffers[clientFD] ?? Data()
        pending.append(contentsOf: buffer[0..<count])
        // A request is a single line; anything larger than one is a protocol
        // error, not something to accumulate.
        guard pending.count <= 64 * 1024 else {
            disconnect(clientFD)
            return
        }
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending.prefix(upTo: newline))
            pending.removeSubrange(...newline)
            handle(line, clientFD: clientFD)
        }
        clientBuffers[clientFD] = pending
    }

    private func handle(_ line: Data, clientFD: Int32) {
        guard let request = try? JSONDecoder()
            .decode(ExtensionSecretProtocol.Request.self, from: line) else {
            write(.failure("invalid request"), to: clientFD)
            return
        }
        let resolve = resolve
        Task { @MainActor in
            let response = resolve(request.extension_id)
            self.queue.async { self.write(response, to: clientFD) }
        }
    }

    private func write(_ response: ExtensionSecretProtocol.Response, to clientFD: Int32) {
        guard var data = try? JSONEncoder().encode(response) else {
            disconnect(clientFD)
            return
        }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            _ = Darwin.write(clientFD, raw.baseAddress, raw.count)
        }
        disconnect(clientFD)
    }

    private func disconnect(_ clientFD: Int32) {
        clientSources[clientFD]?.cancel()
        clientSources[clientFD] = nil
        clientBuffers[clientFD] = nil
    }
}
