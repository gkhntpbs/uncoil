import Darwin
import Foundation

/// uncoil-runtimed — owns session PTYs so agents survive Uncoil restarts.
/// Usage: uncoil-runtimed <socket-path>
///
/// Security: the socket lives in the user-private Application Support dir,
/// is chmod 0600, and every accepted peer's euid is checked against ours
/// via LOCAL_PEERCRED before any command is processed.

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: uncoil-runtimed <socket-path>\n".utf8))
    exit(64)
}
let socketPath = CommandLine.arguments[1]

// Detach from the launching app's session so quitting Uncoil never signals us.
setsid()
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

final class RuntimeLog {
    private var url: URL?

    func configure(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("runtime.log")
    }

    func write(_ message: String) {
        guard let url else { return }
        rotateIfNeeded(url)
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= RuntimeProtocol.logFileLimit else { return }
        let manager = FileManager.default
        for index in stride(from: RuntimeProtocol.logGenerations - 1, through: 1, by: -1) {
            let source = url.appendingPathExtension("\(index)")
            let destination = url.appendingPathExtension("\(index + 1)")
            try? manager.removeItem(at: destination)
            if manager.fileExists(atPath: source.path) {
                try? manager.moveItem(at: source, to: destination)
            }
        }
        let first = url.appendingPathExtension("1")
        try? manager.removeItem(at: first)
        if manager.fileExists(atPath: url.path) {
            try? manager.moveItem(at: url, to: first)
        }
    }
}

let runtimeLog = RuntimeLog()

// MARK: - PTY session

final class PTYSession {
    let sid: String
    let masterFD: Int32
    let pid: pid_t
    var buffer = Data()
    var readSource: DispatchSourceRead?
    var exitCode: Int32?
    let replayURL: URL
    var lastActivity = Date()
    var lastIdleReport = Date.distantPast
    /// When the last client detached; nil while a client is attached. Together
    /// with `lastActivity` this is what marks a session abandoned.
    var unattachedSince: Date? = Date()
    /// Cumulative CPU time (user+system, ns) at the last health tick. Any
    /// growth counts as activity: an agent that wakes now and then to check a
    /// date produces no terminal output, but it does burn CPU when it wakes.
    var lastCPUTime: UInt64 = 0
    /// Stopped with SIGSTOP and waiting for SIGCONT. A stopped process burns no
    /// CPU and writes nothing, which is indistinguishable from an abandoned one
    /// — so the reaper has to be told the difference.
    var isSuspended = false
    /// fd of the single attached client, if any.
    var attachedFD: Int32? {
        didSet { unattachedSince = attachedFD == nil ? Date() : nil }
    }

    init(sid: String, masterFD: Int32, pid: pid_t, replayURL: URL) {
        self.sid = sid
        self.masterFD = masterFD
        self.pid = pid
        self.replayURL = replayURL
    }
}

enum SpawnError: Error { case openptyFailed, spawnFailed(Int32) }

func spawnPTY(shell: String, args: [String], env: [String], cwd: String, cols: Int, rows: Int) throws -> (Int32, pid_t) {
    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw SpawnError.openptyFailed }
    let slavePath = String(cString: ttyname(slave))

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    // With SETSID, opening the tty (fd 0) makes it the controlling terminal.
    posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
    posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
    posix_spawn_file_actions_addclose(&fileActions, master)
    posix_spawn_file_actions_addclose(&fileActions, slave)
    posix_spawn_file_actions_addchdir_np(&fileActions, cwd)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = ([shell] + args).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
    }
    let rc = posix_spawn(&pid, shell, &fileActions, &attr, argv, envp)
    close(slave)
    guard rc == 0 else {
        close(master)
        throw SpawnError.spawnFailed(rc)
    }
    return (master, pid)
}

// MARK: - Server

