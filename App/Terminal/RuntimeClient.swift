import AppKit
import Darwin
import Foundation

/// Connects Uncoil to uncoil-runtimed over the user-private Unix socket.
/// Spawns the daemon on demand; if it cannot be reached the app falls back
/// to in-process terminals (TerminalRegistry checks `phase`).
final class RuntimeClient: @unchecked Sendable {
    static let shared = RuntimeClient(
        socketPath: RuntimeClient.socketPath,
        daemonURL: RuntimeClient.defaultDaemonURL,
        observesWorkspaceNotifications: true
    )

    static func submissionParts(_ text: String, provider: AgentProvider) -> [Data] {
        let enter = provider == .terminal
            ? Data([0x0D])
            : Data([0x1B, 0x5B, 0x31, 0x33, 0x75])
        return [Data(text.utf8), enter]
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case failed
        case incompatible(String)
    }

    struct LaunchSpec {
        var shell: String
        var args: [String]
        var env: [String]
        var cwd: String
        var runLogPath: String? = nil
    }

    /// Called on the main queue each time the daemon reports which sessions it
    /// still has, which is at every handshake — launch and reconnect alike.
    var onAliveSessions: ((Set<UUID>) -> Void)?

    /// Read from the main thread by TerminalRegistry; written on `queue`.
    private(set) var phase: Phase = .idle

    /// Owns the connection fd and closes it when the last dispatch source
    /// registered on it has finished cancelling.
    ///
    /// Cancellation is asynchronous, so closing the fd by hand while a source
    /// is still registered on it is a libdispatch fault — and with a read
    /// source and a write source sharing this one fd there is no moment at
    /// which doing it by hand is safe.
    private final class SocketFD {
        let value: Int32
        private var registeredSources = 0
        private var isOpen = true

        init(_ value: Int32) { self.value = value }

        func retain() { registeredSources += 1 }

        func release() {
            registeredSources -= 1
            guard registeredSources <= 0, isOpen else { return }
            isOpen = false
            close(value)
        }
    }

    private let queue = DispatchQueue(label: "com.gokhantopbas.uncoil.runtime-client")
    private var fd: Int32 = -1
    private var connection: SocketFD?
    private var readSource: DispatchSourceRead?
    /// What has been queued for the daemon and not yet accepted by the socket.
    private var outbox = Data()
    private var writeSource: DispatchSourceWrite?
    private var writeSourceIsPaused = false
    private var heartbeatSource: DispatchSourceTimer?
    /// Armed at connect, disarmed by the daemon's `hello`.
    private var handshakeWatchdog: DispatchWorkItem?
    /// Consecutive handshakes a daemon has failed to answer. Two is what it
    /// takes before the daemon is treated as wedged rather than busy.
    private var unansweredHandshakes = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var preservesSessionsOnReconnect = false
    private var isSystemSleeping = false
    private var lastPong = Date.distantPast
    private(set) var negotiatedMinor = 0
    private var inbox = Data()
    /// Session ids the daemon reported alive at handshake.
    private var aliveSessions: Set<String> = []
    private var sessionPIDs: [String: Int32] = [:]
    private var pendingOpens: [(sid: String, spec: LaunchSpec, cols: Int, rows: Int)] = []

    /// Delivered on the main queue.
    private var dataHandlers: [String: (Data) -> Void] = [:]
    private var exitHandlers: [String: (Int32?) -> Void] = [:]
    /// One-shot replay-buffer readers keyed by sid (control-plane `peek`).
    private var peekHandlers: [String: (Data?) -> Void] = [:]
    private let configuredSocketPath: String
    private let configuredDaemonURL: URL?
    private var workspaceObservers: [NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }

    /// True once the daemon handshake completed and sessions are known.
    var isReady: Bool { phase == .ready }

    static var socketPath: String {
        ProjectStore.defaultDirectory().appendingPathComponent(RuntimeProtocol.socketName).path
    }

