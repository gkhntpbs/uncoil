import XCTest
@testable import Uncoil

final class TestWorkspaceServiceTests: XCTestCase {
    func testCreatesCompleteAcceptanceWorkspace() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let root = try TestWorkspaceService(temporaryDirectory: parent).create()
        let required = [
            ".git",
            ".gitignore",
            "swift-sample/Package.swift",
            "swift-sample/Sources/AcceptanceApp/main.swift",
            "javascript-sample/package.json",
            "javascript-sample/index.test.js",
            "scripts/test-pass.sh",
            "scripts/test-fail.sh",
            "scripts/long-running.sh",
            "scripts/large-output.sh",
            "scripts/crash.sh",
            "fake-mcp/server.js",
            "fake-mcp/config.example.json",
            "acceptance.json",
        ]

        for path in required {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                path
            )
        }

        let manifestData = try Data(contentsOf: root.appendingPathComponent("acceptance.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let mcp = try XCTUnwrap(manifest["mcp"] as? [String: Any])
        XCTAssertEqual(mcp["readOnlyTools"] as? [String], ["fixture_read"])
        XCTAssertEqual(mcp["mutationTools"] as? [String], ["fixture_write"])
        XCTAssertEqual(mcp["destructiveTools"] as? [String], ["fixture_delete"])

        let gitignore = try String(
            contentsOf: root.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        XCTAssertTrue(gitignore.contains(".uncoil-worktrees/"))
    }

    func testGeneratedScriptsAreExecutable() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-workspace-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let root = try TestWorkspaceService(temporaryDirectory: parent).create()
        for name in [
            "test-pass.sh",
            "test-fail.sh",
            "long-running.sh",
            "large-output.sh",
            "crash.sh",
        ] {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(
                    atPath: root.appendingPathComponent("scripts/\(name)").path
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: root.appendingPathComponent("fake-mcp/server.js").path
            )
        )
    }
}
