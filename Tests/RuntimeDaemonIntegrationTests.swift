import Darwin
import Foundation
import XCTest
@testable import Uncoil

final class RuntimeDaemonIntegrationTests: XCTestCase {
    func testHandshakeAndHeartbeat() throws {
        try withDaemon { socketPath, process in
            let fd = try connect(to: socketPath)
            defer { close(fd) }

            try send(RuntimeCommand.hello(), to: fd)
            let hello = try receive(from: fd)
            XCTAssertEqual(hello.ev, "hello")
            XCTAssertEqual(hello.version, RuntimeProtocol.version)

            try send(RuntimeCommand(cmd: "ping"), to: fd)
            let pong = try receive(from: fd)
            XCTAssertEqual(pong.ev, "pong")

            try send(RuntimeCommand(cmd: "shutdown"), to: fd)
            XCTAssertTrue(waitForExit(process, timeout: 3))
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testSecondDaemonCannotReplaceLiveSocket() throws {
        try withDaemon { socketPath, first in
            let second = try startDaemon(socketPath: socketPath)
            XCTAssertTrue(waitForExit(second, timeout: 3))
            XCTAssertNotEqual(second.terminationStatus, 0)

            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")
            try send(RuntimeCommand(cmd: "ping"), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "pong")
            try send(RuntimeCommand(cmd: "shutdown"), to: fd)
            XCTAssertTrue(waitForExit(first, timeout: 3))
        }
    }

    func testKeepSessionsRunningDisconnectsWithoutStoppingDaemon() throws {
        try withDaemon { socketPath, process in
            let client = RuntimeClient(
                socketPath: socketPath,
                daemonURL: try daemonURL(),
                observesWorkspaceNotifications: false
            )
            client.start()
            XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .ready })

            let sessionFD = try connect(to: socketPath)
            defer { close(sessionFD) }
            try send(RuntimeCommand.hello(), to: sessionFD)
            XCTAssertEqual(try receive(from: sessionFD).ev, "hello")
            let sid = UUID().uuidString
            try send(RuntimeCommand(
                cmd: "launch",
                sid: sid,
                shell: "/bin/sleep",
                args: ["20"],
                env: [],
                cwd: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
                cols: 80,
                rows: 24
            ), to: sessionFD)

            client.prepareForApplicationTermination(terminateSessions: false)
            XCTAssertTrue(process.isRunning)

            let verifier = try connect(to: socketPath)
            defer { close(verifier) }
            try send(RuntimeCommand.hello(), to: verifier)
            XCTAssertEqual(try receive(from: verifier).ev, "hello")
            try send(RuntimeCommand(cmd: "list"), to: verifier)
            let sessions = try receive(from: verifier)
            XCTAssertTrue((sessions.sids ?? []).contains(sid))

            try send(RuntimeCommand(cmd: "shutdown"), to: verifier)
            XCTAssertTrue(waitForExit(process, timeout: 3))
        }
    }

    func testTerminateAllAgentsOnQuitStopsDaemon() throws {
        try withDaemon { socketPath, process in
            let client = RuntimeClient(
                socketPath: socketPath,
                daemonURL: try daemonURL(),
                observesWorkspaceNotifications: false
            )
            client.start()
            XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .ready })

            let sessionFD = try connect(to: socketPath)
            defer { close(sessionFD) }
            try send(RuntimeCommand.hello(), to: sessionFD)
            XCTAssertEqual(try receive(from: sessionFD).ev, "hello")
            try send(RuntimeCommand(
                cmd: "launch",
                sid: UUID().uuidString,
                shell: "/bin/sleep",
                args: ["20"],
                env: [],
                cwd: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
                cols: 80,
                rows: 24
            ), to: sessionFD)

            client.prepareForApplicationTermination(terminateSessions: true)

            XCTAssertTrue(waitForExit(process, timeout: 3))
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testVersionMismatchIsExplicitAndDaemonRemainsAvailable() throws {
        try withDaemon { socketPath, process in
            let rejectedFD = try connect(to: socketPath)
            var incompatible = RuntimeCommand.hello()
            incompatible.version = RuntimeProtocol.version + 1
            try send(incompatible, to: rejectedFD)
            let error = try receive(from: rejectedFD)
            XCTAssertEqual(error.ev, "error")
            XCTAssertEqual(error.errorCode, "incompatible_protocol")
            close(rejectedFD)

            let validFD = try connect(to: socketPath)
            defer { close(validFD) }
            try send(RuntimeCommand.hello(), to: validFD)
            XCTAssertEqual(try receive(from: validFD).ev, "hello")
            try send(RuntimeCommand(cmd: "shutdown"), to: validFD)
            XCTAssertTrue(waitForExit(process, timeout: 3))
        }
    }

