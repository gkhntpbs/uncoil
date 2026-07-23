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

// MARK: - PTY session

final class PTYSession {
    let sid: String
    let masterFD: Int32
    let pid: pid_t
    var buffer = Data()
    var readSource: DispatchSourceRead?
    var exitCode: Int32?
    /// fd of the single attached client, if any.
    var attachedFD: Int32?

    init(sid: String, masterFD: Int32, pid: pid_t) {
        self.sid = sid
        self.masterFD = masterFD
        self.pid = pid
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

    func start(socketPath: String) throws {
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
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
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
            guard command.version == RuntimeProtocol.version else {
                send(RuntimeEventMessage(ev: "error", message: "version mismatch"), to: fd)
                dropClient(fd)
                return
            }
            clientVerified.insert(fd)
            send(RuntimeEventMessage(ev: "hello", version: RuntimeProtocol.version), to: fd)
            return
        }
        guard clientVerified.contains(fd) else {
            dropClient(fd)
            return
        }

        switch command.cmd {
        case "list":
            let alive = sessions.values.filter { $0.exitCode == nil }.map(\.sid)
            send(RuntimeEventMessage(ev: "sessions", sids: alive), to: fd)
        case "launch":
            launch(command, from: fd)
        case "attach":
            attach(command, from: fd)
        case "input":
            if let sid = command.sid, let b64 = command.b64,
               let data = Data(base64Encoded: b64), let session = sessions[sid] {
                data.withUnsafeBytes { raw in
                    _ = write(session.masterFD, raw.baseAddress, raw.count)
                }
            }
        case "resize":
            if let sid = command.sid, let cols = command.cols, let rows = command.rows,
               let session = sessions[sid], cols > 0, rows > 0 {
                var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(session.masterFD, TIOCSWINSZ, &size)
            }
        case "kill":
            if let sid = command.sid { kill(sid: sid) }
        case "shutdown":
            for sid in sessions.keys { kill(sid: sid) }
            exit(0)
        default:
            send(RuntimeEventMessage(ev: "error", message: "unknown command"), to: fd)
        }
    }

    private func launch(_ command: RuntimeCommand, from fd: Int32) {
        guard let sid = command.sid, let shell = command.shell else { return }
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
            let session = PTYSession(sid: sid, masterFD: master, pid: pid)
            session.attachedFD = fd
            sessions[sid] = session
            startReading(session)
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
                if session.buffer.count > RuntimeProtocol.replayBufferLimit {
                    session.buffer.removeFirst(session.buffer.count - RuntimeProtocol.replayBufferLimit)
                }
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

    private func reap(_ session: PTYSession) {
        session.readSource?.cancel()
        session.readSource = nil
        var status: Int32 = 0
        waitpid(session.pid, &status, WNOHANG)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        session.exitCode = Int32(code)
        close(session.masterFD)
        if let fd = session.attachedFD {
            send(RuntimeEventMessage(ev: "exited", sid: session.sid, code: session.exitCode), to: fd)
        }
        sessions[session.sid] = nil
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
    }
}

let daemon = RuntimeDaemon()
do {
    try daemon.start(socketPath: socketPath)
} catch {
    FileHandle.standardError.write(Data("uncoil-runtimed: bind failed on \(socketPath)\n".utf8))
    exit(1)
}
dispatchMain()
