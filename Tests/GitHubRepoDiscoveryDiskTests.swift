import XCTest
@testable import Uncoil

/// The on-disk half of repository discovery, against real checkouts.
///
/// The pure tests inject the filesystem, which is what makes the rules
/// assertable — but it also means they would still pass if the disk version
/// asked the wrong questions. This one builds a real container folder: a
/// project directory that is not a checkout at all, holding two that are, one
/// checkout with no remote, and one plain folder.
final class GitHubRepoDiscoveryDiskTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeCheckout("console", remote: "git@github.com:Midyanet/midyanet-console.git")
        try makeCheckout("infra", remote: "https://github.com/Midyanet/midyanet-infra.git")
        // Neither of these is a source of issues, and neither may be asked for
        // one.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try makeCheckout("scratch", remote: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeCheckout(_ name: String, remote: String?) throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try run(["init", "-q", path.path])
        if let remote {
            try run(["-C", path.path, "remote", "add", "origin", remote])
        }
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    /// The case the whole thing exists for. Before this, the Issues tab was
    /// hidden on exactly the projects with the most issues: the root has no
    /// remote of its own, so the project looked like it had no GitHub
    /// repository at all.
    func testAContainerFolderWithNoRemoteOfItsOwnHasRepositories() {
        XCTAssertTrue(GitHubRepoDiscovery.hasRepository(projectRoot: root.path))
    }

    func testEveryCheckoutInsideIsFoundAndTheOthersAreNot() {
        XCTAssertEqual(
            GitHubRepoDiscovery.slugs(projectRoot: root.path),
            ["Midyanet/midyanet-console", "Midyanet/midyanet-infra"]
        )
    }

    func testAFolderWithNothingInItHasNoRepositories() {
        let empty = root.appendingPathComponent("docs").path
        XCTAssertFalse(GitHubRepoDiscovery.hasRepository(projectRoot: empty))
    }

    /// A checkout at the root itself still works — the ordinary case, and the
    /// only one that used to.
    func testAProjectThatIsItselfACheckoutStillWorks() {
        let single = root.appendingPathComponent("console").path
        XCTAssertEqual(
            GitHubRepoDiscovery.slugs(projectRoot: single), ["Midyanet/midyanet-console"]
        )
    }
}
