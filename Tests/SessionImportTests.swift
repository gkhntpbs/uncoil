import XCTest
@testable import Uncoil

/// Finding conversations Claude Code and Codex already keep for a project,
/// and recording them as sessions that resume where they left off. The
/// fixtures are shaped after real transcripts: Claude's line types and field
/// names, Codex's `session_meta` and `session_index.jsonl`.
@MainActor
final class SessionImportTests: XCTestCase {
    private var root: URL!
    private var projectRoot: String!
    private var claudeHome: URL!
    private var codexHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilSessionImport-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Work Projects/alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        projectRoot = project.path
        claudeHome = root.appendingPathComponent("claude-home", isDirectory: true)
        codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func write(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let text = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func claudeTranscript(
        id: String,
        cwd: String,
        prompt: String? = "Fix the login redirect\nand add a test",
        aiTitles: [String] = [],
        customTitle: String? = nil,
        directory: String? = nil
    ) throws {
        var lines: [[String: Any]] = [
            ["type": "mode", "mode": "default", "sessionId": id],
            ["type": "attachment", "cwd": cwd, "sessionId": id, "timestamp": "2026-09-26T16:17:35.943Z",
             "isSidechain": false, "attachment": [:]],
            ["type": "user", "isMeta": true, "cwd": cwd, "sessionId": id, "isSidechain": false,
             "timestamp": "2026-09-26T16:17:35.901Z",
             "message": ["role": "user", "content": "<local-command-caveat>Caveat: …</local-command-caveat>"]],
            ["type": "user", "cwd": cwd, "sessionId": id, "isSidechain": false,
             "timestamp": "2026-09-26T16:17:35.848Z",
             "message": ["role": "user", "content": "<command-name>/clear</command-name>"]],
        ]
        if let prompt {
            lines.append(["type": "user", "cwd": cwd, "sessionId": id, "isSidechain": false,
                          "timestamp": "2026-09-26T16:18:00.000Z",
                          "message": ["role": "user", "content": [["type": "text", "text": prompt]]]])
            lines.append(["type": "assistant", "cwd": cwd, "sessionId": id, "isSidechain": false,
                          "timestamp": "2026-09-26T16:19:00.000Z",
                          "message": ["role": "assistant", "content": [["type": "text", "text": "On it."]]]])
        }
        for title in aiTitles {
            lines.append(["type": "ai-title", "aiTitle": title, "sessionId": id])
        }
        if let customTitle {
            lines.append(["type": "custom-title", "customTitle": customTitle, "sessionId": id])
        }
        let folder = directory ?? ClaudeSessionStore.projectSlug(for: cwd)
        try write(lines, to: claudeHome.appendingPathComponent("projects/\(folder)/\(id).jsonl"))
    }

    private func codexRollout(
        id: String,
        cwd: String,
        prompt: String = "Tidy up the settings page",
        threadSource: String = "user",
        day: String = "2026/10/01"
    ) throws {
        let lines: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-10-01T09:38:51.160Z",
             "payload": ["id": id, "timestamp": "2026-10-01T09:38:51.160Z", "cwd": cwd,
                         "source": "cli", "thread_source": threadSource]],
            ["type": "response_item",
             "payload": ["type": "message", "role": "developer",
                         "content": [["type": "input_text", "text": "You are Codex"]]]],
            ["type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "# AGENTS.md instructions\n…"],
                                     ["type": "input_text", "text": "<environment_context>…"]]]],
            ["type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": prompt]]]],
        ]
        try write(lines, to: codexHome.appendingPathComponent(
            "sessions/\(day)/rollout-2026-10-01T12-38-51-\(id).jsonl"
        ))
    }

    private var sources: [SessionImportSource] {
        [
            SessionImportSource(provider: .claude, root: claudeHome, accountID: nil, name: "~/.claude"),
            SessionImportSource(provider: .codex, root: codexHome, accountID: nil, name: "~/.codex"),
        ]
    }

    private func scan() -> [ImportableSession] {
        SessionImportScanner.scan(projectRoot: projectRoot, sources: sources)
    }

    // MARK: - Claude

    func testClaudeConversationIsFoundWithItsRealPromptAndDates() throws {
        try claudeTranscript(id: "c-1", cwd: projectRoot)
        let found = scan()
        XCTAssertEqual(found.map(\.providerSessionID), ["c-1"])
        let session = try XCTUnwrap(found.first)
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.title, "Fix the login redirect")
        XCTAssertNil(session.worktreePath)
        XCTAssertEqual(session.startedAt, CodexSessionLocator.parseTimestamp("2026-09-26T16:17:35.848Z"))
    }

    func testClaudeTitlePrefersTheUsersThenTheLatestGeneratedOne() throws {
        try claudeTranscript(id: "c-ai", cwd: projectRoot, aiTitles: ["Old title", "Login redirect fix"])
        try claudeTranscript(
            id: "c-custom", cwd: projectRoot, aiTitles: ["Generated"], customTitle: "Auth refactor"
        )
        let titles = Dictionary(uniqueKeysWithValues: scan().map { ($0.providerSessionID, $0.title) })
        XCTAssertEqual(titles["c-ai"], "Login redirect fix")
        XCTAssertEqual(titles["c-custom"], "Auth refactor")
    }

    func testClaudeTranscriptWithoutAPromptIsNotAConversation() throws {
        try claudeTranscript(id: "c-empty", cwd: projectRoot, prompt: nil, aiTitles: ["Something"])
        XCTAssertTrue(scan().isEmpty)
    }

    func testClaudeDirectoryThatOnlySharesAPrefixIsPlacedByItsCwd() throws {
        // `alpha` is a prefix of `alpha-landing`, and Claude's folder for the
        // latter starts with the former's name.
        let sibling = projectRoot + "-landing"
        try claudeTranscript(id: "c-sibling", cwd: sibling)
        try claudeTranscript(id: "c-sub", cwd: projectRoot + "/Sources")
        XCTAssertTrue(scan().isEmpty)
    }

    func testClaudeConversationInALinkedWorktreeKeepsTheWorktree() throws {
        let worktree = root.appendingPathComponent("alpha-wt", isDirectory: true).path
        let admin = URL(fileURLWithPath: projectRoot).appendingPathComponent(".git/worktrees/alpha-wt")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "\(worktree)/.git\n".write(
            to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8
        )
        try claudeTranscript(id: "c-wt", cwd: worktree)
        let session = try XCTUnwrap(scan().first)
        XCTAssertEqual(session.worktreePath, worktree)
        XCTAssertEqual(session.cwd, worktree)
    }

    func testAPastedFirstPromptStillNamesTheSession() throws {
        try claudeTranscript(
            id: "c-paste", cwd: projectRoot,
            prompt: "<pasted_content id=\"ab12\">\nRefactor the parser so it streams\n</pasted_content id=\"ab12\">"
        )
        XCTAssertEqual(scan().first?.title, "Refactor the parser so it streams")
    }

    func testUncoilAutoRunsAreUncoilsOwnAndNotListed() throws {
        let rolePrompt = """
        <pasted_content id="d284">
        You are the Researcher in an Uncoil Auto run. Find the outside information.
        ```\(AutoHandoff.fence)
        {"summary": "..."}
        ```
        </pasted_content id="d284">
        """
        try claudeTranscript(id: "c-auto", cwd: projectRoot, prompt: rolePrompt)
        try codexRollout(id: "x-auto", cwd: projectRoot, prompt: rolePrompt)
        XCTAssertTrue(scan().isEmpty)
    }

    func testPromptClassification() {
        XCTAssertEqual(SessionImportScanner.classify("  fix it \n"), .typed("fix it"))
        XCTAssertEqual(SessionImportScanner.classify("<command-name>/clear</command-name>"), .ignored)
        XCTAssertEqual(SessionImportScanner.classify("# AGENTS.md instructions"), .ignored)
        XCTAssertEqual(SessionImportScanner.classify("<pasted_content id=\"1\">hi</pasted_content id=\"1\">"), .pasted("hi"))
        XCTAssertEqual(SessionImportScanner.classify("   "), .ignored)
    }

    // MARK: - Codex

    func testCodexThreadIsNamedFromTheIndexOrItsFirstRealPrompt() throws {
        try codexRollout(id: "x-named", cwd: projectRoot)
        try codexRollout(id: "x-plain", cwd: projectRoot, prompt: "Add dark mode", day: "2026/10/02")
        try #"{"id":"x-named","thread_name":"Settings cleanup","updated_at":"2026-10-01T10:00:00Z"}"#
            .appending("\n")
            .write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let titles = Dictionary(uniqueKeysWithValues: scan().map { ($0.providerSessionID, $0.title) })
        XCTAssertEqual(titles["x-named"], "Settings cleanup")
        XCTAssertEqual(titles["x-plain"], "Add dark mode")
    }

    func testCodexSkipsOtherProjectsAndThreadsItSpawnedItself() throws {
        try codexRollout(id: "x-other", cwd: root.appendingPathComponent("beta").path)
        try codexRollout(id: "x-review", cwd: projectRoot, threadSource: "subagent")
        XCTAssertTrue(scan().isEmpty)
    }

    func testScanListsNewestFirstAndEachConversationOnce() throws {
        try claudeTranscript(id: "c-1", cwd: projectRoot)
        try codexRollout(id: "x-1", cwd: projectRoot)
        // The same Claude store listed twice, as a home and a profile would be
        // if they pointed at one folder.
        let doubled = sources + [
            SessionImportSource(provider: .claude, root: claudeHome, accountID: UUID(), name: "Work"),
        ]
        let found = SessionImportScanner.scan(projectRoot: projectRoot, sources: doubled)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.filter { $0.provider == .claude }.first?.sourceName, "~/.claude")
        XCTAssertEqual(found.map(\.lastActivityAt), found.map(\.lastActivityAt).sorted(by: >))
    }

    // MARK: - Recording

    private func makeStore() throws -> (ProjectStore, UUID) {
        let store = ProjectStore(directory: root.appendingPathComponent("uncoil-data", isDirectory: true))
        store.addProject(at: URL(fileURLWithPath: projectRoot))
        return (store, try XCTUnwrap(store.projects.first?.id))
    }

    func testImportedSessionsSleepAndResumeTheirConversation() throws {
        try claudeTranscript(id: "c-1", cwd: projectRoot, aiTitles: ["Login redirect fix"])
        let (store, projectID) = try makeStore()
        let found = scan()

        let imported = store.importSessions(found, into: projectID)
        let record = try XCTUnwrap(imported.first)
        XCTAssertEqual(record.provider, .claude)
        XCTAssertEqual(record.providerSessionID, "c-1")
        XCTAssertEqual(record.title, "Login redirect fix")
        XCTAssertEqual(record.sleepMode, .hibernated)
        XCTAssertNil(record.endedAt)
        XCTAssertEqual(record.createdAt, found[0].startedAt)
        XCTAssertFalse(record.hasPlaceholderTitle)

        // Waking it is a resume, because the transcript is where Claude looks.
        let project = try XCTUnwrap(store.projects.first)
        let decision = TerminalRegistry.resumeDecision(
            for: record, cwd: record.workingDirectory(in: project), configDirectory: claudeHome
        )
        XCTAssertEqual(decision, .resume("c-1"))
        let command = TerminalRegistry.launchCommand(for: record, resume: decision, extraArguments: nil)
        XCTAssertTrue(command?.contains("--resume 'c-1'") == true || command?.contains("--resume c-1") == true,
                      command ?? "nil")
    }

    func testImportingTwiceAddsNothingAndSurvivesAReload() throws {
        try claudeTranscript(id: "c-1", cwd: projectRoot)
        try codexRollout(id: "x-1", cwd: projectRoot)
        let (store, projectID) = try makeStore()

        XCTAssertEqual(store.importSessions(scan(), into: projectID).count, 2)
        XCTAssertEqual(store.importSessions(scan(), into: projectID).count, 0)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(
            store.importedConversationKeys,
            ["claude:c-1", "codex:x-1"]
        )

        let reloaded = ProjectStore(directory: root.appendingPathComponent("uncoil-data", isDirectory: true))
        XCTAssertEqual(reloaded.sessions.count, 2)
        XCTAssertTrue(reloaded.sessions.allSatisfy { $0.sleepMode == .hibernated })
    }

    func testImportedSessionsArriveOldestFirstAtTheEndOfTheList() throws {
        let (store, projectID) = try makeStore()
        store.createSession(projectID: projectID, provider: .terminal, accountID: nil, title: "existing")
        let old = ImportableSession(
            provider: .claude, providerSessionID: "old", title: "Old", cwd: projectRoot,
            worktreePath: nil, startedAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 200), accountID: nil, sourceName: "~/.claude"
        )
        let new = ImportableSession(
            provider: .claude, providerSessionID: "new", title: "New", cwd: projectRoot,
            worktreePath: nil, startedAt: Date(timeIntervalSince1970: 300),
            lastActivityAt: Date(timeIntervalSince1970: 400), accountID: nil, sourceName: "~/.claude"
        )
        store.importSessions([new, old], into: projectID)
        XCTAssertEqual(store.sessions(for: projectID).map(\.title), ["existing", "Old", "New"])
        XCTAssertEqual(
            store.sessions.first { $0.providerSessionID == "new" }?.lastActivityAt,
            Date(timeIntervalSince1970: 400)
        )
    }

    func testAnAccountsStoreIsCarriedOntoTheSession() throws {
        let profile = UUID()
        try claudeTranscript(id: "c-1", cwd: projectRoot)
        let (store, projectID) = try makeStore()
        let found = SessionImportScanner.scan(
            projectRoot: projectRoot,
            sources: [SessionImportSource(provider: .claude, root: claudeHome, accountID: profile, name: "Work")]
        )
        XCTAssertEqual(store.importSessions(found, into: projectID).first?.accountID, profile)
    }
}
