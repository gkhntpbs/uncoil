import XCTest
@testable import Uncoil

/// Runs the real producer against a fake CLI.
///
/// The live test needs a login and spends quota, so it runs only when asked —
/// which in practice meant the producer's plumbing was never exercised at all.
/// A stub script is enough to prove everything on Uncoil's side: the shell
/// invocation, the stdin redirect, the envelope parsing, the `-o` file, the
/// failure wording. Only the model's actual answer stays untested here, and
/// that is the one part that cannot fail silently.
final class HandoffProducerStubTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-handoff-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeStub(named name: String, script: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url.path
    }

    /// The Claude path: prompt in on stdin, envelope out on stdout, the
    /// handover JSON inside the envelope's `result` string.
    func testClaudeShapedAnswerIsParsed() throws {
        let stub = try writeStub(named: "claude", script: """
        # The prompt must actually arrive; refuse to answer if it did not.
        grep -q "handover" - || { echo "no prompt on stdin" >&2; exit 1; }
        printf '%s' '{"result": "{\\"objective\\": \\"finish the parser\\", \\"suggestedNextStep\\": \\"run the tests\\"}", "is_error": false}'
        """)
        let result = HandoffProducer.produce(
            provider: .claude, executable: stub, providerSessionID: nil,
            workingDirectory: directory.path,
            request: HandoffPrompt.request(remainingPercent: 8, windowTitle: "Weekly limit"),
            timeout: 30
        )
        XCTAssertNil(result.failure)
        let root = try XCTUnwrap(result.json?.objectValue)
        XCTAssertEqual(root["objective"]?.stringValue, "finish the parser")
    }

    /// "Not logged in" arrives as a well-formed envelope with `is_error` set.
    /// The failure must carry the CLI's own words, not a shrug.
    func testAClaudeErrorEnvelopeBecomesAReadableFailure() throws {
        let stub = try writeStub(named: "claude", script: """
        cat - > /dev/null
        printf '%s' '{"result": "Not logged in. Please run /login.", "is_error": true}'
        """)
        let result = HandoffProducer.produce(
            provider: .claude, executable: stub, providerSessionID: nil,
            workingDirectory: directory.path, request: "x", timeout: 30
        )
        XCTAssertNil(result.json)
        XCTAssertTrue(result.failure?.contains("Not logged in") == true,
                      "failure was: \(result.failure ?? "nil")")
    }

    /// The Codex path: the answer comes back through the `-o` file, not stdout.
    func testCodexShapedAnswerIsParsedFromItsOutputFile() throws {
        let stub = try writeStub(named: "codex", script: """
        cat - > /dev/null
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift; fi
          shift
        done
        [ -n "$out" ] || { echo "no -o argument" >&2; exit 1; }
        echo "chrome and token counts on stdout, as the real one prints"
        printf '%s' '{"objective": "wire the UI", "workDone": ["parsers"]}' > "$out"
        """)
        let result = HandoffProducer.produce(
            provider: .codex, executable: stub, providerSessionID: nil,
            workingDirectory: directory.path, request: "x", timeout: 30
        )
        XCTAssertNil(result.failure)
        let root = try XCTUnwrap(result.json?.objectValue)
        XCTAssertEqual(root["objective"]?.stringValue, "wire the UI")
    }

    /// A CLI that dies says what it said, so the next agent — and the person
    /// debugging — reads a diagnosis rather than "it did not answer".
    func testACrashingCLIsFirstWordsAreTheFailure() throws {
        let stub = try writeStub(named: "claude", script: """
        cat - > /dev/null
        echo "command not found: node"
        exit 127
        """)
        let result = HandoffProducer.produce(
            provider: .claude, executable: stub, providerSessionID: nil,
            workingDirectory: directory.path, request: "x", timeout: 30
        )
        XCTAssertNil(result.json)
        XCTAssertTrue(result.failure?.contains("command not found") == true,
                      "failure was: \(result.failure ?? "nil")")
    }

    /// Fenced or chatty answers still yield their JSON.
    func testAFencedAnswerStillYieldsItsJSON() throws {
        let stub = try writeStub(named: "claude", script: """
        cat - > /dev/null
        printf '%s' '{"result": "Here you go:\\n```json\\n{\\"objective\\": \\"x\\"}\\n```", "is_error": false}'
        """)
        let result = HandoffProducer.produce(
            provider: .claude, executable: stub, providerSessionID: nil,
            workingDirectory: directory.path, request: "x", timeout: 30
        )
        XCTAssertEqual(result.json?.objectValue?["objective"]?.stringValue, "x")
    }
}
