import XCTest
@testable import Uncoil

final class HookEventTests: XCTestCase {
    private func event(_ json: [String: Any]) -> HookEvent? {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return HookEvent(jsonLine: data)
    }

    func testDecodesKnownEvent() {
        let decoded = event([
            "hook_event_name": "PreToolUse",
            "session_id": "abc",
            "cwd": "/tmp/proj",
            "tool_name": "Bash",
        ])
        XCTAssertEqual(decoded?.kind, .preToolUse)
        XCTAssertEqual(decoded?.sessionID, "abc")
        XCTAssertEqual(decoded?.cwd, "/tmp/proj")
        XCTAssertEqual(decoded?.toolName, "Bash")
    }

    func testUnknownEventIgnored() {
        XCTAssertNil(event(["hook_event_name": "SomethingNew"]))
        XCTAssertNil(HookEvent(jsonLine: Data("not json".utf8)))
    }
}

@MainActor
final class HookReducerTests: XCTestCase {
    private var tempDir: URL!
    private var projects: ProjectStore!
    private var sessions: SessionStore!
    private var project: Project!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-hook-tests-\(UUID().uuidString)", isDirectory: true)
        projects = ProjectStore(directory: tempDir)
        projects.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        project = projects.projects[0]
        sessions = SessionStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func send(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard let event = HookEvent(jsonLine: data) else { return }
        sessions.reduce(event) { [projects] path in
            projects!.project(containing: path)
        }
    }

    func testPermissionNotificationSetsAttentionState() {
        send([
            "hook_event_name": "Notification",
            "cwd": "/tmp/demo/sub/dir",
            "message": "Claude needs your permission to use Bash",
        ])
        let session = sessions.session(for: project.id)
        XCTAssertEqual(session?.status, .waitingForPermission)
    }

    func testStopMarksCompletedAndPromptResumesRunning() {
        send(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp/demo"])
        XCTAssertEqual(sessions.session(for: project.id)?.status, .running)
        send(["hook_event_name": "Stop", "cwd": "/tmp/demo"])
        XCTAssertEqual(sessions.session(for: project.id)?.status, .completed)
    }

    func testEventOutsideRegisteredProjectsIgnored() {
        send(["hook_event_name": "UserPromptSubmit", "cwd": "/somewhere/else"])
        XCTAssertTrue(sessions.sessions.isEmpty)
    }
}
