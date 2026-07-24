import XCTest
@testable import Uncoil

final class AgentBrowserAdapterTests: XCTestCase {
    private var root: URL!
    private var binary: URL!
    private var browserDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-agent-browser-\(UUID().uuidString)", isDirectory: true)
        binary = root.appendingPathComponent("bin/agent-browser")
        browserDirectory = root.appendingPathComponent("browsers", isDirectory: true)
        let manifestDirectory = root.appendingPathComponent("node_modules/playwright-core")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: manifestDirectory, withIntermediateDirectories: true)
        try Data().write(to: binary)
        let manifest = #"{"browsers":[{"name":"chromium-headless-shell","revision":"1200"}]}"#
        try Data(manifest.utf8).write(to: manifestDirectory.appendingPathComponent("browsers.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRuntimeRevisionMatchesPlaywrightManifest() {
        XCTAssertEqual(AgentBrowserAdapter.runtimeRevision(binary: binary.path), "1200")
    }

    func testProbeRequiresMatchingRuntimeDirectory() throws {
        let adapter = AgentBrowserAdapter(
            resolver: { self.binary.path },
            browserDirectory: browserDirectory,
            selectedExecutable: { nil }
        )

        XCTAssertFalse(adapter.probe().installed)

        try FileManager.default.createDirectory(
            at: browserDirectory.appendingPathComponent("chromium_headless_shell-1200"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(adapter.probe().installed)
    }

    func testRuntimeEnvironmentUsesConfiguredDirectory() {
        XCTAssertEqual(
            AgentBrowserAdapter.runtimeEnvironment(
                browserDirectory: browserDirectory,
                nodePath: "/opt/runtime/bin/node",
                temporaryDirectory: "/private/tmp/uncoil",
                executablePath: nil
            ),
            [
                "PLAYWRIGHT_BROWSERS_PATH": browserDirectory.path,
                "TMPDIR": "/private/tmp/uncoil",
                "PATH": "/opt/runtime/bin:" + (
                    ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                ),
            ]
        )
    }

    func testRuntimeEnvironmentUsesSelectedChromiumExecutable() throws {
        let executable = root.appendingPathComponent("Custom Chromium")
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let environment = AgentBrowserAdapter.runtimeEnvironment(
            browserDirectory: browserDirectory,
            nodePath: nil,
            temporaryDirectory: nil,
            executablePath: executable.path
        )
        XCTAssertEqual(
            environment["AGENT_BROWSER_EXECUTABLE_PATH"],
            executable.path
        )
    }
}