final class RuntimeDaemon {
    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.runtimed")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private var clientVerified: Set<Int32> = []
    private var sessions: [String: PTYSession] = [:]
    /// Live task claims, keyed "<project>|<task>". The daemon arbitrates because
    /// it is the one process that outlives the app and sees a session's PTY exit,
    /// so a claim can never outlive the agent that took it.
    private var taskClaims: [String: RuntimeTaskClaim] = [:]
    private var lockFD: Int32 = -1
    private var healthSource: DispatchSourceTimer?
    private var replayDirectory: URL?
    private var isDrainingForUpgrade = false
    /// Scheduled scan, if the app asked for one. The daemon keeps it running after
    /// the app quits — that is the whole point of scheduling it here — and refuses
    /// to start a second one while the first is still going.
    private var scanSchedule: ScanSchedule?

    private struct ScanSchedule {
        var binary: String
        var args: [String]
        var interval: TimeInterval
        var timeout: TimeInterval
        var outputPath: String?
        var timer: DispatchSourceTimer?
        var isRunning = false
        var lastStartedAt: Date?
        var lastExitCode: Int32?
        var runs = 0
    }

    func start(socketPath: String) throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        runtimeLog.configure(directory: directory)
        let lockPath = socketPath + ".lock"
        lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw POSIXError(.EADDRINUSE)
        }
        var fileLimit = rlimit(rlim_cur: 1024, rlim_max: 1024)
        _ = setrlimit(RLIMIT_NOFILE, &fileLimit)
        var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &coreLimit)
        let replayDirectory = directory.appendingPathComponent("replays", isDirectory: true)
        try? FileManager.default.createDirectory(at: replayDirectory, withIntermediateDirectories: true)
        self.replayDirectory = replayDirectory
        pruneReplayDirectory()
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }

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
        guard bindResult == 0 else {
            let code = errno
            close(listenFD)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EADDRINUSE)
        }
        guard listen(listenFD, 16) == 0 else {
            let code = errno
            close(listenFD)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL)
        }
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
        startHealthChecks()
        runtimeLog.write("daemon started")
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard peerIsCurrentUser(fd) else {
            close(fd)
            return
        }
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
        guard getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, &cred, &length) == 0 else {
            return false
        }
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
            if !line.isEmpty, let command = try? JSONDecoder().decode(RuntimeCommand.self, from: Data(line)) {
                handle(command, from: fd)
            }
            if clientSources[fd] == nil { return }  // dropped mid-drain
        }
        clientBuffers[fd] = Data(buffer)
    }

    private func dropClient(_ fd: Int32) {
        clientSources[fd]?.cancel()
        clientSources[fd] = nil
        clientBuffers[fd] = nil
        clientVerified.remove(fd)
        for session in sessions.values where session.attachedFD == fd {
            session.attachedFD = nil
        }
        runtimeLog.write("client disconnected")
    }

    private func send<T: Encodable>(_ message: T, to fd: Int32) {
        guard let data = Data.runtimeLine(message) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    // MARK: Command handling

    private func handle(_ command: RuntimeCommand, from fd: Int32) {
        if command.cmd == "hello" {
            let compatibility = RuntimeProtocol.negotiate(
                peerVersion: command.version,
                peerMinor: command.minor
            )
            guard case .compatible(let negotiatedMinor) = compatibility else {
                guard case .incompatible(let message) = compatibility else { return }
                send(RuntimeEventMessage(
                    ev: "error",
                    version: RuntimeProtocol.version,
                    minor: RuntimeProtocol.minor,
                    errorCode: "incompatible_protocol",
                    message: message
                ), to: fd)
                dropClient(fd)
                return
            }
            clientVerified.insert(fd)
            send(RuntimeEventMessage(
                ev: "hello",
                version: RuntimeProtocol.version,
                minor: negotiatedMinor
            ), to: fd)
            return
        }
        guard clientVerified.contains(fd) else {
            dropClient(fd)
            return
        }

        switch command.cmd {
        case "ping":
            send(RuntimeEventMessage(
                ev: "pong",
                version: RuntimeProtocol.version,
                minor: RuntimeProtocol.minor
            ), to: fd)
        case "list":
            let alive = sessions.values.filter { $0.exitCode == nil }.map(\.sid)
            send(RuntimeEventMessage(ev: "sessions", sids: alive), to: fd)
        case "launch":
            if isDrainingForUpgrade {
                send(RuntimeEventMessage(
                    ev: "error",
                    sid: command.sid,
                    errorCode: "daemon_upgrading",
                    message: "The runtime daemon is upgrading and is not accepting new sessions."
                ), to: fd)
            } else {
                launch(command, from: fd)
            }
        case "attach":
            attach(command, from: fd)
        case "input":
            if let sid = command.sid, let b64 = command.b64,
               let data = Data(base64Encoded: b64), let session = sessions[sid] {
                session.lastActivity = .now
                data.withUnsafeBytes { raw in
                    _ = write(session.masterFD, raw.baseAddress, raw.count)
                }
            }
        case "resize":
            if let sid = command.sid, let cols = command.cols, let rows = command.rows,
               let session = sessions[sid], cols > 0, rows > 0 {
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                if ioctl(session.masterFD, TIOCSWINSZ, &size) == 0 {
                    let foregroundGroup = tcgetpgrp(session.masterFD)
                    if foregroundGroup > 0 {
                        _ = Darwin.kill(-foregroundGroup, SIGWINCH)
                    } else {
                        _ = Darwin.kill(-session.pid, SIGWINCH)
                    }
                }
            }
        case "peek":
            // Return the replay buffer WITHOUT attaching (control-plane read).
            if let sid = command.sid, let session = sessions[sid] {
                send(RuntimeEventMessage(ev: "replay", sid: sid,
                                         b64: session.buffer.base64EncodedString()), to: fd)
            } else {
                send(RuntimeEventMessage(ev: "error", sid: command.sid, message: "no such session"), to: fd)
            }
        case "task_claim":
            send(claimTask(command), to: fd)
        case "task_heartbeat":
            send(heartbeatTask(command), to: fd)
        case "task_release":
            send(releaseTask(command), to: fd)
        case "task_claims":
            pruneTaskClaims()
            send(
                RuntimeEventMessage(ev: "task_claims", claims: Array(taskClaims.values)),
                to: fd
            )
        case "scan_schedule":
            send(scheduleScan(command), to: fd)
        case "scan_status":
            send(scanStatus(), to: fd)
        case "scan_cancel":
            cancelScan()
            send(scanStatus(), to: fd)
        case "suspend", "resume":
            send(signalSession(command), to: fd)
        case "kill":
            if let sid = command.sid { kill(sid: sid) }
        case "shutdown":
            for sid in Array(sessions.keys) { kill(sid: sid) }
            exit(0)
        case "upgrade":
            isDrainingForUpgrade = true
            runtimeLog.write("graceful upgrade requested")
            exitIfUpgradeIsDrained()
        default:
            send(RuntimeEventMessage(ev: "error", message: "unknown command"), to: fd)
        }
    }

    private func launch(_ command: RuntimeCommand, from fd: Int32) {
        guard let sid = command.sid,
              UUID(uuidString: sid) != nil,
              let shell = command.shell,
              let replayDirectory else { return }
        // Relaunch for an existing sid replaces the old process.
        if sessions[sid] != nil { kill(sid: sid) }
        do {
            let (master, pid) = try spawnPTY(
                shell: shell,
                args: command.args ?? [],
                env: command.env ?? [],
                cwd: command.cwd ?? NSHomeDirectory(),
                cols: command.cols ?? 80,
                rows: command.rows ?? 24
            )
            let replayURL = replayDirectory.appendingPathComponent("\(sid).log")
            try? FileManager.default.removeItem(at: replayURL)
            let session = PTYSession(sid: sid, masterFD: master, pid: pid, replayURL: replayURL)
            session.attachedFD = fd
            sessions[sid] = session
            startReading(session)
            runtimeLog.write("session launched \(sid)")
        } catch {
            send(RuntimeEventMessage(ev: "error", sid: sid, message: "spawn failed: \(error)"), to: fd)
        }
    }

    private func attach(_ command: RuntimeCommand, from fd: Int32) {
        guard let sid = command.sid, let session = sessions[sid] else {
            send(RuntimeEventMessage(ev: "error", sid: command.sid, message: "no such session"), to: fd)
            return
        }
        session.attachedFD = fd
        if !session.buffer.isEmpty {
            send(RuntimeEventMessage(ev: "data", sid: sid, b64: session.buffer.base64EncodedString()), to: fd)
        }
        if let code = session.exitCode {
            send(RuntimeEventMessage(ev: "exited", sid: sid, code: code), to: fd)
        }
    }

    private func startReading(_ session: PTYSession) {
        let source = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: queue)
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(session.masterFD, &chunk, chunk.count)
            if count > 0 {
                let data = Data(chunk[0..<count])
                session.buffer.append(data)
                session.lastActivity = .now
                if session.buffer.count > RuntimeProtocol.replayBufferLimit {
                    session.buffer.removeFirst(session.buffer.count - RuntimeProtocol.replayBufferLimit)
                }
                self.persistReplay(session)
                if let fd = session.attachedFD {
                    self.send(RuntimeEventMessage(ev: "data", sid: session.sid, b64: data.base64EncodedString()), to: fd)
                }
            } else {
                self.reap(session)
            }
        }
        source.resume()
        session.readSource = source
    }

    private func reap(_ session: PTYSession, status knownStatus: Int32? = nil) {
        session.readSource?.cancel()
        session.readSource = nil
        var status = knownStatus ?? 0
        if knownStatus == nil {
            _ = waitpid(session.pid, &status, WNOHANG)
        }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        session.exitCode = Int32(code)
        close(session.masterFD)
        if let fd = session.attachedFD {
            send(RuntimeEventMessage(ev: "exited", sid: session.sid, code: session.exitCode), to: fd)
        }
        sessions[session.sid] = nil
        try? FileManager.default.removeItem(at: session.replayURL)
        runtimeLog.write("session exited \(session.sid) code=\(code)")
        exitIfUpgradeIsDrained()
    }

    /// SIGSTOP / SIGCONT for a session's process group.
    ///
    /// The group, not the pid: the child called `setsid`, and an agent CLI is a
    /// tree — stopping only the leader leaves its children running, which is
    /// exactly the CPU the user asked to get back.
    ///
    /// The signal goes to the session's own group rather than the terminal's
    /// foreground group. `tcgetpgrp` reports whoever holds the terminal right
    /// now, which for a stopped session is nobody — so resuming would have
    /// nothing to signal and the session would never come back.
    private func signalSession(_ command: RuntimeCommand) -> RuntimeEventMessage {
        guard let sid = command.sid, let session = sessions[sid] else {
            return RuntimeEventMessage(
                ev: "error", sid: command.sid,
                errorCode: "no_such_session", message: "no such session"
            )
        }
        guard session.exitCode == nil else {
            return RuntimeEventMessage(
                ev: "error", sid: sid,
                errorCode: "session_exited", message: "the session has already exited"
            )
        }
        let suspending = command.cmd == "suspend"
        guard Darwin.kill(-session.pid, suspending ? SIGSTOP : SIGCONT) == 0 else {
            return RuntimeEventMessage(
                ev: "error", sid: sid,
                errorCode: "signal_failed",
                message: "could not \(command.cmd) the session"
            )
        }
        session.isSuspended = suspending
        // A stopped session produces no output, and the reaper treats silence
        // plus no attachment as abandoned. Without this a session suspended
        // overnight would be killed rather than resumed.
        session.lastActivity = .now
        runtimeLog.write("session \(suspending ? "suspended" : "resumed") \(sid)")
        return RuntimeEventMessage(ev: suspending ? "suspended" : "resumed", sid: sid)
    }

    private func kill(sid: String) {
        guard let session = sessions[sid] else { return }
        session.readSource?.cancel()
        session.readSource = nil
        // Signal the whole process group (the child called setsid).
        Darwin.kill(-session.pid, SIGTERM)
        close(session.masterFD)
        var status: Int32 = 0
        waitpid(session.pid, &status, WNOHANG)
        sessions[sid] = nil
        try? FileManager.default.removeItem(at: session.replayURL)
        runtimeLog.write("session terminated \(sid)")
        exitIfUpgradeIsDrained()
    }

    private func persistReplay(_ session: PTYSession) {
        guard let replayDirectory else { return }
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: replayDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let otherBytes = files
            .filter { $0 != session.replayURL }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let allowed = max(0, RuntimeProtocol.replayDiskLimit - otherBytes)
        if session.buffer.count > allowed {
            session.buffer.removeFirst(session.buffer.count - allowed)
        }
        try? session.buffer.write(to: session.replayURL, options: .atomic)
    }

    private func pruneReplayDirectory() {
        guard let replayDirectory else { return }
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: replayDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? manager.removeItem(at: file) }
    }

    private func startHealthChecks() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in self?.checkSessionHealth() }
        source.resume()
        healthSource = source
    }

    private func checkSessionHealth() {
        for session in sessions.values {
            var status: Int32 = 0
            let result = waitpid(session.pid, &status, WNOHANG)
            if result == session.pid {
                reap(session, status: status)
                continue
            }
            if result == -1 && errno == ECHILD {
                reap(session, status: -1)
                continue
            }
            // CPU growth counts as activity even without terminal output, so
            // an agent quietly waiting on a timer or a date is never treated
            // as abandoned while it keeps waking up.
            var usage = rusage_info_current()
            let cpuResult = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(session.pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            if cpuResult == 0 {
                let cpu = usage.ri_user_time &+ usage.ri_system_time
                if cpu != session.lastCPUTime {
                    session.lastCPUTime = cpu
                    session.lastActivity = Date()
                }
            }
            let idle = Date().timeIntervalSince(session.lastActivity)
            // Abandoned: no client attached for a full day AND no output in as
            // long. Without this, sessions left behind by closed apps (or dev
            // builds) accumulate forever, each keeping an agent CLI and its
            // MCP helper alive.
            // A suspended session looks exactly like an abandoned one — no
            // output, no CPU, nobody attached — but it was stopped on purpose
            // and is waiting to be resumed. Reaping it would answer "pause
            // this" with "this is gone".
            if session.isSuspended { continue }
            if let unattached = session.unattachedSince,
               Date().timeIntervalSince(unattached) >= RuntimeProtocol.sessionAbandonedThreshold,
               idle >= RuntimeProtocol.sessionAbandonedThreshold {
                runtimeLog.write("session abandoned \(session.sid); terminating")
                kill(sid: session.sid)
                continue
            }
            if idle >= RuntimeProtocol.sessionIdleThreshold,
               Date().timeIntervalSince(session.lastIdleReport) >= RuntimeProtocol.sessionIdleThreshold {
                session.lastIdleReport = .now
                if let fd = session.attachedFD {
                    send(RuntimeEventMessage(
                        ev: "error",
                        sid: session.sid,
                        errorCode: "session_idle",
                        message: "The session has produced no output for an hour."
                    ), to: fd)
                }
                runtimeLog.write("session idle \(session.sid)")
            }
        }
    }

    // MARK: - Task claims

    private func claimKey(_ command: RuntimeCommand) -> String? {
        guard let taskID = command.task_id else { return nil }
        return "\(command.project_id ?? "-")|\(taskID)"
    }

    /// Grants a claim unless a live one conflicts. Only one implementer at a
    /// time; a different role attaches alongside, and the same session renews.
    private func claimTask(_ command: RuntimeCommand) -> RuntimeEventMessage {
        pruneTaskClaims()
        guard let key = claimKey(command), let taskID = command.task_id,
              let sid = command.sid, let role = command.role else {
            return RuntimeEventMessage(
                ev: "error", errorCode: "invalid_request",
                message: "task_claim needs task_id, sid and role"
            )
        }
        let now = Date().timeIntervalSince1970
        let duration = min(max(command.duration_s ?? RuntimeProtocol.taskLeaseDuration, 60), 3600)

        if let existing = taskClaims[key] {
            let sameSession = existing.owner_sid == sid
            // "implementer" is the only exclusive role; everything else coexists.
            let conflicts = !sameSession && existing.role == "implementer" && role == "implementer"
            if conflicts {
                return RuntimeEventMessage(
                    ev: "task_claim", message: "held by another implementer",
                    task_id: taskID, granted: false,
                    owner_sid: existing.owner_sid, role: existing.role,
                    expires_at: existing.expires_at, generation: existing.generation
                )
            }
            if sameSession {
                var renewed = existing
                renewed.acquired_at = now
                renewed.expires_at = now + duration
                renewed.last_heartbeat = now
                renewed.generation += 1
                taskClaims[key] = renewed
                runtimeLog.write("task claim renewed \(key) by \(sid)")
                return RuntimeEventMessage(
                    ev: "task_claim", task_id: taskID, granted: true,
                    owner_sid: sid, role: renewed.role,
                    expires_at: renewed.expires_at, generation: renewed.generation
                )
            }
        }

        let claim = RuntimeTaskClaim(
            task_id: taskID, project_id: command.project_id, owner_sid: sid,
            role: role, acquired_at: now, expires_at: now + duration,
            generation: 1, last_heartbeat: now,
            session_known: sessions[sid] != nil
        )
        // A non-exclusive role does not displace an exclusive holder's record.
        if taskClaims[key] == nil || role == "implementer" {
            taskClaims[key] = claim
        }
        runtimeLog.write("task claim granted \(key) by \(sid) as \(role)")
        return RuntimeEventMessage(
            ev: "task_claim", task_id: taskID, granted: true,
            owner_sid: sid, role: role,
            expires_at: claim.expires_at, generation: claim.generation
        )
    }

    private func heartbeatTask(_ command: RuntimeCommand) -> RuntimeEventMessage {
        pruneTaskClaims()
        guard let key = claimKey(command), let taskID = command.task_id,
              let sid = command.sid, var claim = taskClaims[key], claim.owner_sid == sid else {
            return RuntimeEventMessage(
                ev: "task_claim", message: "no claim to renew",
                task_id: command.task_id, granted: false
            )
        }
        let now = Date().timeIntervalSince1970
        claim.last_heartbeat = now
        claim.expires_at = now + min(
            max(command.duration_s ?? RuntimeProtocol.taskLeaseDuration, 60), 3600
        )
        claim.generation += 1
        taskClaims[key] = claim
        return RuntimeEventMessage(
            ev: "task_claim", task_id: taskID, granted: true,
            owner_sid: sid, role: claim.role,
            expires_at: claim.expires_at, generation: claim.generation
        )
    }

    private func releaseTask(_ command: RuntimeCommand) -> RuntimeEventMessage {
        guard let key = claimKey(command), let sid = command.sid,
              let claim = taskClaims[key], claim.owner_sid == sid else {
            return RuntimeEventMessage(
                ev: "task_claim", message: "not the owner",
                task_id: command.task_id, granted: false
            )
        }
        taskClaims.removeValue(forKey: key)
        runtimeLog.write("task claim released \(key)")
        return RuntimeEventMessage(
            ev: "task_claim", task_id: command.task_id, granted: true
        )
    }

    /// Drops claims that expired, went quiet, or belong to a session the daemon
    /// no longer has — the three ways an agent stops holding a task.
    // MARK: - Scheduled scans

    /// Takes a scan schedule from the app. One schedule at a time: a second
    /// request replaces the first rather than stacking timers.
    private func scheduleScan(_ command: RuntimeCommand) -> RuntimeEventMessage {
        guard let binary = command.scan_binary, !binary.isEmpty else {
            return RuntimeEventMessage(
                ev: "error", message: "scan_binary required", scan_scheduled: false
            )
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            // Not installed is an ordinary answer, not a failure to hide.
            runtimeLog.write("scan not scheduled: \(binary) is not executable")
            return RuntimeEventMessage(
                ev: "scan_status",
                message: "binary not executable",
                scan_scheduled: false,
                scan_running: false
            )
        }
        let interval = max(60, command.interval_s ?? 24 * 60 * 60)
        cancelScan()
        var schedule = ScanSchedule(
            binary: binary,
            args: command.scan_args ?? [],
            interval: interval,
            timeout: max(10, command.timeout_s ?? 300),
            outputPath: command.output_path
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fires once now and then on the interval; the app asks for this only when
        // a scan is already due.
        timer.schedule(deadline: .now() + 1, repeating: interval)
        timer.setEventHandler { [weak self] in self?.runScheduledScan() }
        schedule.timer = timer
        scanSchedule = schedule
        timer.resume()
        runtimeLog.write("scan scheduled every \(Int(interval))s: \(binary)")
        return scanStatus()
    }

    private func cancelScan() {
        scanSchedule?.timer?.cancel()
        scanSchedule?.timer = nil
        scanSchedule = nil
    }

    private func scanStatus() -> RuntimeEventMessage {
        RuntimeEventMessage(
            ev: "scan_status",
            scan_scheduled: scanSchedule != nil,
            scan_running: scanSchedule?.isRunning ?? false,
            scan_last_started_at: scanSchedule?.lastStartedAt?.timeIntervalSince1970,
            scan_last_exit_code: scanSchedule?.lastExitCode,
            scan_runs: scanSchedule?.runs ?? 0
        )
    }

    /// Runs the scan. Never two at once: a slow scan is skipped rather than
    /// queued, because two scanners over the same files is worse than one late.
    private func runScheduledScan() {
        guard var schedule = scanSchedule else { return }
        if schedule.isRunning {
            runtimeLog.write("scan skipped: previous run still going")
            return
        }
        schedule.isRunning = true
        schedule.lastStartedAt = Date()
        schedule.runs += 1
        scanSchedule = schedule

        let process = Process()
        process.executableURL = URL(fileURLWithPath: schedule.binary)
        process.arguments = schedule.args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            runtimeLog.write("scan failed to start: \(error)")
            scanSchedule?.isRunning = false
            scanSchedule?.lastExitCode = -1
            return
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        queue.asyncAfter(deadline: .now() + schedule.timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        // The result is written where the app will find it on its next launch;
        // the daemon does not interpret it.
        if let path = scanSchedule?.outputPath, !data.isEmpty {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        scanSchedule?.isRunning = false
        scanSchedule?.lastExitCode = process.terminationStatus
        runtimeLog.write(
            "scan finished: exit \(process.terminationStatus), \(data.count) bytes"
        )
    }

    private func pruneTaskClaims() {
        let now = Date().timeIntervalSince1970
        let silenceLimit = RuntimeProtocol.taskLeaseDuration
        for (key, claim) in taskClaims {
            let expired = now >= claim.expires_at
            let silent = now - claim.last_heartbeat > silenceLimit
            let sessionGone = claim.session_known && sessions[claim.owner_sid] == nil
            if expired || silent || sessionGone {
                taskClaims.removeValue(forKey: key)
                runtimeLog.write(
                    "task claim dropped \(key): " +
                    (expired ? "expired" : silent ? "no heartbeat" : "session gone")
                )
            }
        }
    }

    private func exitIfUpgradeIsDrained() {
        guard isDrainingForUpgrade, sessions.isEmpty else { return }
        runtimeLog.write("graceful upgrade completed")
        exit(0)
    }
}

let daemon = RuntimeDaemon()
do {
    try daemon.start(socketPath: socketPath)
} catch {
    FileHandle.standardError.write(Data("uncoil-runtimed: \(error.localizedDescription) (\(socketPath))\n".utf8))
    exit(1)
}
dispatchMain()
