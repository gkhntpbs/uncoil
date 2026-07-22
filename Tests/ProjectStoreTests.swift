import XCTest
@testable import Uncoil

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAddPersistsAndReloads() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo-project"))
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects[0].name, "demo-project")

        let reloaded = ProjectStore(directory: tempDir)
        XCTAssertEqual(reloaded.projects, store.projects)
    }

    func testDuplicatePathIgnored() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/demo"))
        XCTAssertEqual(store.projects.count, 1)
    }

    func testAttentionPriorityOrdering() {
        XCTAssertGreaterThan(
            AgentSessionStatus.waitingForPermission.attentionPriority,
            AgentSessionStatus.running.attentionPriority
        )
        XCTAssertGreaterThan(
            AgentSessionStatus.waitingForInput.attentionPriority,
            AgentSessionStatus.running.attentionPriority
        )
    }
}
