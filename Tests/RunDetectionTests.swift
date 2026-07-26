import XCTest
@testable import Uncoil

/// Fake filesystem: paths are "." or slash-joined relative paths mapping to
/// either file contents (String) or a directory marker (nil contents).
private struct FakeFS: RunDetectionFileSystem {
    var files: [String: String] = [:]
    var directories: Set<String> = []

    func list(_ relativePath: String) -> [String] {
        let prefix = relativePath == "." ? "" : relativePath + "/"
        var names = Set<String>()
        for path in files.keys where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                names.insert(String(rest[rest.startIndex..<slash]))
            } else if !rest.isEmpty {
                names.insert(String(rest))
            }
        }
        for dir in directories where dir.hasPrefix(prefix) {
            let rest = dir.dropFirst(prefix.count)
            if !rest.isEmpty, !rest.contains("/") { names.insert(String(rest)) }
        }
        return Array(names)
    }

    func isDirectory(_ relativePath: String) -> Bool {
        directories.contains(relativePath)
            || files.keys.contains { $0.hasPrefix(relativePath + "/") }
    }

    func read(_ relativePath: String) -> String? { files[relativePath] }
}

final class RunDetectionTests: XCTestCase {
    func testNextJsProject() {
        let fs = FakeFS(files: [
            "package.json": #"{"scripts":{"dev":"next dev","build":"next build"}}"#,
            "pnpm-lock.yaml": "",
        ])
        let configs = RunDetection.detect(fileSystem: fs)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].id, "dev")
        XCTAssertEqual(configs[0].command, "pnpm run dev")
        XCTAssertEqual(configs[0].ports, [3000])
        XCTAssertEqual(configs[0].previewURL, "http://localhost:3000")
        XCTAssertEqual(configs[0].source, .detected)
    }

    func testNpmStartFallback() {
        let fs = FakeFS(files: [
            "package.json": #"{"scripts":{"start":"node server.js"}}"#,
        ])
        XCTAssertEqual(RunDetection.detect(fileSystem: fs).first?.command, "npm start")
    }

    func testXcodeProject() {
        let fs = FakeFS(files: ["README.md": ""], directories: ["PowerSentry.xcodeproj"])
        let configs = RunDetection.detect(fileSystem: fs)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].id, "xcode-run")
        XCTAssertTrue(configs[0].command.contains("-project \"PowerSentry.xcodeproj\""))
        XCTAssertTrue(configs[0].command.contains("-scheme \"PowerSentry\""))
        XCTAssertEqual(configs[0].readyPattern, "BUILD SUCCEEDED")
    }

    func testWorkspaceBeatsProject() {
        let fs = FakeFS(directories: ["App.xcworkspace", "App.xcodeproj"])
        let configs = RunDetection.detect(fileSystem: fs)
        XCTAssertTrue(configs[0].command.contains("-workspace \"App.xcworkspace\""))
    }

    func testComposeMakefileProcfile() {
        let fs = FakeFS(files: [
            "docker-compose.yml": "services:",
            "Makefile": "dev:\n\tgo run .\n\nclean:\n\trm -rf out\n",
            "Procfile": "web: bundle exec puma\nworker: sidekiq\n# comment: no\n",
        ])
        let configs = RunDetection.detect(fileSystem: fs)
        let ids = Set(configs.map(\.id))
        XCTAssertTrue(ids.contains("compose"))
        XCTAssertTrue(ids.contains("make-dev"))
        XCTAssertTrue(ids.contains("proc-web"))
        XCTAssertTrue(ids.contains("proc-worker"))
        XCTAssertEqual(configs.first { $0.id == "proc-web" }?.command, "bundle exec puma")
    }

    func testPythonAndStatic() {
        let django = FakeFS(files: ["manage.py": ""])
        XCTAssertEqual(RunDetection.detect(fileSystem: django).first?.id, "django")

        let uv = FakeFS(files: [
            "pyproject.toml": "[project]\nname = \"x\"\n[project.scripts]\ncli = \"x.main:run\"\n",
            "uv.lock": "",
        ])
        XCTAssertEqual(RunDetection.detect(fileSystem: uv).first?.command, "uv run cli")

        let site = FakeFS(files: ["index.html": "<html>"])
        let configs = RunDetection.detect(fileSystem: site)
        XCTAssertEqual(configs.first?.id, "static")
        XCTAssertEqual(configs.first?.ports, [8080])
    }

    func testStaticFallbackOnlyWhenNothingElseDetected() {
        let fs = FakeFS(files: [
            "index.html": "<html>",
            "package.json": #"{"scripts":{"dev":"vite"}}"#,
        ])
        XCTAssertEqual(RunDetection.detect(fileSystem: fs).map(\.id), ["dev"])
    }

    func testMultiServiceRepoSweepsSubdirectories() {
        let fs = FakeFS(files: [
            "backend/package.json": #"{"scripts":{"dev":"nest start --watch"}}"#,
            "mobile/package.json": #"{"scripts":{"start":"expo start"}}"#,
            "node_modules/x/package.json": #"{"scripts":{"dev":"nope"}}"#,
        ])
        let configs = RunDetection.detect(fileSystem: fs)
        XCTAssertEqual(Set(configs.map(\.id)), ["backend-dev", "mobile-dev"])
        XCTAssertEqual(configs.first { $0.id == "backend-dev" }?.cwd, "backend")
    }
}
