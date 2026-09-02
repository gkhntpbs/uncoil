import XCTest
@testable import Uncoil

/// Whether a launch carries a resume flag.
final class AgentResumeDecisionTests: XCTestCase {
    private func decide(
        _ provider: AgentProvider,
        _ id: String?,
        _ state: AgentResumeState
    ) -> AgentResumeDecision {
        AgentResume.decide(provider: provider, providerSessionID: id) { _ in state }
    }

    func testAConversationThatIsStillThereIsResumed() {
        XCTAssertEqual(decide(.claude, "abc", .resumable), .resume("abc"))
    }

    /// The bug. `claude --resume <id>` on a transcript Claude no longer has
    /// prints "No conversation found with session ID: …" and exits, so the
    /// session opened onto one line of error and nothing else.
    func testAConversationTheProviderHasLostStartsFresh() {
        XCTAssertEqual(decide(.claude, "abc", .gone), .fresh(.gone))
    }

    /// Codex refuses a second writer on a thread: `thread <id> already has an
    /// active writer (code -32600)`. An agent process that outlived its daemon
    /// still holds the lock, so the resume died on its first line.
    func testAConversationAnotherProcessHoldsStartsFresh() {
        XCTAssertEqual(decide(.codex, "abc", .busy), .fresh(.busy))
    }

    /// A provider whose store Uncoil has not verified is resumed anyway.
    /// Refusing a resume that would have worked is worse than the error it
    /// would have avoided.
    func testAnUnreadableStoreStillResumes() {
        XCTAssertEqual(decide(.grok, "abc", .unknown), .resume("abc"))
    }

    func testNoIdIsAnOrdinaryNewSession() {
        XCTAssertEqual(decide(.claude, nil, .resumable), .fresh(nil))
        XCTAssertEqual(decide(.claude, "", .resumable), .fresh(nil))
        XCTAssertNil(decide(.claude, nil, .resumable).obstacle)
    }

    /// Gemini has no verified resume flag at all, so nothing is passed however
    /// tempting the stored id looks.
    func testAProviderThatCannotResumeNeverDoes() {
        XCTAssertFalse(AgentProvider.gemini.resumesConversation)
        XCTAssertEqual(decide(.gemini, "abc", .resumable), .fresh(nil))
    }

    /// The store is only touched when there is something to ask about.
    func testANewSessionAsksTheProviderNothing() {
        var asked = 0
        _ = AgentResume.decide(provider: .claude, providerSessionID: nil) { _ in
            asked += 1
            return .resumable
        }
        XCTAssertEqual(asked, 0)
    }
}

/// Where Claude files a conversation.
final class ClaudeSessionStoreTests: XCTestCase {
    /// Every one of these was checked against a directory that exists in a
    /// real `~/.claude/projects`, because the rule is Claude's and guessing it
    /// would send the lookup to a directory that is not there.
    func testTheProjectSlugMatchesClaudesOwnDirectoryNames() {
        let cases: [(String, String)] = [
            (
                "/Volumes/SN770 1TB M2 SSD/Developer/Projects/uncoil",
                "-Volumes-SN770-1TB-M2-SSD-Developer-Projects-uncoil"
            ),
            (
                "/Users/gokhantopbas/Developer/Projects/gokhantopbas.com",
                "-Users-gokhantopbas-Developer-Projects-gokhantopbas-com"
            ),
            // A worktree is filed under its own name, which is why resuming in
            // the wrong working directory finds nothing even though the
            // transcript is right there. Note the double hyphen: `/.` is two
            // characters and becomes two.
            (
                "/Volumes/SN770 1TB M2 SSD/Developer/Projects/moonlet/.uncoil-worktrees/comic-support",
                "-Volumes-SN770-1TB-M2-SSD-Developer-Projects-moonlet--uncoil-worktrees-comic-support"
            ),
            ("/private/tmp", "-private-tmp"),
        ]
        for (path, slug) in cases {
            XCTAssertEqual(ClaudeSessionStore.projectSlug(for: path), slug, path)
        }
    }

    /// Claude replaces on `[^a-zA-Z0-9]`, which Swift's own `isLetter` does
    /// not: it would keep `ş` and send the lookup somewhere that is not there.
    func testNonASCIILettersBecomeHyphensToo() {
        XCTAssertEqual(
            ClaudeSessionStore.projectSlug(for: "/Users/x/Projeler/işyeri"),
            "-Users-x-Projeler-i-yeri"
        )
    }

    func testAMissingTranscriptReadsAsGone() {
        let home = URL(fileURLWithPath: "/nowhere")
        XCTAssertEqual(
            ClaudeSessionStore.state(
                configDirectory: home, cwd: "/repo", sessionID: "abc", fileExists: { _ in false }
            ),
            .gone
        )
        XCTAssertEqual(
            ClaudeSessionStore.state(
                configDirectory: home, cwd: "/repo", sessionID: "abc", fileExists: { _ in true }
            ),
            .resumable
        )
    }

    func testTheTranscriptPathIsBuiltFromTheWorkingDirectory() {
        let url = ClaudeSessionStore.transcriptURL(
            configDirectory: URL(fileURLWithPath: "/home/.claude"),
            cwd: "/repo/tree",
            sessionID: "abc"
        )
        XCTAssertEqual(url.path, "/home/.claude/projects/-repo-tree/abc.jsonl")
    }
}

/// Codex's thread lock and rollout files.
final class CodexSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAThreadNobodyHasOpenedIsNotBusy() {
        XCTAssertFalse(CodexSessionStore.isBusy(codexHome: root, threadID: "abc"))
    }

    /// The real thing: a lock file held by another process reads as busy, and
    /// the probe puts it back the way it found it.
    func testALockSomeoneElseHoldsReadsAsBusy() throws {
        let lock = CodexSessionStore.lockURL(codexHome: root, threadID: "abc")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: lock.path, contents: Data())

        let descriptor = open(lock.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(CodexSessionStore.isBusy(codexHome: root, threadID: "abc"))

        flock(descriptor, LOCK_UN)
        close(descriptor)
        XCTAssertFalse(
            CodexSessionStore.isBusy(codexHome: root, threadID: "abc"),
            "the probe must leave the lock exactly as it found it"
        )
    }

    /// Codex names a rollout `rollout-<timestamp>-<thread-id>.jsonl` and files
    /// it under the date it began, so the id is matched on the suffix rather
    /// than by rebuilding a path that would need that date.
    func testARolloutIsFoundByItsThreadIdWhereverItIsFiled() throws {
        let day = root
            .appendingPathComponent("sessions/2026/09/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent(
            "rollout-2026-09-01T12-38-00-01a05c55-2b50-79c0-9e60-7301fa4da86e.jsonl"
        )
        FileManager.default.createFile(atPath: file.path, contents: Data())

        XCTAssertTrue(
            CodexSessionStore.transcriptExists(
                codexHome: root, threadID: "01a05c55-2b50-79c0-9e60-7301fa4da86e"
            )
        )
        XCTAssertFalse(
            CodexSessionStore.transcriptExists(codexHome: root, threadID: "not-a-thread")
        )
    }

    func testAThreadWithNoRolloutIsGone() {
        XCTAssertEqual(
            CodexSessionStore.state(codexHome: root, threadID: "abc"), .gone
        )
    }
}
