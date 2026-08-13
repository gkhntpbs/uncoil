import XCTest
@testable import Uncoil

/// Maestro, read the way this screen needs it: one row per command, not one
/// row per flow. Maestro is the runner for mobile and web end-to-end flows, and
/// its console output is drawn as a box — so the frame and the colour codes
/// have to come off before a single name can be read.
final class MaestroOutputTests: XCTestCase {
    /// The shape Maestro prints: a flow heading, then its commands.
    private let output = """
     ║
     ║  > Flow: login
     ║
     ║    ✅  Launch app "com.example.app"
     ║    ✅  Tap on "Login"
     ║    ❌  Assert that "Welcome back" is visible
     ║        Assertion is false: "Welcome back" is visible
     ║
     ║  > Flow: checkout
     ║
     ║    ✅  Open https://example.com
     ║    ⏳  Tap on "Buy"
     ║
    """

    func testEveryCommandBecomesAStep() {
        let parsed = TestOutputParser.parse(output, framework: .maestro, exitCode: 1)
        XCTAssertEqual(parsed.cases.count, 5)
        XCTAssertEqual(parsed.summary.passed, 3)
        XCTAssertEqual(parsed.summary.failed, 1)
        XCTAssertEqual(parsed.summary.skipped, 1)
        XCTAssertTrue(parsed.summary.isDetailed)
    }

    /// The flow is the step's suite, the way a class is for XCTest — without it
    /// two flows' steps read as one undifferentiated list.
    func testStepsCarryTheirFlow() {
        let parsed = TestOutputParser.parse(output, framework: .maestro, exitCode: 1)
        XCTAssertEqual(parsed.cases.first?.suite, "login")
        XCTAssertEqual(parsed.cases.first?.name, #"Launch app "com.example.app""#)
        XCTAssertEqual(parsed.cases.last?.suite, "checkout")
    }

    /// The reason is printed under the command that failed, and belongs to it.
    func testTheReasonReachesTheCommandThatFailed() {
        let parsed = TestOutputParser.parse(output, framework: .maestro, exitCode: 1)
        let failed = parsed.cases.first { $0.outcome == .failed }
        XCTAssertEqual(failed?.message, #"Assertion is false: "Welcome back" is visible"#)
        XCTAssertNil(parsed.cases.first { $0.outcome == .passed }?.message)
    }

    /// On a terminal every line arrives wrapped in colour codes, and a code
    /// left in place would end up inside a step's name.
    func testColourCodesAreNotPartOfTheName() {
        let coloured = " ║    \u{1B}[32m✅\u{1B}[0m  Tap on \"Login\"\n"
        let cases = TestOutputParser.parseMaestro(coloured)
        XCTAssertEqual(cases.map(\.name), [#"Tap on "Login""#])
    }

    /// A line that is not a command is not a step — the box's own frame, the
    /// device banner, the blank lines between flows.
    func testOnlyCommandsAreCounted() {
        let noise = """
        Running on emulator-5554
         ║
         ║  > Flow: login
         ║
        """
        XCTAssertTrue(TestOutputParser.parseMaestro(noise).isEmpty)
    }
}

/// Proposing a Maestro suite for a project that has flows.
final class MaestroDetectionTests: XCTestCase {
    private struct FakeFS: RunDetectionFileSystem {
        var files: [String: String]
        var directories: Set<String>

        func list(_ path: String) -> [String] {
            let prefix = path == "." ? "" : path + "/"
            var names = Set<String>()
            for key in Set(files.keys).union(directories) where key.hasPrefix(prefix) {
                let rest = key.dropFirst(prefix.count)
                guard !rest.isEmpty, let first = rest.split(separator: "/").first
                else { continue }
                names.insert(String(first))
            }
            return Array(names)
        }

        func isDirectory(_ path: String) -> Bool { directories.contains(path) }
        func read(_ path: String) -> String? { files[path] }
    }

    func testFlowsInMaestrosOwnDirectoryAreDetected() {
        let suites = TestDetection.detect(fileSystem: FakeFS(
            files: [".maestro/login.yaml": "appId: com.example.app\n---\n- launchApp"],
            directories: [".maestro"]
        ))
        let suite = suites.first { $0.framework == .maestro }
        XCTAssertEqual(suite?.id, "maestro")
        XCTAssertEqual(suite?.command, "maestro test .maestro --debug-output .maestro-output")
        // Inside the project, because Maestro's own default is a directory
        // under the home folder that Uncoil refuses to read.
        XCTAssertEqual(suite?.artifacts, TestDetection.maestroOutputDirectory)
    }

    /// A web flow has no `appId`; it names a URL, and it is still a flow.
    func testAWebFlowIsDetectedToo() {
        let suites = TestDetection.detect(fileSystem: FakeFS(
            files: ["e2e/checkout.yml": "url: https://example.com\n---\n- openLink"],
            directories: ["e2e"]
        ))
        XCTAssertEqual(suites.first { $0.framework == .maestro }?.command,
                       "maestro test e2e --debug-output .maestro-output")
    }

    /// `e2e/` and `flows/` are ordinary names. Without something that looks
    /// like a flow in them, offering to run Maestro would be a guess.
    func testAnUnrelatedDirectoryIsNotAMaestroSuite() {
        let suites = TestDetection.detect(fileSystem: FakeFS(
            files: ["flows/diagram.yaml": "nodes:\n  - a\n"],
            directories: ["flows"]
        ))
        XCTAssertNil(suites.first { $0.framework == .maestro })
    }
}
