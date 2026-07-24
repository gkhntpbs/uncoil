import XCTest
@testable import Uncoil

final class DebugBundleServiceTests: XCTestCase {
    private var root: URL!
    private var dataDirectory: URL!
    private var homeDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        temporaryDirectory = root.appendingPathComponent("temporary", isDirectory: true)
        for directory in [dataDirectory, homeDirectory, temporaryDirectory] {
            try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRedactsSecretsPathsAndPrompts() {
        let service = makeService()
        let project = "/Volumes/External/SecretProject"
        let input = """
        path=\(homeDirectory.path)/.codex/config.toml
        temp=\(temporaryDirectory.path)/session
        project=\(project)/Sources
        access_token="token-value"
        Authorization: Bearer bearer-value
        token: accessibility-token-value
        github_token=ghp_abcdefghijklmnopqrstuvwxyz123456
        api_key=sk-abcdefghijklmnopqrstuvwxyz
        args=["--api-key","ctx7sk-d50a70a2-4dfa-4fb1-a009-776e0749697f"]
        initial_prompt=do not include this
        """
        let result = service.redact(input, projectPaths: [project])

        XCTAssertFalse(result.contains(homeDirectory.path))
        XCTAssertFalse(result.contains(temporaryDirectory.path))
        XCTAssertFalse(result.contains(project))
        XCTAssertFalse(result.contains("token-value"))
        XCTAssertFalse(result.contains("bearer-value"))
        XCTAssertFalse(result.contains("accessibility-token-value"))
        XCTAssertFalse(result.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(result.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(result.contains("ctx7sk-d50a70a2-4dfa-4fb1-a009-776e0749697f"))
        XCTAssertFalse(result.contains("do not include this"))
        XCTAssertTrue(result.contains("~/.codex/config.toml"))
        XCTAssertTrue(result.contains("$TMPDIR/session"))
        XCTAssertTrue(result.contains("<PROJECT_ROOT>/Sources"))
        XCTAssertTrue(result.contains("<redacted-prompt>"))
    }

    func testCreatesSanitizedArchiveWithRequiredSections() throws {
        try seedFixtures()
        let service = makeService()
        let result = try service.create()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        XCTAssertEqual(
            Set(result.includedFiles),
            Set([
                "acceptance-results.txt",
                "agent-versions.txt",
                "app-logs.txt",
                "crash-reports.txt",
                "manifest.txt",
                "mcp-handshake.txt",
                "permission-decisions.txt",
                "runtime-daemon-logs.txt",
                "sanitized-agent-configs.txt",
                "system-information.txt",
            ])
        )

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", result.bundleURL.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let files = try FileManager.default.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: nil
        )
        let content = files.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertFalse(content.contains("super-secret-token"))
        XCTAssertFalse(content.contains("do not ship this prompt"))
        XCTAssertFalse(content.contains("private conversation"))
        XCTAssertFalse(content.contains(homeDirectory.path))
        XCTAssertTrue(content.contains("ACCEPTANCE_PASS"))
        XCTAssertTrue(content.contains("prompt_content_included=false"))
        XCTAssertTrue(content.contains("protocol_version="))
    }

    private func makeService() -> DebugBundleService {
        DebugBundleService(
            dataDirectory: dataDirectory,
            homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            command: { executable, arguments in
                if executable == "/usr/bin/ditto" {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    try? process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0 ? "" : nil
                }
                if arguments == ["--version"] {
                    return executable.contains("claude") ? "claude 1.0" : "codex 2.0"
                }
                return "fixture log \(self.homeDirectory.path) access_token=super-secret-token"
            }
        )
    }

    private func seedFixtures() throws {
        let projects = [
            Project(name: "secret", rootPath: "/Volumes/External/SecretProject"),
        ]
        try JSONEncoder().encode(projects).write(
            to: dataDirectory.appendingPathComponent("projects.json")
        )
        try JSONSerialization.data(withJSONObject: [
            "access_token": "super-secret-token",
            "initial_prompt": [
                "role": "user",
                "content": "do not ship this prompt",
            ],
            "message_history": [
                ["content": "private conversation"],
            ],
        ], options: [.prettyPrinted]).write(to: homeDirectory.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(
            at: homeDirectory.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        try Data("api_key=super-secret-token\n".utf8).write(
            to: homeDirectory.appendingPathComponent(".codex/config.toml")
        )
        try FileManager.default.createDirectory(
            at: dataDirectory.appendingPathComponent("mcp"),
            withIntermediateDirectories: true
        )
        try Data(#"{"command":"/Volumes/External/SecretProject/uncoil-mcp"}"#.utf8).write(
            to: dataDirectory.appendingPathComponent("mcp/session.json")
        )
        try Data(#"{"status":"approved","secret":"super-secret-token"}"#.utf8).write(
            to: dataDirectory.appendingPathComponent("permissions.json")
        )
        let audit = dataDirectory.appendingPathComponent("audit")
        try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true)
        try Data(#"{"action":"request_permission","args":["permission"]}"#.utf8).write(
            to: audit.appendingPathComponent("2026-07-25.jsonl")
        )
        let artifacts = dataDirectory.appendingPathComponent(
            "projects/project/sessions/session/artifacts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try Data("ACCEPTANCE_PASS\n".utf8).write(
            to: artifacts.appendingPathComponent("guided-acceptance-results.md")
        )
        let crash = homeDirectory.appendingPathComponent(
            "Library/Logs/DiagnosticReports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: true)
        try Data("Uncoil crash \(homeDirectory.path)\n".utf8).write(
            to: crash.appendingPathComponent("Uncoil-2026-07-25.ips")
        )
    }
}
