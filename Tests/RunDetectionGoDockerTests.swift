import XCTest
@testable import Uncoil

/// Same fake filesystem shape as `RunDetectionTests`: paths map to contents,
/// plus explicit directory markers.
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

final class RunDetectionGoTests: XCTestCase {
    func testAMainPackageAtTheModuleRootRunsWithADot() throws {
        let fs = FakeFS(files: [
            "go.mod": "module example.com/app\n\ngo 1.22\n",
            "main.go": "package main\n\nfunc main() {}\n",
        ])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "go-run" }
        )
        XCTAssertEqual(config.command, "go run .")
    }

    /// The common layout. `go run .` at the root fails here with "no Go files",
    /// so the entry point is looked up rather than assumed.
    func testAModuleWithOnlyCmdMainFindsTheEntryPoint() throws {
        let fs = FakeFS(files: [
            "go.mod": "module example.com/app\n",
            "cmd/server/main.go": "package main\n\nfunc main() {}\n",
            "internal/store/store.go": "package store\n",
        ])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "go-run" }
        )
        XCTAssertEqual(config.command, "go run ./cmd/server")
    }

    /// A `.go` file at the root is not automatically a main package — a library
    /// module has plenty of them.
    func testALibraryFileAtTheRootDoesNotCountAsAnEntryPoint() throws {
        let fs = FakeFS(files: [
            "go.mod": "module example.com/lib\n",
            "lib.go": "package lib\n",
            "cmd/tool/main.go": "package main\n",
        ])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "go-run" }
        )
        XCTAssertEqual(config.command, "go run ./cmd/tool")
    }

    func testNoGoModMeansNoGoConfiguration() {
        let fs = FakeFS(files: ["main.go": "package main\n"])
        XCTAssertNil(RunDetection.detect(fileSystem: fs).first { $0.id == "go-run" })
    }

    /// Go's standard library prints nothing on listen and every framework logs
    /// differently. A guessed ready pattern leaves the run stuck in "starting".
    func testNoPortOrReadyPatternIsInvented() throws {
        let fs = FakeFS(files: [
            "go.mod": "module example.com/app\n",
            "main.go": "package main\n",
        ])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "go-run" }
        )
        XCTAssertTrue(config.ports.isEmpty)
        XCTAssertNil(config.readyPattern)
        XCTAssertNil(config.previewURL)
    }
}

final class RunDetectionDockerTests: XCTestCase {
    func testADockerfileIsDetected() throws {
        let fs = FakeFS(files: ["Dockerfile": "FROM alpine\nCMD [\"sh\"]\n"])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "docker" }
        )
        XCTAssertTrue(config.command.contains("docker build"))
        XCTAssertTrue(config.command.contains("docker run"))
    }

    /// Ports are read from the Dockerfile's own EXPOSE lines — stated, not
    /// guessed — and only then is a preview URL offered.
    func testPortsComeFromExposeLines() throws {
        let fs = FakeFS(files: [
            "Dockerfile": "FROM nginx\nEXPOSE 8080/tcp\nEXPOSE 9090 9091\n",
        ])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "docker" }
        )
        XCTAssertEqual(config.ports, [8080, 9090, 9091])
        XCTAssertEqual(config.previewURL, "http://localhost:8080")
        XCTAssertTrue(config.command.contains("-p 8080:8080"))
    }

    func testADockerfileWithNoExposeOffersNoPreview() throws {
        let fs = FakeFS(files: ["Dockerfile": "FROM alpine\n"])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "docker" }
        )
        XCTAssertTrue(config.ports.isEmpty)
        XCTAssertNil(config.previewURL)
    }

    /// Compose already describes how the thing runs. Adding a Dockerfile entry
    /// beside it would only offer a second, worse way to start the same app.
    func testComposeWinsOverABareDockerfile() {
        let fs = FakeFS(files: [
            "Dockerfile": "FROM alpine\n",
            "docker-compose.yml": "services: {}\n",
        ])
        let ids = RunDetection.detect(fileSystem: fs).map(\.id)
        XCTAssertTrue(ids.contains("compose"))
        XCTAssertFalse(ids.contains("docker"))
    }

    /// The container is named so it can be found again to report its state; an
    /// unnamed one gets a random name and cannot be looked up.
    func testTheRunIsNamedSoItsStateCanBeRead() throws {
        let fs = FakeFS(files: ["Dockerfile": "FROM alpine\n"])
        let config = try XCTUnwrap(
            RunDetection.detect(fileSystem: fs).first { $0.id == "docker" }
        )
        XCTAssertNotNil(DockerStatus.runContainerName(in: config.command))
        XCTAssertNotNil(DockerStatus.statusArguments(for: config.command))
    }

    func testAVariablePortIsSkippedRatherThanGuessedAt() {
        XCTAssertEqual(RunDetection.exposedPorts(in: "EXPOSE $PORT\nEXPOSE 80\n"), [80])
    }

    func testADuplicateExposeIsListedOnce() {
        XCTAssertEqual(RunDetection.exposedPorts(in: "EXPOSE 80\nEXPOSE 80/tcp\n"), [80])
    }
}
