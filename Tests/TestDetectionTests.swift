import XCTest
@testable import Uncoil

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

final class TestDetectionTests: XCTestCase {
    private func detect(_ fs: FakeFS) -> [TestSuiteConfiguration] {
        TestDetection.detect(fileSystem: fs)
    }

    // MARK: - Apple

    func testASwiftPackageIsDetected() throws {
        let suite = try XCTUnwrap(
            detect(FakeFS(files: ["Package.swift": "// swift-tools-version:5.9\n"])).first
        )
        XCTAssertEqual(suite.command, "swift test")
        XCTAssertEqual(suite.framework, .swift)
    }

    /// A project with an Xcode container has its tests wired to a scheme;
    /// `swift test` on it either fails or silently runs a smaller set.
    func testAnXcodeContainerWinsOverABarePackage() {
        let suites = detect(FakeFS(
            files: ["Package.swift": ""],
            directories: ["App.xcodeproj"]
        ))
        XCTAssertEqual(suites.map(\.framework), [.xcodebuild])
    }

    // MARK: - Node

    func testAJestScriptIsDetectedWithItsFramework() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: [
            "package.json": #"{"scripts":{"test":"jest --ci"}}"#,
        ])).first)
        XCTAssertEqual(suite.command, "npm test")
        XCTAssertEqual(suite.framework, .jest)
    }

    func testVitestIsReadByTheSameParser() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: [
            "package.json": #"{"scripts":{"test":"vitest run"}}"#,
        ])).first)
        XCTAssertEqual(suite.framework, .jest)
    }

    /// The runner is unrecognised, so the suite still runs but promises no
    /// per-test breakdown — and its note says why.
    func testAnUnrecognisedRunnerIsMarkedUnknownRatherThanGuessed() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: [
            "package.json": #"{"scripts":{"test":"./run-my-tests.sh"}}"#,
        ])).first)
        XCTAssertEqual(suite.framework, .unknown)
        XCTAssertFalse(suite.framework.reportsIndividualTests)
        XCTAssertEqual(suite.notes?.contains("not recognised"), true)
    }

    /// `npm init` writes this into every project. Offering it as a suite means
    /// offering to run a command that tests nothing and exits 1.
    func testNpmsPlaceholderScriptIsNotASuite() {
        let suites = detect(FakeFS(files: [
            "package.json":
                #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#,
        ]))
        XCTAssertTrue(suites.isEmpty)
    }

    func testAProjectWithNoTestScriptOffersNothing() {
        let suites = detect(FakeFS(files: [
            "package.json": #"{"scripts":{"dev":"vite"}}"#,
        ]))
        XCTAssertTrue(suites.isEmpty)
    }

    func testThePackageManagerIsHonoured() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: [
            "package.json": #"{"scripts":{"test":"vitest"}}"#,
            "pnpm-lock.yaml": "",
        ])).first)
        XCTAssertEqual(suite.command, "pnpm test")
    }

    // MARK: - Go, Rust

    /// go's plain output reports a package summary and leaves individual
    /// results to be inferred from indentation; -json states them.
    func testGoIsRunWithJSONOutput() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: ["go.mod": "module x\n"])).first)
        XCTAssertTrue(suite.command.contains("-json"))
        XCTAssertEqual(suite.framework, .go)
    }

    func testCargoIsDetected() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: ["Cargo.toml": "[package]\n"])).first)
        XCTAssertEqual(suite.command, "cargo test")
        XCTAssertEqual(suite.framework, .cargo)
    }

    // MARK: - Python

    /// pytest's default output is a row of dots with no test names in it, so
    /// there would be nothing to parse without -v.
    func testPytestIsRunVerboselyOrThereAreNoNamesToRead() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: ["pytest.ini": "[pytest]\n"])).first)
        XCTAssertTrue(suite.command.contains("-v"))
        XCTAssertEqual(suite.framework, .pytest)
    }

    func testUvIsUsedWhenTheProjectLocksWithIt() throws {
        let suite = try XCTUnwrap(detect(FakeFS(files: [
            "pyproject.toml": "[tool.pytest.ini_options]\n",
            "uv.lock": "",
        ])).first)
        XCTAssertTrue(suite.command.hasPrefix("uv run"))
    }

    /// A tests directory is not a runner. Without a pytest configuration there
    /// is nothing saying pytest is what runs them.
    func testATestsFolderAloneIsNotEnough() {
        let suites = detect(FakeFS(
            files: ["tests/test_api.py": "def test_x(): pass\n"],
            directories: ["tests"]
        ))
        XCTAssertTrue(suites.isEmpty)
    }

    // MARK: - Sub-projects and merging

    func testASubProjectIsFoundAndItsIdIsPrefixed() {
        let suites = detect(FakeFS(
            files: ["backend/go.mod": "module x\n"],
            directories: ["backend"]
        ))
        XCTAssertEqual(suites.map(\.id), ["backend-go-test"])
    }

    /// Same rule as run configurations: detection may add, never overwrite what
    /// a person or an agent wrote.
    func testMergingNeverOverwritesAHandWrittenSuite() {
        let mine = TestSuiteConfiguration(
            id: "swift-test", command: "swift test --filter Fast", source: .user
        )
        let suggested = TestSuiteConfiguration(id: "swift-test", command: "swift test")
        let merged = TestConfigFile.merge(
            existing: [mine], suggestions: [suggested], replacingDetected: true
        )
        XCTAssertEqual(merged.map(\.command), ["swift test --filter Fast"])
    }

    func testMergingAddsNewSuggestions() {
        let merged = TestConfigFile.merge(
            existing: [TestSuiteConfiguration(id: "a", command: "a", source: .user)],
            suggestions: [TestSuiteConfiguration(id: "b", command: "b")],
            replacingDetected: false
        )
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    // MARK: - The file

    func testASuiteRoundTripsThroughTheFileShape() throws {
        let suite = TestSuiteConfiguration(
            id: "swift-test", name: "Unit", command: "swift test",
            framework: .swift, isDefault: true, source: .user
        )
        let data = try JSONEncoder().encode(
            JSONValue.object(["version": .int(1), "suites": .array([suite.asJSON()])])
        )
        let contents = TestConfigFile.parse(data)
        XCTAssertEqual(contents.suites, [suite])
        XCTAssertTrue(contents.problems.isEmpty)
    }

    /// One bad entry must not brick the feature for the others.
    func testAMalformedEntryIsSkippedAndReported() throws {
        let data = try JSONEncoder().encode(JSONValue.object([
            "suites": .array([
                .object(["name": .string("no id or command")]),
                .object(["id": .string("ok"), "command": .string("swift test")]),
            ]),
        ]))
        let contents = TestConfigFile.parse(data)
        XCTAssertEqual(contents.suites.map(\.id), ["ok"])
        XCTAssertEqual(contents.problems.count, 1)
    }

    /// Keys the app does not know about belong to whoever wrote them.
    func testUnknownKeysSurviveARewrite() throws {
        let data = try JSONEncoder().encode(JSONValue.object([
            "suites": .array([.object([
                "id": .string("a"),
                "command": .string("swift test"),
                "owner": .string("the platform team"),
            ])]),
        ]))
        let suite = try XCTUnwrap(TestConfigFile.parse(data).suites.first)
        XCTAssertEqual(suite.asJSON().objectValue?["owner"]?.stringValue, "the platform team")
    }
}
