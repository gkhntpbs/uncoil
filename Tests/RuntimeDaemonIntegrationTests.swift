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
        XCTAssertTrue(waitForSocket(socketPath, timeout: socketTimeout))
        // Rotation happens when the daemon next writes a log line, not when it
        // configures the directory, so the rotated file is waited for rather
        // than asserted the instant the socket appears.
        XCTAssertTrue(waitUntil(timeout: socketTimeout) {
            FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path)
        })

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
        XCTAssertTrue(waitForSocket(socketPath, timeout: socketTimeout))

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
        XCTAssertTrue(waitForSocket(socketPath, timeout: socketTimeout))

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
        XCTAssertTrue(waitForSocket(socketPath, timeout: socketTimeout))
        try body(socketPath, process)
    }


    // MARK: - Scheduled scans (Aşama 16.4)

    func testTheDaemonRunsAScheduledScanAndWritesItsOutput() throws {
        try withDaemon { socketPath, _ in
            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let script = root.appendingPathComponent("fake-bumblebee.sh")
            let output = root.appendingPathComponent("scan-output.ndjson")
            try """
            #!/bin/sh
            echo '{"type":"scan_summary","scanned":1,"findings":0}'
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path
            )

            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")

            try send(RuntimeCommand(
                cmd: "scan_schedule",
                scan_binary: script.path,
                scan_args: ["scan", "--ndjson"],
                interval_s: 60,
                timeout_s: 10,
                output_path: output.path
            ), to: fd)
            let scheduled = try receive(from: fd)
            XCTAssertEqual(scheduled.ev, "scan_status")
            XCTAssertEqual(scheduled.scan_scheduled, true)

            // The first run fires a second after scheduling: the app asks only when
            // a scan is already due.
            XCTAssertTrue(
                waitUntil(timeout: 8) {
                    FileManager.default.fileExists(atPath: output.path)
                },
                "the daemon should have run the scan and written its output"
            )
            let written = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(written.contains("scan_summary"), written)

            try send(RuntimeCommand(cmd: "scan_status"), to: fd)
            let status = try receive(from: fd)
            XCTAssertEqual(status.scan_scheduled, true)
            XCTAssertEqual(status.scan_last_exit_code, 0)
            XCTAssertGreaterThanOrEqual(status.scan_runs ?? 0, 1)

            try send(RuntimeCommand(cmd: "scan_cancel"), to: fd)
            XCTAssertEqual(try receive(from: fd).scan_scheduled, false)
        }
    }

    func testAScheduledScanKeepsRunningAfterTheAppDisconnects() throws {
        try withDaemon { socketPath, process in
            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let script = root.appendingPathComponent("fake-bumblebee.sh")
            let marker = root.appendingPathComponent("ran.txt")
            try """
            #!/bin/sh
            echo run >> "\(marker.path)"
            echo '{"type":"scan_summary","scanned":1,"findings":0}'
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path
            )

            let fd = try connect(to: socketPath)
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)
            try send(RuntimeCommand(
                cmd: "scan_schedule",
                scan_binary: script.path,
                scan_args: [],
                interval_s: 60,
                timeout_s: 10,
                output_path: root.appendingPathComponent("out.ndjson").path
            ), to: fd)
            _ = try receive(from: fd)

            // The app quits: its connection goes away, the daemon does not.
            close(fd)
            XCTAssertTrue(
                waitUntil(timeout: 8) { FileManager.default.fileExists(atPath: marker.path) },
                "the scan runs with no client connected — that is the point of scheduling it here"
            )
            XCTAssertTrue(process.isRunning, "and the daemon is still up")

            let second = try connect(to: socketPath)
            defer { close(second) }
            try send(RuntimeCommand.hello(), to: second)
            _ = try receive(from: second)
            try send(RuntimeCommand(cmd: "scan_status"), to: second)
            XCTAssertEqual(try receive(from: second).scan_scheduled, true)
        }
    }

    func testASecondScheduleReplacesTheFirstRatherThanStacking() throws {
        try withDaemon { socketPath, _ in
            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let script = root.appendingPathComponent("s.sh")
            try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path
            )
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            for _ in 0..<3 {
                try send(RuntimeCommand(
                    cmd: "scan_schedule", scan_binary: script.path,
                    interval_s: 3_600, timeout_s: 10
                ), to: fd)
                XCTAssertEqual(try receive(from: fd).scan_scheduled, true)
            }
            try send(RuntimeCommand(cmd: "scan_status"), to: fd)
            let status = try receive(from: fd)
            XCTAssertEqual(status.scan_scheduled, true)
            XCTAssertLessThanOrEqual(
                status.scan_runs ?? 0, 1,
                "three requests are one schedule, not three timers"
            )
        }
    }

    func testAMissingScanBinaryIsReportedRatherThanScheduled() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)
            try send(RuntimeCommand(
                cmd: "scan_schedule", scan_binary: "/does/not/exist", interval_s: 60
            ), to: fd)
            let reply = try receive(from: fd)
            XCTAssertEqual(reply.scan_scheduled, false)
            XCTAssertTrue(reply.message?.contains("not executable") ?? false, reply.message ?? "-")
        }
    }

    // MARK: - Load and durability (Aşama 20)

    func testTenSessionsRunAtOnce() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            var sids: [String] = []
            for index in 0..<10 {
                let sid = UUID().uuidString
                sids.append(sid)
                try send(RuntimeCommand(
                    cmd: "launch", sid: sid, shell: "/bin/sh",
                    args: ["-c", "echo session-\(index); sleep 30"],
                    env: [], cwd: NSTemporaryDirectory(), cols: 80, rows: 24
                ), to: fd)
            }
            // Every one of them is live at the same time.
            XCTAssertTrue(
                waitUntil(timeout: 10) {
                    guard (try? send(RuntimeCommand(cmd: "list"), to: fd)) != nil,
                          let listed = try? receive(from: fd) else { return false }
                    return Set(listed.sids ?? []).isSuperset(of: Set(sids))
                },
                "ten concurrent sessions"
            )
            for sid in sids {
                try send(RuntimeCommand(cmd: "kill", sid: sid), to: fd)
            }
        }
    }

    func testASustainedHighVolumeSessionStaysBounded() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            let sid = UUID().uuidString
            // What an hours-long PTY does to Uncoil is produce output without end;
            // this produces the same volume quickly.
            try send(RuntimeCommand(
                cmd: "launch", sid: sid, shell: "/bin/sh",
                args: ["-c", "for i in $(seq 1 4000); do head -c 4096 /dev/zero | tr '\\0' 'x'; echo; done"],
                env: [], cwd: NSTemporaryDirectory(), cols: 80, rows: 24
            ), to: fd)

            let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let replay = root.appendingPathComponent("replays/\(sid).log")
            XCTAssertTrue(
                waitUntil(timeout: 20) {
                    FileManager.default.fileExists(atPath: replay.path)
                },
                "the session should be recording"
            )
            // Give it time to finish producing ~16 MB.
            _ = waitUntil(timeout: 25) {
                let size = (try? replay.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return size >= RuntimeProtocol.replayBufferLimit
            }
            let size = (try? replay.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            XCTAssertLessThanOrEqual(
                size, RuntimeProtocol.replayBufferLimit,
                "the replay is bounded however long the session runs"
            )
            try send(RuntimeCommand(cmd: "kill", sid: sid), to: fd)
        }
    }

    func testASessionSurvivesTheAppQuittingAndIsFoundAgain() throws {
        try withDaemon { socketPath, process in
            let first = try connect(to: socketPath)
            try send(RuntimeCommand.hello(), to: first)
            _ = try receive(from: first)
            let sid = UUID().uuidString
            // It has to produce something: a silent session has nothing to
            // replay, and "nothing to replay" is not evidence of survival.
            try send(RuntimeCommand(
                cmd: "launch", sid: sid, shell: "/bin/sh",
                args: ["-c", "echo hayatta; sleep 30"], env: [], cwd: NSTemporaryDirectory(),
                cols: 80, rows: 24
            ), to: first)
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    guard (try? send(RuntimeCommand(cmd: "list"), to: first)) != nil,
                          let listed = try? receive(from: first) else { return false }
                    return listed.sids?.contains(sid) == true
                }
            )

            // The app goes away without saying goodbye — a quit, a crash, a sleep.
            close(first)
            XCTAssertTrue(process.isRunning)

            // And a fresh connection finds the session still there.
            let second = try connect(to: socketPath)
            defer { close(second) }
            try send(RuntimeCommand.hello(), to: second)
            _ = try receive(from: second)
            try send(RuntimeCommand(cmd: "list"), to: second)
            XCTAssertEqual(try receive(from: second).sids?.contains(sid), true)

            // `peek` reads the replay buffer without attaching, which is exactly
            // the question here: is the output the app missed still there?
            var replayed = ""
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    guard (try? send(RuntimeCommand(cmd: "peek", sid: sid), to: second)) != nil,
                          let reply = try? receive(from: second), reply.ev == "replay" else {
                        return false
                    }
                    replayed = reply.b64
                        .flatMap { Data(base64Encoded: $0) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    return replayed.contains("hayatta")
                },
                "the output produced while no app was connected survived: \(replayed)"
            )
            try send(RuntimeCommand(cmd: "kill", sid: sid), to: second)
        }
    }

    // MARK: - Task claims (Aşama 29)

    func testTwoImplementersCannotHoldTheSameTask() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            XCTAssertEqual(try receive(from: fd).ev, "hello")

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            let granted = try receive(from: fd)
            XCTAssertEqual(granted.ev, "task_claim")
            XCTAssertEqual(granted.granted, true)
            XCTAssertEqual(granted.owner_sid, "session-a")

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-b",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            let refused = try receive(from: fd)
            XCTAssertEqual(refused.granted, false)
            XCTAssertEqual(refused.owner_sid, "session-a", "the refusal names the holder")
        }
    }

    func testATesterAttachesAlongsideAnImplementer() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, true)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-b",
                task_id: "task-1", project_id: "p", role: "tester"
            ), to: fd)
            XCTAssertEqual(
                try receive(from: fd).granted, true,
                "a tester has its own job and must not be locked out"
            )
        }
    }

    func testTaskClaimHolderRenewsAndTheGenerationClimbs() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            let first = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_heartbeat", sid: "session-a", task_id: "task-1", project_id: "p"
            ), to: fd)
            let renewed = try receive(from: fd)
            XCTAssertEqual(renewed.granted, true)
            XCTAssertEqual(renewed.generation, (first.generation ?? 0) + 1)
        }
    }

    func testOnlyTheClaimOwnerCanReleaseOrRenew() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_release", sid: "session-b", task_id: "task-1", project_id: "p"
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, false)

            try send(RuntimeCommand(
                cmd: "task_heartbeat", sid: "session-b", task_id: "task-1", project_id: "p"
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, false)

            try send(RuntimeCommand(
                cmd: "task_release", sid: "session-a", task_id: "task-1", project_id: "p"
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, true)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-b",
                task_id: "task-1", project_id: "p", role: "implementer"
            ), to: fd)
            XCTAssertEqual(
                try receive(from: fd).granted, true,
                "a released task is free for anyone"
            )
        }
    }

    func testClaimListReportsOwnerRoleAndLease() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a", task_id: "task-1",
                project_id: "p", role: "implementer", duration_s: 60
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, true)

            try send(RuntimeCommand(cmd: "task_claims"), to: fd)
            let listed = try receive(from: fd)
            XCTAssertEqual(listed.ev, "task_claims")
            let claim = listed.claims?.first { $0.task_id == "task-1" }
            XCTAssertEqual(claim?.owner_sid, "session-a")
            XCTAssertEqual(claim?.role, "implementer")
            XCTAssertGreaterThan((claim?.expires_at ?? 0) - (claim?.acquired_at ?? 0), 59)
            XCTAssertEqual(
                claim?.session_known, false,
                "the daemon never launched this session, so its absence must not free the claim"
            )
        }
    }

    func testTaskClaimsAreScopedPerProject() throws {
        try withDaemon { socketPath, _ in
            let fd = try connect(to: socketPath)
            defer { close(fd) }
            try send(RuntimeCommand.hello(), to: fd)
            _ = try receive(from: fd)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-a",
                task_id: "task-1", project_id: "p1", role: "implementer"
            ), to: fd)
            XCTAssertEqual(try receive(from: fd).granted, true)

            try send(RuntimeCommand(
                cmd: "task_claim", sid: "session-b",
                task_id: "task-1", project_id: "p2", role: "implementer"
            ), to: fd)
            XCTAssertEqual(
                try receive(from: fd).granted, true,
                "the same task id under another project is a different task"
            )
        }
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

    /// Budget for the daemon to come up. Generous on purpose: these tests spawn
    /// a real helper process, and one of them first makes the daemon rotate a
    /// 1 MB log, which under a full-suite load took longer than a tight window
    /// allowed. A daemon that never starts still fails the assertion.
    private var socketTimeout: TimeInterval { 10 }

    /// Waits for the daemon's socket file to appear.
    ///
    /// Existence alone does not mean the daemon is accepting yet — the file is
    /// created by `bind()` and `connect()` keeps failing with ECONNREFUSED until
    /// `listen()` runs. That window is closed in `connect(to:)` instead of here,
    /// because probing with a throwaway connection would look to the daemon like
    /// a client that connected and left, which is a lifecycle event it acts on.
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

    /// Connects, retrying while the daemon is between `bind()` and `listen()`.
    /// Without the retry, a test that reached this a few microseconds early
    /// failed with "Connection refused" — intermittently, on whichever test in
    /// the suite happened to lose the race.
    private func connect(to path: String, timeout: TimeInterval = 3) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try attemptConnect(to: path)
            } catch let error as POSIXError where error.code == .ECONNREFUSED
                || error.code == .ENOENT {
                guard Date() < deadline else { throw error }
                usleep(20_000)
            }
        }
    }

    private func attemptConnect(to path: String) throws -> Int32 {
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
