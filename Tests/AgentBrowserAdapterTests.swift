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

    func testVersionComparison() {
        XCTAssertTrue(AgentBrowserAdapter.isOutdated("0.5.0", recommended: "0.39.4"))
        XCTAssertTrue(AgentBrowserAdapter.isOutdated("0.39.3", recommended: "0.39.4"))
        XCTAssertFalse(AgentBrowserAdapter.isOutdated("0.39.4", recommended: "0.39.4"))
        XCTAssertFalse(AgentBrowserAdapter.isOutdated("1.0.0", recommended: "0.39.4"))
        XCTAssertFalse(AgentBrowserAdapter.isOutdated("0.40", recommended: "0.39.4"))
        XCTAssertFalse(AgentBrowserAdapter.isOutdated(nil))
        XCTAssertFalse(AgentBrowserAdapter.isOutdated("dev-build"))
        XCTAssertEqual(AgentBrowserAdapter.parseVersion("agent-browser 0.39.4\n"), "0.39.4")
        XCTAssertEqual(AgentBrowserAdapter.parseVersion("v1.2.3"), "1.2.3")
        XCTAssertNil(AgentBrowserAdapter.parseVersion("Unknown command"))
    }

    func testVersionIsReadFromThePackageBesideTheBinary() throws {
        try Data(#"{"name":"agent-browser","version":"0.5.0"}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        XCTAssertEqual(AgentBrowserAdapter.packageVersion(binary: binary.path), "0.5.0")
        XCTAssertEqual(AgentBrowserAdapter.generation(binary: binary.path), .playwright)

        try Data(#"{"name":"other","version":"9.9.9"}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        XCTAssertNil(AgentBrowserAdapter.packageVersion(binary: binary.path))
    }

    func testOutdatedProbeStaysUsableAndNamesTheUpdate() throws {
        try Data(#"{"name":"agent-browser","version":"0.5.0"}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(
            at: browserDirectory.appendingPathComponent("chromium_headless_shell-1200"),
            withIntermediateDirectories: true)
        let info = AgentBrowserAdapter(
            resolver: { self.binary.path }, browserDirectory: browserDirectory, selectedExecutable: { nil }
        ).probe()
        XCTAssertTrue(info.installed)
        XCTAssertEqual(info.version, "0.5.0")
        XCTAssertTrue(info.remedy?.contains("Update agent-browser") == true, info.remedy ?? "nil")
    }

    func testNativeGenerationUsesItsOwnRuntime() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("node_modules"))
        XCTAssertEqual(AgentBrowserAdapter.generation(binary: binary.path), .native)
        let native = root.appendingPathComponent("native-browsers", isDirectory: true)
        XCTAssertFalse(AgentBrowserAdapter.nativeRuntimeInstalled(browserDirectory: native, detected: []))
        try FileManager.default.createDirectory(
            at: native.appendingPathComponent("chrome-148.0"), withIntermediateDirectories: true)
        XCTAssertFalse(AgentBrowserAdapter.nativeRuntimeInstalled(browserDirectory: native, detected: []))
        let executable = native.appendingPathComponent("chrome-148.0/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(AgentBrowserAdapter.nativeRuntimeInstalled(browserDirectory: native, detected: []))
        XCTAssertEqual(AgentBrowserAdapter.installInvocation(binary: binary.path)?.arguments, ["install"])
    }

    func testUpdatePinsTheRecommendedRelease() throws {
        try Data(#"{"name":"agent-browser","version":"0.5.0"}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let npm = binary.deletingLastPathComponent().appendingPathComponent("npm")
        try Data().write(to: npm)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        let invocation = try XCTUnwrap(AgentBrowserAdapter.updateInvocation(binary: binary.path))
        XCTAssertEqual(invocation.executable, npm.path)
        XCTAssertEqual(invocation.arguments,
                       ["install", "-g", "agent-browser@\(AgentBrowserAdapter.recommendedVersion)"])
    }

    func testViewportAndScrollIntoViewArgv() {
        let adapter = AgentBrowserAdapter(resolver: { nil })
        XCTAssertEqual(adapter.argv(for: .viewport(width: 1440, height: 900, scale: nil)).0,
                       ["set", "viewport", "1440", "900"])
        XCTAssertEqual(adapter.argv(for: .viewport(width: 390, height: 844, scale: 3)).0,
                       ["set", "viewport", "390", "844", "3.0"])
        XCTAssertEqual(adapter.argv(for: .scrollIntoView(ref: "@e4")).0, ["scrollintoview", "@e4"])
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
