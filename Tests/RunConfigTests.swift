import XCTest
@testable import Uncoil

final class RunConfigTests: XCTestCase {
    func testParseFullConfiguration() {
        let json = """
        {"version":1,"configurations":[{"id":"web","name":"Web","command":"npm run dev",
        "cwd":"apps/web","env":{"PORT":"3000"},"ports":[3000],
        "preview_url":"http://localhost:3000","ready_pattern":"Local:",
        "depends_on":["api"],"source":"user","notes":"n","custom_key":{"a":1}}]}
        """
        let contents = RunConfigFile.parse(Data(json.utf8))
        XCTAssertEqual(contents.problems, [])
        XCTAssertEqual(contents.configurations.count, 1)
        let config = contents.configurations[0]
        XCTAssertEqual(config.id, "web")
        XCTAssertEqual(config.command, "npm run dev")
        XCTAssertEqual(config.cwd, "apps/web")
        XCTAssertEqual(config.env, ["PORT": "3000"])
        XCTAssertEqual(config.ports, [3000])
        XCTAssertEqual(config.previewURL, "http://localhost:3000")
        XCTAssertEqual(config.readyPattern, "Local:")
        XCTAssertEqual(config.dependsOn, ["api"])
        XCTAssertEqual(config.source, .user)
        XCTAssertEqual(config.extra["custom_key"], .object(["a": .int(1)]))
    }

    func testMalformedEntryIsSkippedNotFatal() {
        let json = """
        {"configurations":[{"name":"no id"},{"id":"ok","command":"true"}]}
        """
        let contents = RunConfigFile.parse(Data(json.utf8))
        XCTAssertEqual(contents.configurations.map(\.id), ["ok"])
        XCTAssertEqual(contents.problems.count, 1)
    }

    func testDuplicateIdsKeepFirst() {
        let json = """
        {"configurations":[{"id":"a","command":"one"},{"id":"a","command":"two"}]}
        """
        let contents = RunConfigFile.parse(Data(json.utf8))
        XCTAssertEqual(contents.configurations.count, 1)
        XCTAssertEqual(contents.configurations[0].command, "one")
        XCTAssertEqual(contents.problems.count, 1)
    }

    func testRoundTripPreservesUnknownKeys() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let config = RunConfiguration(
            id: "x", name: "X", command: "true", source: .agent,
            extra: ["agent_note": .string("keep me")]
        )
        try RunConfigFile.save([config], projectRoot: tempDir)
        let loaded = RunConfigFile.load(projectRoot: tempDir)
        XCTAssertEqual(loaded.configurations, [config])
        XCTAssertEqual(loaded.configurations[0].extra["agent_note"], .string("keep me"))
    }

    func testDefaultConfigurationResolution() {
        let a = RunConfiguration(id: "a", command: "a")
        let b = RunConfiguration(id: "b", command: "b", isDefault: true)
        // The flagged entry wins.
        XCTAssertEqual(RunConfigFile.defaultConfiguration([a, b])?.id, "b")
        // A single configuration is the obvious default even without the flag.
        XCTAssertEqual(RunConfigFile.defaultConfiguration([a])?.id, "a")
        // Several candidates and no flag: no guessing.
        XCTAssertNil(RunConfigFile.defaultConfiguration([a, RunConfiguration(id: "c", command: "c")]))
    }

    func testSetDefaultIsExclusiveAndPersists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try RunConfigFile.save([
            RunConfiguration(id: "a", command: "a", isDefault: true),
            RunConfiguration(id: "b", command: "b"),
        ], projectRoot: tempDir)
        try RunConfigFile.setDefault("b", projectRoot: tempDir)
        let loaded = RunConfigFile.load(projectRoot: tempDir).configurations
        XCTAssertEqual(loaded.filter(\.isDefault).map(\.id), ["b"])
    }

    func testMergeNeverTouchesUserEntries() {
        let user = RunConfiguration(id: "dev", command: "my custom", source: .user)
        let detectedOld = RunConfiguration(id: "old", command: "stale", source: .detected)
        let suggestion = RunConfiguration(id: "dev", command: "npm run dev", source: .detected)
        let fresh = RunConfiguration(id: "new", command: "make dev", source: .detected)

        let appended = RunDetection.merge(
            existing: [user, detectedOld], suggestions: [suggestion, fresh],
            replacingDetected: false
        )
        XCTAssertEqual(appended.map(\.id), ["dev", "old", "new"])
        XCTAssertEqual(appended[0].command, "my custom")

        let replaced = RunDetection.merge(
            existing: [user, detectedOld], suggestions: [suggestion, fresh],
            replacingDetected: true
        )
        XCTAssertEqual(replaced.map(\.id), ["dev", "new"])
        XCTAssertEqual(replaced[0].command, "my custom")
    }
}