    func testGracefulUpgradeExitsWhenNoSessionsRemain() throws {
        try withDaemon { socketPath, process in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")
            try send(RuntimeCommand(cmd: "upgrade"), to: fd)
            XCTAssertTrue(waitForExit(process, timeout: 3))
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testReplayFileStaysWithinPerSessionAndGlobalLimits() throws {
        try withDaemon { socketPath, process in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")

            let sid = UUID().uuidString
            try send(RuntimeCommand(
                cmd: "launch",
                sid: sid,
                shell: "/bin/sh",
                args: ["-c", "/usr/bin/yes x | /usr/bin/head -c 700000; /bin/sleep 5"],
                env: [],
                cwd: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
                cols: 80,
                rows: 24
            ), to: fd)

            var receivedBytes = 0
            let deadline = Date().addingTimeInterval(4)
            while receivedBytes < 600_000, Date() < deadline {
                let event = try receive(from: fd)
                if event.ev == "data", let b64 = event.b64 {
                    receivedBytes += Data(base64Encoded: b64)?.count ?? 0
                }
            }
            XCTAssertGreaterThanOrEqual(receivedBytes, 600_000)

            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let replayURL = root.appendingPathComponent("replays/\(sid).log")
            let replaySize = try replayURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertLessThanOrEqual(replaySize, RuntimeProtocol.replayBufferLimit)
            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("replays"),
                includingPropertiesForKeys: [.fileSizeKey]
            )
            let total = try files.reduce(0) {
                $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            XCTAssertLessThanOrEqual(total, RuntimeProtocol.replayDiskLimit)

            try send(RuntimeCommand(cmd: "kill", sid: sid), to: fd)
            try send(RuntimeCommand(cmd: "shutdown"), to: fd)
            XCTAssertTrue(waitForExit(process, timeout: 3))
        }
    }

    func testRuntimeLogRotatesAtConfiguredLimit() throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("runtime.log")
        try Data(repeating: 0x41, count: RuntimeProtocol.logFileLimit).write(to: logURL)
        let socketPath = root.appendingPathComponent("runtime.sock").path
        let process = try startDaemon(socketPath: socketPath)
        defer {
            if process.isRunning {
                process.terminate()
                _ = waitForExit(process, timeout: 2)
            }
        }
        XCTAssertTrue(waitForSocket(socketPath, timeout: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))

        let fd = try connect(to: socketPath)
        defer { close(fd) }
        try send(RuntimeCommand.hello(), to: fd)
        XCTAssertEqual(try receive(from: fd).ev, "hello")
        try send(RuntimeCommand(cmd: "shutdown"), to: fd)
        XCTAssertTrue(waitForExit(process, timeout: 3))
    }

    func testSleepWakeReconnectsAfterDaemonExit() throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("runtime.sock").path
        let first = try startDaemon(socketPath: socketPath)
        defer {
            if first.isRunning {
                first.terminate()
                _ = waitForExit(first, timeout: 2)
            }
        }
        XCTAssertTrue(waitForSocket(socketPath, timeout: 3))

        let client = RuntimeClient(
            socketPath: socketPath,
            daemonURL: try daemonURL(),
            observesWorkspaceNotifications: false
        )
        client.start()
        XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .ready })

        client.handleSystemSleep()
        usleep(100_000)
        first.terminate()
        XCTAssertTrue(waitForExit(first, timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .failed })

        client.handleSystemWake()
        XCTAssertTrue(waitUntil(timeout: 5) { client.phase == .ready })

        client.handleSystemSleep()
        usleep(100_000)
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        try send(RuntimeCommand.hello(), to: fd)
        XCTAssertEqual(try receive(from: fd).ev, "hello")
        try send(RuntimeCommand(cmd: "shutdown"), to: fd)
        XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .failed })
    }

    func testClientRestartsDaemonAfterCrash() throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("runtime.sock").path
        let first = try startDaemon(socketPath: socketPath)
        defer {
            if first.isRunning {
                first.terminate()
                _ = waitForExit(first, timeout: 2)
            }
        }
        XCTAssertTrue(waitForSocket(socketPath, timeout: 3))

        let client = RuntimeClient(
            socketPath: socketPath,
            daemonURL: try daemonURL(),
            observesWorkspaceNotifications: false
        )
        client.start()
        XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .ready })

        first.terminate()
        XCTAssertTrue(waitForExit(first, timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 6) { client.phase == .ready })

        client.handleSystemSleep()
        usleep(100_000)
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        try send(RuntimeCommand.hello(), to: fd)
        XCTAssertEqual(try receive(from: fd).ev, "hello")
        try send(RuntimeCommand(cmd: "shutdown"), to: fd)
        XCTAssertTrue(waitUntil(timeout: 3) { client.phase == .failed })
    }

    func testExitedChildIsReapedAndReplayRemoved() throws {
        try withDaemon { socketPath, process in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")

            let sid = UUID().uuidString
            try send(RuntimeCommand(
                cmd: "launch",
                sid: sid,
                shell: "/usr/bin/true",
                args: [],
                env: [],
                cwd: URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
                cols: 80,
                rows: 24
            ), to: fd)

            var exited = false
            let deadline = Date().addingTimeInterval(3)
            while !exited, Date() < deadline {
                let event = try receive(from: fd)
                exited = event.ev == "exited" && event.sid == sid
            }
            XCTAssertTrue(exited)

            try send(RuntimeCommand(cmd: "list"), to: fd)
            let sessions = try receive(from: fd)
            XCTAssertEqual(sessions.ev, "sessions")
            XCTAssertFalse((sessions.sids ?? []).contains(sid))
            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("replays/\(sid).log").path
            ))

            try send(RuntimeCommand(cmd: "shutdown"), to: fd)
            XCTAssertTrue(waitForExit(process, timeout: 3))
        }
    }

    private func withDaemon(
        _ body: (String, Process) throws -> Void
    ) throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("runtime.sock").path
        let process = try startDaemon(socketPath: socketPath)
        defer {
            if process.isRunning {
                process.terminate()
                _ = waitForExit(process, timeout: 2)
            }
        }
        XCTAssertTrue(waitForSocket(socketPath, timeout: 3))
        try body(socketPath, process)
    }

    private func startDaemon(socketPath: String) throws -> Process {
        let process = Process()
        process.executableURL = try daemonURL()
        process.arguments = [socketPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func daemonURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let testHost = environment["TEST_HOST"] {
            let app = URL(fileURLWithPath: testHost)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(
                app.appendingPathComponent("Contents/Helpers/uncoil-runtimed")
            )
        }
        if let products = environment["BUILT_PRODUCTS_DIR"] {
            candidates.append(
                URL(fileURLWithPath: products)
                    .appendingPathComponent("Uncoil.app/Contents/Helpers/uncoil-runtimed")
            )
        }
        candidates.append(
            Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Uncoil.app/Contents/Helpers/uncoil-runtimed")
        )
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRoot.appendingPathComponent(
                ".build-cache/DerivedData/Build/Products/Debug/"
                    + "Uncoil.app/Contents/Helpers/uncoil-runtimed"
            )
        )
        guard let source = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("uncoil-runtimed bulunamadı")
        }
        let stagingRoot = sourceRoot
            .appendingPathComponent(".build-cache/rt-bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let executable = stagingRoot.appendingPathComponent(
            "uncoil-runtimed-\(UUID().uuidString.prefix(8))"
        )
        try FileManager.default.copyItem(at: source, to: executable)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", executable.path]
        signer.standardOutput = Pipe()
        signer.standardError = Pipe()
        try signer.run()
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else {
            throw POSIXError(.EPERM)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: executable)
        }
        return executable
    }

    private func testRoot() throws -> URL {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = sourceRoot
            .appendingPathComponent(".build-cache/rt", isDirectory: true)
            .appendingPathComponent(
                String(UUID().uuidString.prefix(8)),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForSocket(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            usleep(20_000)
        }
        return false
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        return !process.isRunning
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
        return fd
    }

    private func send<T: Encodable>(_ message: T, to fd: Int32) throws {
        let data = try XCTUnwrap(Data.runtimeLine(message))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let result = write(
                    fd,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset
                )
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private func receive(from fd: Int32) throws -> RuntimeEventMessage {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") {
                return try JSONDecoder().decode(RuntimeEventMessage.self, from: data)
            }
            data.append(byte)
        }
        throw POSIXError(.ETIMEDOUT)
    }
}
