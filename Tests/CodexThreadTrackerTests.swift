import Darwin
import XCTest
@testable import Uncoil

final class CodexThreadTrackerTests: XCTestCase {
    // MARK: Rollout

    private func line(_ text: String) -> Data { Data(text.utf8) }

    func testRolloutLinesMapToStatusEvents() {
        XCTAssertEqual(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"2026-10-09T21:43:55.644Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"x"}}"#
        )), .turnStarted)
        XCTAssertEqual(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"t","ordinal":9,"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#
        )), .turnFinished)
        XCTAssertEqual(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"t","ordinal":9,"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
        )), .turnAborted)
        XCTAssertEqual(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"t","ordinal":9,"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch"}}"#
        )), .working)
        XCTAssertNil(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"t","ordinal":9,"type":"response_item","payload":{"type":"message","role":"assistant"}}"#
        )))
        XCTAssertNil(CodexRolloutTail.event(fromLine: line(
            #"{"timestamp":"t","ordinal":0,"type":"session_meta","payload":{"id":"abc"}}"#
        )))
    }

    func testTailReadsOnlyWhatIsAppendedAndWaitsForWholeLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = #"{"timestamp":"t","ordinal":1,"type":"event_msg","payload":{"type":"task_started"}}"#
        try Data((started + "\n").utf8).write(to: url)

        var fromStart = CodexRolloutTail(startingAtEndOf: nil)
        XCTAssertEqual(fromStart.read(url), [.turnStarted])

        var fromEnd = CodexRolloutTail(startingAtEndOf: url)
        XCTAssertEqual(fromEnd.read(url), [])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let finished = #"{"timestamp":"t","ordinal":2,"type":"event_msg","payload":{"type":"task_complete"}}"#
        try handle.write(contentsOf: Data(finished.prefix(30).utf8))
        XCTAssertEqual(fromEnd.read(url), [], "half a line is not an event yet")
        try handle.write(contentsOf: Data((finished.dropFirst(30) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(fromEnd.read(url), [.turnFinished])
        XCTAssertEqual(fromStart.read(url), [.turnFinished])
    }

    // MARK: Process

    func testLockPathsNameTheirThread() {
        XCTAssertEqual(
            CodexProcessProbe.threadID(
                fromLockPath: "/Users/x/.codex/thread-writer-locks/01a12298-572b-7c90-8f3e-dcceb085709d.lock"),
            "01a12298-572b-7c90-8f3e-dcceb085709d"
        )
        XCTAssertNil(CodexProcessProbe.threadID(fromLockPath: "/Users/x/.codex/config.lock"))
        XCTAssertNil(CodexProcessProbe.threadID(fromLockPath: "/tmp/thread-writer-locks/a.txt"))
    }

    func testEnvironmentIsReadFromAProcArgsBuffer() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { buffer += $0 }
        buffer += Array("/opt/homebrew/bin/codex".utf8) + [0, 0, 0]
        buffer += Array("codex".utf8) + [0] + Array("-c".utf8) + [0]
        buffer += Array("HOME=/Users/x".utf8) + [0] + Array("UNCOIL_SESSION_ID=ABC".utf8) + [0, 0]
        XCTAssertEqual(
            CodexProcessProbe.environment(fromProcArgs: buffer),
            ["HOME=/Users/x", "UNCOIL_SESSION_ID=ABC"]
        )
    }

    /// The kernel half, against this very process: a lock file held open
    /// here must be read back as held.
    func testAHeldLockIsReadFromTheProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)/thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let id = "01a1235f-479d-7162-b498-0dfa4c61f7a4"
        let path = directory.appendingPathComponent("\(id).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        let held = CodexProcessProbe.heldThreadIDs(pid: getpid())
        XCTAssertTrue(held.contains { $0.threadID == id && $0.descriptor == descriptor })
    }

    func testTheThreadOnTheRecordWinsWhileItIsStillHeld() {
        let home = FileManager.default.temporaryDirectory
        let held = [
            CodexProcessProbe.HeldLock(descriptor: 12, threadID: "first"),
            CodexProcessProbe.HeldLock(descriptor: 40, threadID: "second"),
        ]
        XCTAssertEqual(CodexTrackingState.mainThread(among: held, current: "second", codexHome: home), "second")
        XCTAssertEqual(CodexTrackingState.mainThread(among: held, current: "gone", codexHome: home), "first")
        XCTAssertNil(CodexTrackingState.mainThread(among: [], current: "gone", codexHome: home))
    }

    // MARK: Index

    func testTheNewestStateDatabaseIsTheOneRead() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["state_4.sqlite", "state_12.sqlite", "state_5.sqlite-wal", "logs_2.sqlite"] {
            try Data().write(to: home.appendingPathComponent(name))
        }
        XCTAssertEqual(CodexThreadIndex.databaseURL(codexHome: home)?.lastPathComponent, "state_12.sqlite")
    }
}

/// Against a real Codex session Uncoil is running. Set
/// `UNCOIL_CODEX_LIVE_SESSION` to the session's id to run it.
final class CodexThreadTrackerLiveTests: XCTestCase {
    func testALiveSessionIsFoundWithItsThread() throws {
        guard let value = ProcessInfo.processInfo.environment["UNCOIL_CODEX_LIVE_SESSION"],
              let sessionID = UUID(uuidString: value) else {
            throw XCTSkip("Set UNCOIL_CODEX_LIVE_SESSION to a running Codex session's id")
        }
        let pid = try XCTUnwrap(CodexProcessProbe.codexProcess(sessionID: sessionID))
        let held = CodexProcessProbe.heldThreadIDs(pid: pid)
        let home = CodexSessionStore.defaultHome()
        let thread = try XCTUnwrap(CodexTrackingState.mainThread(among: held, current: nil, codexHome: home))
        let row = CodexThreadIndex.thread(id: thread, codexHome: home)
        print("LIVE pid=\(pid) held=\(held.map(\.threadID)) main=\(thread) title=\(row?.title ?? "-") rollout=\(row?.rolloutPath ?? "-")")
    }
}

final class CodexRolloutRecoveryTests: XCTestCase {
    private func line(_ kind: String, _ type: String) -> String {
        #"{"timestamp":"2026-10-23T03:01:40.920Z","ordinal":3,"type":"\#(kind)","payload":{"type":"\#(type)","x":1}}"#
    }

    func testLastEventIsTheTurnInFlight() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = [
            line("event_msg", "task_started"),
            line("event_msg", "task_complete"),
            line("event_msg", "task_started"),
            line("response_item", "reasoning"),
            line("response_item", "custom_tool_call"),
            line("event_msg", "token_count"),
        ].joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexRolloutTail.lastEvent(in: url), .working)
    }

    func testAWindowStartingMidLineSkipsThePartialLine() {
        let data = Data((#"payload":{"type":"task_complete"}}"# + "\n" + line("event_msg", "task_started") + "\n").utf8)
        XCTAssertEqual(CodexRolloutTail.events(in: data, dropFirstLine: true), [.turnStarted])
    }

    func testFinishedFileRecoversAsFinished() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (line("event_msg", "task_started") + "\n" + line("event_msg", "task_complete") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexRolloutTail.lastEvent(in: url), .turnFinished)
    }
}
