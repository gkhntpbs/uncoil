import Foundation

/// Connects Uncoil to uncoil-runtimed over the user-private Unix socket.
/// Spawns the daemon on demand; if it cannot be reached the app falls back
/// to in-process terminals (TerminalRegistry checks `phase`).
final class RuntimeClient {
    static let shared = RuntimeClient()

    static func submissionParts(_ text: String, provider: AgentProvider) -> [Data] {
        let enter = provider == .terminal
            ? Data([0x0D])
            : Data([0x1B, 0x5B, 0x31, 0x33, 0x75])
        return [Data(text.utf8), enter]
    }

    enum Phase { case idle, connecting, ready, failed }

    struct LaunchSpec {
        var shell: String
        var args: [String]
        var env: [String]
        var cwd: String
    }

    /// Read from the main thread by TerminalRegistry; written on `queue`.
    private(set) var phase: Phase = .idle

    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.runtime-client")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var inbox = Data()
    /// Session ids the daemon reported alive at handshake.
    private var aliveSessions: Set<String> = []
    private var pendingOpens: [(sid: String, spec: LaunchSpec, cols: Int, rows: Int)] = []

    /// Delivered on the main queue.
    private var dataHandlers: [String: (Data) -> Void] = [:]
    private var exitHandlers: [String: (Int32?) -> Void] = [:]
    /// One-shot replay-buffer readers keyed by sid (control-plane `peek`).
    private var peekHandlers: [String: (Data?) -> Void] = [:]

    /// True once the daemon handshake completed and sessions are known.
    var isReady: Bool { phase == .ready }

    static var socketPath: String {
        ProjectStore.defaultDirectory().appendingPathComponent(RuntimeProtocol.socketName).path
    }