    static var defaultDaemonURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uncoil-runtimed")
    }

    init(
        socketPath: String,
        daemonURL: URL?,
        observesWorkspaceNotifications: Bool
    ) {
        configuredSocketPath = socketPath
        configuredDaemonURL = daemonURL
        guard observesWorkspaceNotifications else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSystemSleep()
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSystemWake()
        })
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard phase == .idle || phase == .failed else { return }
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempts = 0
            startLocked()
        }
    }

    private func startLocked() {
        guard fd < 0 else { return }
        phase = .connecting
        let socketDirectory = URL(fileURLWithPath: configuredSocketPath)
            .deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: socketDirectory, withIntermediateDirectories: true
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
            armHandshakeWatchdog()
        } else {
            NSLog("[uncoil-runtime] connect failed")
            phase = .failed
            scheduleReconnect()
        }
    }

    private func connect() -> Bool {
        let path = configuredSocketPath
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        // The daemon goes away for ordinary reasons — it is upgraded, it is
        // ended after a stall, it crashes — and a write to a socket whose peer
        // has gone raises SIGPIPE, whose default action is to end *this*
        // process. The daemon guards itself the same way at its own entry
        // point; without the same guard here the `written < 0` branch in
        // `drainOutbox()` is unreachable, because the signal arrives before
        // the error does.
        var noSignalOnBrokenPipe: Int32 = 1
        setsockopt(
            sock, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignalOnBrokenPipe, socklen_t(MemoryLayout<Int32>.size)
        )
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
        // Non-blocking: a daemon that stops reading must cost the app a
        // backlog, never the runtime queue. A blocking `write` here froze this
        // queue behind the daemon, which took the heartbeat — the one thing
        // that would have noticed — down with it.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        connection = SocketFD(sock)
        fd = sock
        return true
    }

    private func spawnDaemon() {
        guard let daemon = configuredDaemonURL else { return }
        let process = Process()
        process.executableURL = daemon
        process.arguments = [configuredSocketPath]
        try? process.run()
    }

    private func beginReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        if let connection {
            source.setCancelHandler { connection.release() }
            connection.retain()
        }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 128 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return
        }
        guard count > 0 else {
            disconnect(restart: true)
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

    private func disconnect(restart: Bool = false, notifyHandlers: Bool = true) {
        stopHeartbeat()
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
        teardownWriteSource()
        readSource?.cancel()
        readSource = nil
        connection = nil
        fd = -1
        if case .incompatible = phase {
        } else {
            phase = .failed
        }
        if notifyHandlers {
            let handlers = exitHandlers
            exitHandlers.removeAll()
            dataHandlers.removeAll()
            preservesSessionsOnReconnect = false
            DispatchQueue.main.async {
                for handler in handlers.values { handler(nil) }
            }
        } else {
            preservesSessionsOnReconnect = true
        }
        if restart, !isIncompatiblePhase, !isSystemSleeping {
            scheduleReconnect()
        }
    }

    private var isIncompatiblePhase: Bool {
        if case .incompatible = phase { return true }
        return false
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < 5, reconnectWorkItem == nil else { return }
        reconnectAttempts += 1
        let delay = min(pow(2, Double(reconnectAttempts - 1)), 16)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard self.fd < 0, !self.isIncompatiblePhase else { return }
            self.startLocked()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handle(_ event: RuntimeEventMessage) {
        switch event.ev {
        case "hello":
            switch RuntimeProtocol.negotiate(
                peerVersion: event.version,
                peerMinor: event.minor
            ) {
            case .compatible(let minor):
                handshakeWatchdog?.cancel()
                handshakeWatchdog = nil
                unansweredHandshakes = 0
                negotiatedMinor = minor
                lastPong = .now
                startHeartbeat()
                sendCommand(RuntimeCommand(cmd: "list"))
            case .incompatible(let message):
                failCompatibility(message)
            }
        case "started":
            if let sid = event.sid, let pid = event.process_id { sessionPIDs[sid] = pid }
        case "sessions":
            aliveSessions = Set(event.sids ?? [])
            sessionPIDs = event.session_pids ?? [:]
            phase = .ready
            reconnectAttempts = 0
            // The daemon's answer to "what survived?" — the only thing that
            // knows, since agents outlive the app. Handed up so the sidebar can
            // stop calling every restored session closed until it is clicked.
            let reported = Set(aliveSessions.compactMap(UUID.init(uuidString:)))
            if let onAliveSessions {
                DispatchQueue.main.async { onAliveSessions(reported) }
            }
            NSLog("[uncoil-runtime] ready, alive=%@", aliveSessions.joined(separator: ","))
            let pending = pendingOpens
            pendingOpens.removeAll()
            for open in pending {
                openLocked(sid: open.sid, spec: open.spec, cols: open.cols, rows: open.rows)
            }
            let attached = dataHandlers.keys.filter { aliveSessions.contains($0) }
            for sid in attached {
                sendCommand(RuntimeCommand(cmd: "attach", sid: sid))
            }
            if preservesSessionsOnReconnect {
                let missing = dataHandlers.keys.filter { !aliveSessions.contains($0) }
                preservesSessionsOnReconnect = false
                for sid in missing {
                    let handler = exitHandlers.removeValue(forKey: sid)
                    dataHandlers.removeValue(forKey: sid)
                    if let handler {
                        DispatchQueue.main.async { handler(nil) }
                    }
                }
            }
        case "pong":
            lastPong = .now
        case "error":
            if event.errorCode == nil, let sid = event.sid, let handler = exitHandlers.removeValue(forKey: sid) {
                aliveSessions.remove(sid)
                dataHandlers.removeValue(forKey: sid)
                DispatchQueue.main.async { handler(nil) }
            }
            if phase == .connecting,
               event.errorCode == "incompatible_protocol",
               let message = event.message {
                failCompatibility(message)
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
                sessionPIDs[sid] = nil
                let code = event.code
                if let handler = exitHandlers[sid] {
                    DispatchQueue.main.async { handler(code) }
                }
                // The session is gone; keeping its handlers would pin the
                // captured view state for the rest of the app's lifetime.
                dataHandlers.removeValue(forKey: sid)
                exitHandlers.removeValue(forKey: sid)
            }
        default:
            break
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            if Date().timeIntervalSince(self.lastPong) > 15 {
                self.disconnect(restart: true)
                return
            }
            self.sendCommand(RuntimeCommand(cmd: "ping"))
        }
        source.resume()
        heartbeatSource = source
    }

    private func stopHeartbeat() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
    }

    /// How long the daemon has to answer `hello`. A daemon that is running
    /// answers in microseconds; this is the budget for one that is merely
    /// loaded, at a moment — app launch — when the machine often is.
    private static let handshakeTimeout: TimeInterval = 10

    /// Notices a daemon that accepted the connection and then said nothing.
    ///
    /// The heartbeat only starts once the handshake completes, so before that
    /// there was nothing watching: a daemon stuck inside a blocking call still
    /// accepts connections — the kernel does that — and then never reads them.
    /// The app connected, sent `hello`, and waited forever, which is what a
    /// session that opens onto an empty terminal looks like from the outside.
    private func armHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.handshakeWatchdog != nil, self.phase == .connecting else { return }
            self.handshakeWatchdog = nil
            self.unansweredHandshakes += 1
            NSLog(
                "[uncoil-runtime] no handshake within %.0fs (attempt %d)",
                Self.handshakeTimeout, self.unansweredHandshakes
            )
            // Once is a daemon having a bad moment; twice is a daemon that is
            // not coming back, and reconnecting to it forever is what made
            // this survive quitting the app.
            if self.unansweredHandshakes >= 2 { self.endUnresponsiveDaemon() }
            self.disconnect(restart: true, notifyHandlers: false)
        }
        handshakeWatchdog = work
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: work)
    }

    /// Ends a daemon that has twice failed to answer, so the next connect
    /// spawns a fresh one.
    ///
    /// The pid comes from the lock file the daemon writes when it takes the
    /// lock, and the process is only signalled if it is still a uncoil-runtimed
    /// — a pid outlives nothing so reliably as a pid, and killing whatever
    /// inherited the number would be far worse than the freeze.
    private func endUnresponsiveDaemon() {
        unansweredHandshakes = 0
        let lockPath = configuredSocketPath + RuntimeProtocol.lockSuffix
        guard let text = try? String(contentsOfFile: lockPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1
        else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0,
              String(cString: buffer).hasSuffix("/uncoil-runtimed")
        else { return }
        NSLog("[uncoil-runtime] ending unresponsive daemon pid=%d", pid)
        _ = Darwin.kill(pid, SIGKILL)
        unlink(configuredSocketPath)
    }

    private func failCompatibility(_ message: String) {
        phase = .incompatible(message)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .runtimeCompatibilityError,
                object: message
            )
        }
        disconnect()
    }

    func handleSystemSleep() {
        queue.async { [self] in
            isSystemSleeping = true
            stopHeartbeat()
        }
    }

    func handleSystemWake() {
        queue.async { [self] in
            isSystemSleeping = false
            guard phase == .ready, fd >= 0 else {
                if phase == .failed { startLocked() }
                return
            }
            lastPong = .distantPast
            startHeartbeat()
            sendCommand(RuntimeCommand(cmd: "ping"))
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self,
                      self.phase == .ready,
                      Date().timeIntervalSince(self.lastPong) > 5 else { return }
                self.disconnect(restart: true, notifyHandlers: false)
            }
        }
    }

    /// Queues a command and writes what the socket will take.
    ///
    /// Never blocks. This looped on a blocking `write` until the whole command
    /// was gone, on the serial queue that carries every runtime call the app
    /// makes — so a daemon that stopped reading held the queue, and with it
    /// the heartbeat that exists to notice exactly that. The app then sat
    /// silently on a dead connection: no error, no reconnect, and every new
    /// session opening onto a terminal that never printed anything.
    private func sendCommand(_ command: RuntimeCommand) {
        guard fd >= 0, let data = Data.runtimeLine(command) else { return }
        outbox.append(data)
        drainOutbox()
    }

    private func drainOutbox() {
        guard fd >= 0 else {
            outbox = Data()
            return
        }
        while !outbox.isEmpty {
            let written = outbox.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!, raw.count)
            }
            if written > 0 {
                outbox.removeFirst(written)
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                break
            }
            outbox = Data()
            disconnect(restart: true)
            return
        }
        if outbox.isEmpty {
            suspendWriteSource()
        } else if outbox.count > RuntimeProtocol.clientBacklogLimit {
            outbox = Data()
            disconnect(restart: true)
        } else {
            resumeWriteSource()
        }
    }

    private func resumeWriteSource() {
        if let source = writeSource {
            if writeSourceIsPaused {
                writeSourceIsPaused = false
                source.resume()
            }
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainOutbox() }
        if let connection {
            source.setCancelHandler { connection.release() }
            connection.retain()
        }
        writeSource = source
        source.resume()
    }

    /// A write source armed with nothing to write wakes the app every time the
    /// socket is writable, which is constantly.
    private func suspendWriteSource() {
        guard let source = writeSource, !writeSourceIsPaused else { return }
        writeSourceIsPaused = true
        source.suspend()
    }

    /// A suspended dispatch source cannot be released, so it is resumed on the
    /// way out; cancelling it while suspended would trap.
    private func teardownWriteSource() {
        outbox = Data()
        guard let source = writeSource else { return }
        if writeSourceIsPaused {
            writeSourceIsPaused = false
            source.resume()
        }
        source.cancel()
        writeSource = nil
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
                cols: cols, rows: rows, run_log_path: spec.runLogPath
            ))
        }
    }

    func attachExisting(
        sid: UUID,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (Int32?) -> Void
    ) {
        queue.async { [self] in
            let key = sid.uuidString
            guard phase == .ready, aliveSessions.contains(key) else {
                DispatchQueue.main.async { onExit(nil) }
                return
            }
            dataHandlers[key] = onData
            exitHandlers[key] = onExit
            sendCommand(RuntimeCommand(cmd: "attach", sid: key))
        }
    }

    func terminateOwnedSession(sid: UUID) {
        queue.async { [self] in
            sendCommand(RuntimeCommand(cmd: "run_stop", sid: sid.uuidString))
        }
    }

    func connectionIsReady() -> Bool {
        queue.sync { phase == .ready }
    }

    func supportsManagedRuns() -> Bool {
        queue.sync { phase == .ready && negotiatedMinor >= 4 }
    }

    func aliveSessionIDs() -> Set<UUID> {
        queue.sync { Set(aliveSessions.compactMap(UUID.init(uuidString:))) }
    }

    func processID(sid: UUID) -> Int32? {
        queue.sync { sessionPIDs[sid.uuidString] }
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

    /// Asks the daemon again what it still has, producing another `sessions`
    /// event.
    ///
    /// The handshake asks once. A session the daemon left out of that one
    /// answer is not yet gone — it may have replied while restarting, before
    /// re-adopting what it had — so the second look is asked for deliberately
    /// rather than waited for.
    func requestSessionList() {
        queue.async { [self] in
            guard phase == .ready, fd >= 0 else { return }
            sendCommand(RuntimeCommand(cmd: "list"))
        }
    }

    /// Sends Ctrl-C (0x03) to a live session.
    func interrupt(sid: UUID) {
        sendInput(Data([0x03]), sid: sid)
    }

    /// Whether the daemon reported this session alive. False before the
    /// handshake lands, so a caller must treat it as "no process to talk to"
    /// rather than as proof the session died.
    func isAlive(sid: UUID) -> Bool {
        queue.sync { aliveSessions.contains(sid.uuidString) }
    }

    /// Stops or restarts a session's process group without ending it.
    ///
    /// Handlers stay registered, unlike `kill`: the session is coming back, and
    /// dropping them would leave a resumed process writing to nobody.
    func setSuspended(_ suspended: Bool, sid: UUID) {
        let key = sid.uuidString
        queue.async { [self] in
            sendCommand(RuntimeCommand(cmd: suspended ? "suspend" : "resume", sid: key))
        }
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

    /// Hands a scheduled scan to the daemon, which keeps running it after the app
    /// quits. Uncoil does not install the binary; it only says where one is.
    func scheduleScan(
        binaryPath: String,
        arguments: [String],
        intervalSeconds: TimeInterval,
        timeoutSeconds: TimeInterval,
        outputPath: String
    ) {
        queue.async { [self] in
            guard phase == .ready else { return }
            sendCommand(RuntimeCommand(
                cmd: "scan_schedule",
                scan_binary: binaryPath,
                scan_args: arguments,
                interval_s: intervalSeconds,
                timeout_s: timeoutSeconds,
                output_path: outputPath
            ))
        }
    }

    func cancelScheduledScan() {
        queue.async { [self] in
            guard phase == .ready else { return }
            sendCommand(RuntimeCommand(cmd: "scan_cancel"))
        }
    }

    func requestGracefulUpgrade() {
        queue.async { [self] in
            guard phase == .ready else { return }
            sendCommand(RuntimeCommand(cmd: "upgrade"))
        }
    }

    func prepareForApplicationTermination(terminateSessions: Bool, managedRuns: Bool = false) {
        queue.sync { [self] in
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            isSystemSleeping = true
            if terminateSessions, phase == .ready {
                sendCommand(RuntimeCommand(cmd: managedRuns ? "run_shutdown" : "shutdown"))
            }
            disconnect(restart: false, notifyHandlers: false)
        }
    }
}
