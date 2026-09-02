import XCTest
@testable import Uncoil

/// Pointing Uncoil at a CLI it could not find on its own, from the settings
/// side: what is stored, what is refused, and what has to be forgotten so the
/// answer actually takes effect.
@MainActor
final class AgentBinaryLocationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilLocations-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BinarySearchPath.setUserLocations([:])
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A directory holding an executable named after the command — the shape an
    /// install kept outside the usual locations actually has.
    private func makeInstall(command: String) throws -> (directory: URL, binary: URL) {
        let root = directory.appendingPathComponent("tools-\(command)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent(command)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )
        return (root, binary)
    }

    func testChoosingAFolderStoresItAndResolvesTheBinary() throws {
        let install = try makeInstall(command: "hermes")
        let settings = SettingsStore(directory: directory)

        let outcome = settings.setAgentBinaryLocation(install.directory.path, forCommand: "hermes")
        XCTAssertEqual(outcome, .resolved(install.binary.path))
        XCTAssertEqual(settings.agentBinaryLocation(forCommand: "hermes"), install.directory.path)
        // The search path is the thing every other surface asks, so the setting
        // is worth nothing until it is there.
        XCTAssertEqual(BinarySearchPath.userLocation(for: "hermes"), install.directory.path)
        XCTAssertEqual(BinarySearchPath.locate("hermes"), install.binary.path)
    }

    func testChoosingTheExecutableItselfWorksToo() throws {
        let install = try makeInstall(command: "hermes")
        let settings = SettingsStore(directory: directory)
        XCTAssertEqual(
            settings.setAgentBinaryLocation(install.binary.path, forCommand: "hermes"),
            .resolved(install.binary.path)
        )
    }

    /// A location that finds nothing is refused rather than stored: kept, it
    /// would leave the row exactly as it was and the user with no idea why.
    func testALocationThatFindsNothingIsNotStored() throws {
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let settings = SettingsStore(directory: directory)

        XCTAssertEqual(
            settings.setAgentBinaryLocation(empty.path, forCommand: "hermes"),
            .nothingExecutableThere
        )
        XCTAssertNil(settings.agentBinaryLocation(forCommand: "hermes"))
        XCTAssertNil(BinarySearchPath.userLocation(for: "hermes"))
    }

    func testTheLocationSurvivesARestart() throws {
        let install = try makeInstall(command: "hermes")
        SettingsStore(directory: directory)
            .setAgentBinaryLocation(install.directory.path, forCommand: "hermes")

        BinarySearchPath.setUserLocations([:])
        let reopened = SettingsStore(directory: directory)
        XCTAssertEqual(
            reopened.agentBinaryLocation(forCommand: "hermes"), install.directory.path
        )
        // Mirrored on load as well as on change — otherwise the setting would
        // only work in the session it was made in.
        XCTAssertEqual(BinarySearchPath.userLocation(for: "hermes"), install.directory.path)
    }

    func testClearingGoesBackToTheUsualLocations() throws {
        let install = try makeInstall(command: "hermes")
        let settings = SettingsStore(directory: directory)
        settings.setAgentBinaryLocation(install.directory.path, forCommand: "hermes")

        settings.clearAgentBinaryLocation(forCommand: "hermes")
        XCTAssertNil(settings.agentBinaryLocation(forCommand: "hermes"))
        XCTAssertNil(BinarySearchPath.userLocation(for: "hermes"))
        XCTAssertNil(SettingsStore(directory: directory).agentBinaryLocation(forCommand: "hermes"))
    }

    /// The part that is easy to forget and impossible to diagnose:
    /// `resolveBinaries()` only re-resolves an entry once its old path stops
    /// being executable, so a cached path would outlive the answer the user
    /// just gave — obeyed by the Extensions screen and ignored by session
    /// launch.
    func testChoosingALocationForgetsTheCachedResolutionForThatProvider() async throws {
        let install = try makeInstall(command: "claude")
        let settings = SettingsStore(directory: directory)
        await settings.resolveBinaries()
        let cachedElsewhere = settings.binaryPath(for: .claude)

        settings.setAgentBinaryLocation(install.directory.path, forCommand: "claude")
        XCTAssertNil(
            settings.binaryPath(for: .claude),
            "the old resolution should have been dropped, not left at \(cachedElsewhere ?? "nil")"
        )
        await settings.resolveBinaries()
        XCTAssertEqual(settings.binaryPath(for: .claude), install.binary.path)
    }

    /// Every agent Uncoil lists can be pointed at, including the ones it only
    /// manages configuration for. A command that could not be overridden would
    /// be a row whose "Locate…" button did nothing.
    func testEveryListedAgentHasACommandThatCanBeOverridden() throws {
        let settings = SettingsStore(directory: directory)
        for agent in ExtensionAgentID.allCases {
            let install = try makeInstall(command: agent.cliBinaryName)
            XCTAssertEqual(
                settings.setAgentBinaryLocation(
                    install.directory.path, forCommand: agent.cliBinaryName
                ),
                .resolved(install.binary.path),
                agent.rawValue
            )
        }
    }
}