    private static var daemonURL: URL? {
        Bundle.main.url(forResource: "uncoil-runtimed", withExtension: nil)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            phase = .connecting
            // First-ever run: the App Support dir may not exist yet.
            try? FileManager.default.createDirectory(
                at: ProjectStore.defaultDirectory(), withIntermediateDirectories: true
            )
            if !connect() {
                spawnDaemon()
                var attempts = 0
                while attempts < 20, !connect() {
                    attempts += 1
                    usleep(100_000)
                }
            }
            if fd >= 0 {
                NSLog("[uncoil-runtime] connected fd=%d", fd)
                beginReading()
                sendCommand(RuntimeCommand.hello())
            } else {
                NSLog("[uncoil-runtime] connect failed, falling back to in-process PTYs")
                phase = .failed
                flushPendingAsFailed()
            }
        }
    }

    private func connect() -> Bool {
        let path = Self.socketPath
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(sock)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            return false
        }
        fd = sock
        return true
    }

    private func spawnDaemon() {
        guard let daemon = Self.daemonURL else { return }
        let process = Process()
        process.executableURL = daemon
        process.arguments = [Self.socketPath]
        try? process.run()
    }

    private func beginReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 128 * 1024)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            disconnect()
            return
        }
        inbox.append(contentsOf: chunk[0..<count])
        while let newline = inbox.firstIndex(of: UInt8(ascii: "\n")) {
            let line = inbox[inbox.startIndex..<newline]
            inbox = Data(inbox[inbox.index(after: newline)...])
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(RuntimeEventMessage.self, from: Data(line))
            else { continue }
            handle(event)
        }
    }

    private func disconnect() {
        readSource?.cancel()
        readSource = nil
        fd = -1
        phase = .failed
        let handlers = exitHandlers
        exitHandlers.removeAll()
        dataHandlers.removeAll()
        DispatchQueue.main.async {
            for handler in handlers.values { handler(nil) }
        }
    }

    private func handle(_ event: RuntimeEventMessage) {
        switch event.ev {
        case "hello":
            sendCommand(RuntimeCommand(cmd: "list"))
        case "sessions":
            aliveSessions = Set(event.sids ?? [])
            phase = .ready
            NSLog("[uncoil-runtime] ready, alive=%@", aliveSessions.joined(separator: ","))
            let pending = pendingOpens
            pendingOpens.removeAll()
            for open in pending {
                openLocked(sid: open.sid, spec: open.spec, cols: open.cols, rows: open.rows)
            }
        case "data":
            if let sid = event.sid, let b64 = event.b64, let data = Data(base64Encoded: b64),
               let handler = dataHandlers[sid] {
                DispatchQueue.main.async { handler(data) }
            }
        case "replay":
            if let sid = event.sid, let handler = peekHandlers[sid] {
                peekHandlers[sid] = nil
                let data = event.b64.flatMap { Data(base64Encoded: $0) } ?? Data()
                DispatchQueue.main.async { handler(data) }
            }
        case "exited":
            if let sid = event.sid {
                aliveSessions.remove(sid)
                let code = event.code
                if let handler = exitHandlers[sid] {
                    DispatchQueue.main.async { handler(code) }
                }
            }
        default:
            break
        }
    }

    private func sendCommand(_ command: RuntimeCommand) {
        guard fd >= 0, let data = Data.runtimeLine(command) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func flushPendingAsFailed() {
        let pending = pendingOpens
        pendingOpens.removeAll()
        DispatchQueue.main.async { [self] in
            for open in pending { exitHandlers[open.sid]?(nil) }
        }
    }

    // MARK: - Session API (callable from the main thread)

    /// Launches the session in the daemon, or reattaches if it is already
    /// alive there (app restart). Handlers are invoked on the main queue.
    func open(
        sid: UUID,
        spec: LaunchSpec,
        cols: Int,
        rows: Int,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (Int32?) -> Void
    ) {
        let key = sid.uuidString
        queue.async { [self] in
            dataHandlers[key] = onData
            exitHandlers[key] = onExit
            switch phase {
            case .ready:
                openLocked(sid: key, spec: spec, cols: cols, rows: rows)
            case .failed:
                DispatchQueue.main.async { onExit(nil) }
            default:
                pendingOpens.append((key, spec, cols, rows))
            }
        }
    }

    private func openLocked(sid: String, spec: LaunchSpec, cols: Int, rows: Int) {
        NSLog("[uncoil-runtime] open sid=%@ attach=%d", sid, aliveSessions.contains(sid) ? 1 : 0)
        if aliveSessions.contains(sid) {
            sendCommand(RuntimeCommand(cmd: "attach", sid: sid))
        } else {
            aliveSessions.insert(sid)
            sendCommand(RuntimeCommand(
                cmd: "launch", sid: sid,
                shell: spec.shell, args: spec.args, env: spec.env, cwd: spec.cwd,
                cols: cols, rows: rows
            ))
        }
    }

    func sendInput(_ data: Data, sid: UUID) {
        let key = sid.uuidString
        queue.async { [self] in
            sendCommand(RuntimeCommand(cmd: "input", sid: key, b64: data.base64EncodedString()))
        }
    }

    func resize(sid: UUID, cols: Int, rows: Int) {
        let key = sid.uuidString
        queue.async { [self] in
            sendCommand(RuntimeCommand(cmd: "resize", sid: key, cols: cols, rows: rows))
        }
    }

    /// Whether the daemon reported this session alive at/after handshake.
    /// Read on `queue`; call from `queue` contexts or via the async peek.
    func sessionIsAlive(_ sid: UUID, completion: @escaping (Bool) -> Void) {
        let key = sid.uuidString
        queue.async { [self] in
            let alive = phase == .ready && aliveSessions.contains(key)
            DispatchQueue.main.async { completion(alive) }
        }
    }

    /// Reads the daemon's replay buffer for a session WITHOUT attaching.
    /// Returns nil if the daemon is unreachable or the session isn't alive.
    func peek(sid: UUID, timeout: TimeInterval = 5) async -> Data? {
        await withCheckedContinuation { continuation in
            let key = sid.uuidString
            queue.async { [self] in
                guard phase == .ready, aliveSessions.contains(key) else {
                    continuation.resume(returning: nil)
                    return
                }
                peekHandlers[key] = { data in continuation.resume(returning: data) }
                sendCommand(RuntimeCommand(cmd: "peek", sid: key))
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let handler = self.peekHandlers[key] else { return }
                    self.peekHandlers[key] = nil
                    handler(nil)
                }
            }
        }
    }

    /// Sends raw bytes to a live session's PTY (control-plane send_text).
    func sendText(_ data: Data, sid: UUID) {
        sendInput(data, sid: sid)
    }

    func submitText(_ text: String, sid: UUID, provider: AgentProvider) async {
        let parts = Self.submissionParts(text, provider: provider)
        sendInput(parts[0], sid: sid)
        try? await Task.sleep(nanoseconds: 300_000_000)
        sendInput(parts[1], sid: sid)
    }

    func waitUntilInputReady(
        sid: UUID,
        provider: AgentProvider,
        timeout: TimeInterval = 12
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = -1
        var stableSince = Date()
        var firstOutputAt: Date?

        while Date() < deadline {
            if let buffer = await peek(sid: sid, timeout: 1), !buffer.isEmpty {
                let now = Date()
                if firstOutputAt == nil {
                    firstOutputAt = now
                }
                if provider == .claude,
                   String(decoding: buffer, as: UTF8.self).contains("manual mode on") {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return
                }
                if buffer.count != lastSize {
                    lastSize = buffer.count
                    stableSince = now
                } else if let firstOutputAt,
                          now.timeIntervalSince(stableSince) >= 1,
                          now.timeIntervalSince(firstOutputAt) >= 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Sends Ctrl-C (0x03) to a live session.
    func interrupt(sid: UUID) {
        sendInput(Data([0x03]), sid: sid)
    }

    func kill(sid: UUID) {
        let key = sid.uuidString
        queue.async { [self] in
            aliveSessions.remove(key)
            dataHandlers[key] = nil
            exitHandlers[key] = nil
            sendCommand(RuntimeCommand(cmd: "kill", sid: key))
        }
    }
}
