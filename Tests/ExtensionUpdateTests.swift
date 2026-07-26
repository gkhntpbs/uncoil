import XCTest
@testable import Uncoil

/// Builds throwaway git repositories so the mirror and update engine are
/// exercised against real git rather than a stub.
@MainActor
final class ExtensionUpdateTests: XCTestCase {
    private var base: URL!
    private var layout: ExtensionStoreLayout!
    private var mirror: ExtensionMirror!
    private var store: SkillStore!
    private var remote: URL!

    private let repository = "acme/skills"

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilUpdate-\(UUID().uuidString)", isDirectory: true)
        layout = ExtensionStoreLayout(root: base.appendingPathComponent("store", isDirectory: true))
        try layout.ensure()
        mirror = ExtensionMirror(layout: layout)
        store = SkillStore(
            layout: layout,
            canonicalRoot: base.appendingPathComponent("agents/skills", isDirectory: true)
        )
        remote = base.appendingPathComponent("remote", isDirectory: true)
        try makeRemote()
    }

    // MARK: - Fixture repository

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRemote() throws {
        try FileManager.default.createDirectory(
            at: remote.appendingPathComponent("writer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: remote.appendingPathComponent("reviewer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("# writer v1\n".utf8).write(
            to: remote.appendingPathComponent("writer/SKILL.md")
        )
        try Data("# reviewer v1\n".utf8).write(
            to: remote.appendingPathComponent("reviewer/SKILL.md")
        )
        try git(["init", "--initial-branch=main"], in: remote)
        try git(["add", "."], in: remote)
        try git(["commit", "-m", "initial skills"], in: remote)
    }

    @discardableResult
    private func commitWriterUpdate(_ body: String, message: String) throws -> String {
        try Data(body.utf8).write(to: remote.appendingPathComponent("writer/SKILL.md"))
        try git(["add", "."], in: remote)
        try git(["commit", "-m", message], in: remote)
        return try git(["rev-parse", "HEAD"], in: remote)
    }

    private func package(
        subpath: String? = "writer",
        tracking: ExtensionSource.TrackingMode = .branch("main"),
        activeRevision: InstalledRevision? = nil
    ) -> ExtensionPackage {
        ExtensionPackage(
            id: "acme/skills:\(subpath ?? "-")",
            kind: .skill,
            name: subpath ?? "skills",
            source: .managedGitHub(repository: repository, subpath: subpath, tracking: tracking),
            activeRevision: activeRevision
        )
    }

    private func engine(
        scan: @escaping (URL) -> [SecurityFinding] = { _ in [] },
        smokeTest: @escaping (URL) -> Bool = { _ in true }
    ) -> ExtensionUpdateEngine {
        ExtensionUpdateEngine(mirror: mirror, store: store, scan: scan, smokeTest: smokeTest)
    }

    // MARK: - Mirror

    func testTwoSkillsInOneRepositoryShareASingleMirror() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let before = try FileManager.default.contentsOfDirectory(atPath: layout.mirrors.path)
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let after = try FileManager.default.contentsOfDirectory(atPath: layout.mirrors.path)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.count, 1)
    }

    func testResolvesBranchTagAndPinnedCommit() throws {
        try git(["tag", "v1"], in: remote)
        let head = try git(["rev-parse", "HEAD"], in: remote)
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)

        XCTAssertEqual(try mirror.resolve(.branch("main"), repository: repository), head)
        XCTAssertEqual(try mirror.resolve(.tag("v1"), repository: repository), head)
        XCTAssertEqual(try mirror.resolve(.pinnedCommit(head), repository: repository), head)
        XCTAssertThrowsError(try mirror.resolve(.branch("nope"), repository: repository))
    }

    func testRevisionHoldsTheSubpathContentsAtItsRoot() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let head = try mirror.resolve(.branch("main"), repository: repository)
        let revision = try mirror.materializeRevision(
            repository: repository, sha: head, subpath: "writer"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: revision.appendingPathComponent("SKILL.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: revision.appendingPathComponent("writer").path
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: revision.appendingPathComponent(".git").path),
            "a revision is a plain directory, not a repository"
        )
    }

    func testRevisionIDsDifferPerSubpathAndCommit() throws {
        let a = ExtensionMirror.revisionID(repository: repository, sha: "abc123456789", subpath: "writer")
        let b = ExtensionMirror.revisionID(repository: repository, sha: "abc123456789", subpath: "reviewer")
        let c = ExtensionMirror.revisionID(repository: repository, sha: "def123456789", subpath: "writer")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMissingSubpathFailsWithoutLeavingAPartialRevision() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let head = try mirror.resolve(.branch("main"), repository: repository)
        XCTAssertThrowsError(
            try mirror.materializeRevision(repository: repository, sha: head, subpath: "absent")
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: layout.revisions.path)
        XCTAssertTrue(
            leftovers.filter { !$0.hasPrefix(".") }.isEmpty,
            "a failed checkout leaves no revision behind"
        )
    }

    // MARK: - Check

    func testNoUpdateWhenTheInstalledCommitIsCurrent() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let head = try mirror.resolve(.branch("main"), repository: repository)
        let installed = InstalledRevision(
            id: "r1", commitSHA: head, contentHash: "h", path: "/x",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(
            try engine().checkForUpdate(
                package(activeRevision: installed), remote: remote.path
            )
        )
    }

    func testBranchMovingForwardIsDetectedWithChangedFilesAndCount() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let first = try mirror.resolve(.branch("main"), repository: repository)
        try commitWriterUpdate("# writer v2\n", message: "writer: v2")
        try commitWriterUpdate("# writer v3\n", message: "writer: v3")

        let installed = InstalledRevision(
            id: "r1", commitSHA: first, contentHash: "h", path: "/x",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        let candidate = try engine().checkForUpdate(
            package(activeRevision: installed), remote: remote.path
        )
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.commitCount, 2)
        XCTAssertEqual(candidate?.changedFiles, ["writer/SKILL.md"])
        XCTAssertEqual(candidate?.installedCommitSHA, first)
        XCTAssertTrue(candidate?.changelog?.contains("writer: v3") == true)
    }

    func testChangesOutsideTheSubpathAreNotReportedAsChangedFiles() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let first = try mirror.resolve(.branch("main"), repository: repository)
        try Data("# reviewer v2\n".utf8).write(
            to: remote.appendingPathComponent("reviewer/SKILL.md")
        )
        try git(["add", "."], in: remote)
        try git(["commit", "-m", "reviewer: v2"], in: remote)

        let installed = InstalledRevision(
            id: "r1", commitSHA: first, contentHash: "h", path: "/x",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        let candidate = try engine().checkForUpdate(
            package(activeRevision: installed), remote: remote.path
        )
        XCTAssertEqual(candidate?.changedFiles, [], "writer's files did not move")
    }

    func testUnmanagedSourcesAreNeverUpdateChecked() {
        let local = ExtensionPackage(
            id: "local", kind: .skill, name: "local", source: .local(path: "/tmp/x")
        )
        XCTAssertThrowsError(try engine().checkForUpdate(local, remote: remote.path)) { error in
            XCTAssertEqual(error as? ExtensionUpdateError, .notManaged("local"))
        }
    }

    func testPinnedCommitDoesNotFollowTheBranch() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let pinned = try mirror.resolve(.branch("main"), repository: repository)
        try commitWriterUpdate("# writer v2\n", message: "writer: v2")

        let installed = InstalledRevision(
            id: "r1", commitSHA: pinned, contentHash: "h", path: "/x",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(
            try engine().checkForUpdate(
                package(tracking: .pinnedCommit(pinned), activeRevision: installed),
                remote: remote.path
            )
        )
    }

    // MARK: - Stage

    func testStagingChecksStructureExecutablesAndSmokeTest() throws {
        try Data("echo hi\n".utf8).write(to: remote.appendingPathComponent("writer/run.sh"))
        _ = try git(["update-index", "--add", "--chmod=+x", "writer/run.sh"], in: remote)
        try git(["commit", "-m", "writer: add script"], in: remote)

        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let staged = try engine().stage(candidate, package: package())

        XCTAssertTrue(staged.structureIssues.isEmpty)
        XCTAssertEqual(staged.executables, ["run.sh"])
        XCTAssertTrue(staged.smokeTestPassed)
        XCTAssertTrue(staged.isActivatable)
        XCTAssertEqual(staged.commitSHA, candidate.availableCommitSHA)
    }

    func testMissingEntrypointBlocksActivation() throws {
        try FileManager.default.removeItem(at: remote.appendingPathComponent("writer/SKILL.md"))
        try Data("noop\n".utf8).write(to: remote.appendingPathComponent("writer/other.txt"))
        try git(["add", "-A"], in: remote)
        try git(["commit", "-m", "writer: drop SKILL.md"], in: remote)

        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let staged = try engine().stage(candidate, package: package())

        XCTAssertFalse(staged.isActivatable)
        XCTAssertTrue(staged.blockingReason?.contains("SKILL.md") == true)
        XCTAssertFalse(staged.smokeTestPassed, "gates after a structural failure do not run")
    }

    func testBlockedFindingStopsActivationButAWarningDoesNot() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!

        let blocking = engine(scan: { _ in
            [SecurityFinding(
                id: "f1", origin: .uncoil, severity: .blocked, rule: "known-malicious",
                message: "bilinen zararlı paket", foundAt: Date(timeIntervalSince1970: 0)
            )]
        })
        let blocked = try blocking.stage(candidate, package: package())
        XCTAssertFalse(blocked.isActivatable)
        XCTAssertEqual(blocked.blockingReason, "bilinen zararlı paket")

        let warning = engine(scan: { _ in
            [SecurityFinding(
                id: "f2", origin: .uncoil, severity: .needsReview, rule: "risky-command.curl",
                message: "curl | sh", foundAt: Date(timeIntervalSince1970: 0)
            )]
        })
        XCTAssertTrue(try warning.stage(candidate, package: package()).isActivatable)
    }

    func testAcceptedBlockingFindingNoLongerStopsActivation() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let staged = try engine(scan: { _ in
            [SecurityFinding(
                id: "f1", origin: .bumblebee, severity: .blocked, rule: "r",
                message: "m", foundAt: Date(timeIntervalSince1970: 0), isAccepted: true
            )]
        }).stage(candidate, package: package())
        XCTAssertTrue(staged.isActivatable)
    }

    func testFailedSmokeTestStopsActivation() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let staged = try engine(smokeTest: { _ in false }).stage(candidate, package: package())
        XCTAssertFalse(staged.isActivatable)
        XCTAssertEqual(staged.blockingReason, "The smoke test failed.")
    }

    func testSymlinkEscapeIsCaught() throws {
        let escape = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: escape, withIntermediateDirectories: true)
        let package = base.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("# s\n".utf8).write(to: package.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("escape"), withDestinationURL: escape
        )
        let issues = ExtensionUpdateEngine.structureIssues(at: package, kind: .skill)
        XCTAssertTrue(issues.contains { $0.contains("symlink") })

        // An internal symlink is fine.
        let inner = base.appendingPathComponent("pkg2", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("# s\n".utf8).write(to: inner.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("alias"),
            withDestinationURL: inner.appendingPathComponent("SKILL.md")
        )
        XCTAssertTrue(ExtensionUpdateEngine.structureIssues(at: inner, kind: .skill).isEmpty)
    }

    func testMCPPackagesNeedTheirOwnEntrypoint() throws {
        let package = base.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertFalse(
            ExtensionUpdateEngine.structureIssues(at: package, kind: .mcpServer).isEmpty
        )
        try Data("{}".utf8).write(to: package.appendingPathComponent("package.json"))
        XCTAssertTrue(
            ExtensionUpdateEngine.structureIssues(at: package, kind: .mcpServer).isEmpty
        )
    }

    // MARK: - Activate and roll back

    func testActivationIsAtomicAndKeepsThePreviousRevision() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)

        // v1 installed and linked into an agent.
        let firstCandidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let firstStaged = try engine().stage(firstCandidate, package: package())
        var current = try engine().activate(firstStaged, package: package(), skillName: "writer")
        let agentDirectory = base.appendingPathComponent("claude/skills", isDirectory: true)
        try store.link(name: "writer", intoAgentDirectory: agentDirectory)
        XCTAssertEqual(
            try String(contentsOf: agentDirectory.appendingPathComponent("writer/SKILL.md"), encoding: .utf8),
            "# writer v1\n"
        )

        // v2 published, staged, activated.
        try commitWriterUpdate("# writer v2\n", message: "writer: v2")
        var v2Package = package()
        v2Package.activeRevision = current.activeRevision
        let secondCandidate = try engine().checkForUpdate(v2Package, remote: remote.path)!
        let secondStaged = try engine().stage(secondCandidate, package: v2Package)
        current = try engine().activate(secondStaged, package: v2Package, skillName: "writer")

        XCTAssertEqual(
            try String(contentsOf: agentDirectory.appendingPathComponent("writer/SKILL.md"), encoding: .utf8),
            "# writer v2\n",
            "the agent's link follows the swapped pointer"
        )
        XCTAssertEqual(current.previousRevision?.commitSHA, firstCandidate.availableCommitSHA)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: current.previousRevision!.path),
            "the previous revision survives for rollback"
        )
    }

    func testFailedStageLeavesTheActiveRevisionAlone() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        let good = try engine().stage(candidate, package: package())
        let active = try engine().activate(good, package: package(), skillName: "writer")

        try commitWriterUpdate("# writer bad\n", message: "writer: bad")
        var next = package()
        next.activeRevision = active.activeRevision
        let badCandidate = try engine().checkForUpdate(next, remote: remote.path)!
        let badStaged = try engine(smokeTest: { _ in false }).stage(badCandidate, package: next)

        XCTAssertThrowsError(
            try engine().activate(badStaged, package: next, skillName: "writer")
        )
        XCTAssertEqual(
            store.activeStatus(name: "writer", expectedRevisionID: active.activeRevision!.id),
            .linked,
            "the active pointer never moved"
        )
    }

    func testRollbackReturnsToThePreviousCommitAndChecksHealth() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let first = try engine().stage(
            try engine().checkForUpdate(package(), remote: remote.path)!, package: package()
        )
        var current = try engine().activate(first, package: package(), skillName: "writer")

        try commitWriterUpdate("# writer v2\n", message: "writer: v2")
        var next = package()
        next.activeRevision = current.activeRevision
        let second = try engine().stage(
            try engine().checkForUpdate(next, remote: remote.path)!, package: next
        )
        current = try engine().activate(second, package: next, skillName: "writer")

        let result = try engine().rollback(current, skillName: "writer")
        XCTAssertEqual(result.package.activeRevision?.commitSHA, first.commitSHA)
        XCTAssertEqual(result.health.outcome, .ok)

        let agentDirectory = base.appendingPathComponent("claude/skills", isDirectory: true)
        try store.link(name: "writer", intoAgentDirectory: agentDirectory)
        XCTAssertEqual(
            try String(contentsOf: agentDirectory.appendingPathComponent("writer/SKILL.md"), encoding: .utf8),
            "# writer v1\n"
        )
    }

    func testRollbackWithoutAPreviousRevisionFails() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let staged = try engine().stage(
            try engine().checkForUpdate(package(), remote: remote.path)!, package: package()
        )
        let current = try engine().activate(staged, package: package(), skillName: "writer")
        XCTAssertThrowsError(try engine().rollback(current, skillName: "writer")) { error in
            XCTAssertEqual(error as? ExtensionUpdateError, .noPreviousRevision(current.id))
        }
    }

    // MARK: - Interruptions and garbage collection

    func testInterruptedUpdateIsCleanedUpWithoutTouchingLiveRevisions() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let staged = try engine().stage(
            try engine().checkForUpdate(package(), remote: remote.path)!, package: package()
        )
        let current = try engine().activate(staged, package: package(), skillName: "writer")

        // A checkout that died halfway, plus a revision nothing points at.
        let staging = layout.revisions.appendingPathComponent(".staging-dead", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let orphan = layout.revision("orphan-revision")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let removed = engine().recoverAfterInterruption(packages: [current])
        XCTAssertTrue(removed.contains(".staging-dead"))
        XCTAssertTrue(removed.contains("orphan-revision"))
        XCTAssertFalse(removed.contains(current.activeRevision!.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.activeRevision!.path))
    }

    func testGarbageCollectionKeepsActiveAndPreviousRevisions() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let first = try engine().stage(
            try engine().checkForUpdate(package(), remote: remote.path)!, package: package()
        )
        var current = try engine().activate(first, package: package(), skillName: "writer")
        try commitWriterUpdate("# writer v2\n", message: "writer: v2")
        var next = package()
        next.activeRevision = current.activeRevision
        let second = try engine().stage(
            try engine().checkForUpdate(next, remote: remote.path)!, package: next
        )
        current = try engine().activate(second, package: next, skillName: "writer")

        engine().recoverAfterInterruption(packages: [current])
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.activeRevision!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.previousRevision!.path))
    }

    func testStagingStopsSafelyWhenDiskSpaceIsShort() throws {
        _ = try mirror.ensureMirror(repository: repository, remote: remote.path)
        let candidate = try engine().checkForUpdate(package(), remote: remote.path)!
        var tight = engine()
        tight.minimumFreeBytes = .max
        XCTAssertThrowsError(try tight.stage(candidate, package: package())) { error in
            guard case .diskFull = error as? ExtensionUpdateError else {
                return XCTFail("expected a disk-full failure, got \(error)")
            }
        }
    }
}
