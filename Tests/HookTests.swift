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
    private var record: SessionRecord!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-hook-tests-\(UUID().uuidString)", isDirectory: true)
        projects = ProjectStore(directory: tempDir)
        projects.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        project = projects.projects[0]
        sessions = SessionStore()
        record = projects.createSession(
            projectID: project.id,
            provider: .claude,
            accountID: nil,
            title: "test"
        )
        sessions.setStatus(.running, for: record.id)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func send(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard let event = HookEvent(jsonLine: data) else { return }
        sessions.reduce(
            event,
            projectResolver: { [projects] path in projects!.project(containing: path) },
            sessionResolver: { [projects, sessions] projectID in
                sessions!.liveSessionID(projectSessions: projects!.sessions(for: projectID))
            },
            touchSession: { _ in }
        )
    }

    func testPermissionNotificationSetsAttentionState() {
        send([
            "hook_event_name": "Notification",
            "cwd": "/tmp/demo/sub/dir",
            "message": "Claude needs your permission to use Bash",
        ])
        XCTAssertEqual(sessions.status(of: record.id), .waitingForPermission)
    }

    func testStopMarksCompletedAndPromptResumesRunning() {
        send(["hook_event_name": "Stop", "cwd": "/tmp/demo"])
        XCTAssertEqual(sessions.status(of: record.id), .completed)
        send(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp/demo"])
        XCTAssertEqual(sessions.status(of: record.id), .running)
    }

    func testEventOutsideRegisteredProjectsIgnored() {
        send(["hook_event_name": "Stop", "cwd": "/somewhere/else"])
        XCTAssertEqual(sessions.status(of: record.id), .running)
    }

    func testPromptBecomesTitleAndProviderSessionIDCaptured() {
        var capturedSID: String?
        var capturedTitle: String?
        let data = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "prov-123",
            "cwd": "/tmp/demo",
            "prompt": "Login ekranındaki hatayı düzelt\nDetaylar: ...",
        ])
        let event = HookEvent(jsonLine: data)!
        sessions.reduce(
            event,
            projectResolver: { [projects] path in projects!.project(containing: path) },
            sessionResolver: { [projects, sessions] projectID in
                sessions!.liveSessionID(projectSessions: projects!.sessions(for: projectID))
            },
            touchSession: { _ in },
            applyMeta: { _, sid, title in
                capturedSID = sid
                capturedTitle = title
            }
        )
        XCTAssertEqual(capturedSID, "prov-123")
        XCTAssertEqual(capturedTitle, "Login ekranındaki hatayı düzelt")
    }

    func testLongPromptTitleTruncated() {
        let long = String(repeating: "a", count: 80)
        let data = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "cwd": "/tmp/demo",
            "prompt": long,
        ])
        let title = SessionStore.titleCandidate(from: HookEvent(jsonLine: data)!)
        XCTAssertEqual(title?.count, 42)
        XCTAssertTrue(title!.hasSuffix("…"))
    }

    func testEventWithNoLiveSessionIgnored() {
        sessions.setStatus(.terminated, for: record.id)
        send(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp/demo"])
        XCTAssertEqual(sessions.status(of: record.id), .terminated)
    }
}
