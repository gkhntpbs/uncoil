import Foundation

/// Whether a provider can still take a session back into its conversation.
///
/// Uncoil used to pass `--resume <id>` whenever it had an id, and an id is not
/// a promise. Claude keeps its transcripts per working directory and prunes
/// them; Codex takes an exclusive writer lock per thread. So the flag was
/// handed to a CLI that answered "No conversation found with session ID: …"
/// and exited — leaving a terminal with one line of error in it and no way
/// forward except deleting the session.
enum AgentResumeState: Equatable {
    /// The provider's own store has this conversation and nothing else holds it.
    case resumable
    /// The provider's store no longer has it.
    case gone
    /// Another process is already writing to it.
    case busy
    /// Uncoil cannot read this provider's store, so it does not pretend to
    /// know. Resume is attempted, which is what happened before.
    case unknown
}

/// Why a session had to start fresh. Said out loud rather than swallowed: a
/// conversation that quietly did not come back is the same to the user as one
/// that was lost.
enum AgentResumeObstacle: Equatable {
    case gone
    case busy

    func message(for provider: AgentProvider) -> String {
        switch self {
        case .gone:
            String(localized: "Started fresh — \(provider.displayName) no longer has this conversation.")
        case .busy:
            String(localized: "Started fresh — this conversation is open in another \(provider.displayName) process.")
        }
    }
}

enum AgentResumeDecision: Equatable {
    case resume(String)
    /// Nothing to go back to. `obstacle` is nil when there never was an id —
    /// an ordinary new session, not a failure.
    case fresh(AgentResumeObstacle?)

    var sessionID: String? {
        if case .resume(let id) = self { return id }
        return nil
    }

    var obstacle: AgentResumeObstacle? {
        if case .fresh(let obstacle) = self { return obstacle }
        return nil
    }
}

enum AgentResume {
    /// The one place that decides whether a launch carries a resume flag.
    ///
    /// `state` is asked only when there is something to ask about, so a new
    /// session never touches the disk.
    static func decide(
        provider: AgentProvider,
        providerSessionID: String?,
        state: (String) -> AgentResumeState
    ) -> AgentResumeDecision {
        guard provider.resumesConversation,
              let id = providerSessionID,
              !id.isEmpty
        else { return .fresh(nil) }
        switch state(id) {
        case .resumable, .unknown: return .resume(id)
        case .gone: return .fresh(.gone)
        case .busy: return .fresh(.busy)
        }
    }
}

// MARK: - Claude

/// Where Claude Code keeps a conversation, and whether it still has one.
enum ClaudeSessionStore {
    /// Claude files a conversation under the directory it was held in, with
    /// every character that is not a letter or a digit turned into a hyphen:
    /// `/Volumes/SN770 1TB M2 SSD/…/uncoil` becomes
    /// `-Volumes-SN770-1TB-M2-SSD-…-uncoil`. Read off the real directory names
    /// rather than guessed — a worktree gets a directory of its own, which is
    /// why resuming a session in the wrong working directory finds nothing
    /// even though the transcript is right there under another name.
    static func projectSlug(for path: String) -> String {
        // ASCII letters and digits only. Swift's `isLetter` would keep `ç` and
        // `ş`, and Claude does not: it replaces on `[^a-zA-Z0-9]`, so a project
        // with a Turkish name in its path would be looked for under a
        // directory that does not exist.
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func transcriptURL(
        configDirectory: URL,
        cwd: String,
        sessionID: String
    ) -> URL {
        configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectSlug(for: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    /// Claude has no lock to check: it is happy to open the same conversation
    /// twice. So the only question is whether the transcript is there.
    static func state(
        configDirectory: URL,
        cwd: String,
        sessionID: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> AgentResumeState {
        fileExists(transcriptURL(configDirectory: configDirectory, cwd: cwd, sessionID: sessionID))
            ? .resumable
            : .gone
    }

    /// `~/.claude`, or the isolated directory an Uncoil account uses.
    static func defaultConfigDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
}

// MARK: - Codex

/// Where Codex keeps a thread, and whether anyone else is writing to it.
enum CodexSessionStore {
    /// Codex takes an exclusive `flock` here for as long as it has a thread
    /// open, and refuses a second writer: `thread <id> already has an active
    /// writer (code -32600)`. It is a real lock rather than a pid file, so it
    /// clears the moment the holder dies — which also means the only way to
    /// see it is to try to take it.
    static func lockURL(codexHome: URL, threadID: String) -> URL {
        codexHome
            .appendingPathComponent("thread-writer-locks", isDirectory: true)
            .appendingPathComponent("\(threadID).lock")
    }

    /// True when some other process holds the thread's writer lock.
    ///
    /// The probe takes the lock and drops it again in the same breath. It has
    /// to: `flock` has no read-only enquiry, and the alternative — asking the
    /// system which process holds which descriptor — costs a subprocess per
    /// session. Nothing is created, so a thread that has never been opened
    /// simply has no lock file and reads as free.
    static func isBusy(codexHome: URL, threadID: String) -> Bool {
        let path = lockURL(codexHome: codexHome, threadID: threadID).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// The rollout file for a thread, if Codex still has one.
    ///
    /// Named `rollout-<timestamp>-<thread-id>.jsonl` and filed under
    /// `sessions/YYYY/MM/DD`, so the id is matched on the suffix rather than
    /// by rebuilding a path that would need the date the thread began.
    ///
    /// It walks the whole tree, and is asked only when a session with a stored
    /// thread is being reopened — never for a new one, and never for a thread
    /// whose lock is already held, which is checked first and answers without
    /// touching the tree at all. Measured against a year of real use: 484
    /// files, a couple of milliseconds.
    static func transcriptExists(
        codexHome: URL,
        threadID: String,
        manager: FileManager = .default
    ) -> Bool {
        transcriptURL(codexHome: codexHome, threadID: threadID, manager: manager) != nil
    }

    /// Where the thread's rollout file is, found the same way.
    static func transcriptURL(
        codexHome: URL,
        threadID: String,
        manager: FileManager = .default
    ) -> URL? {
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let suffix = "-\(threadID).jsonl"
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }

    static func state(codexHome: URL, threadID: String) -> AgentResumeState {
        if isBusy(codexHome: codexHome, threadID: threadID) { return .busy }
        return transcriptExists(codexHome: codexHome, threadID: threadID) ? .resumable : .gone
    }

    /// Waits for the thread's writer lock to come free, up to `timeout`.
    ///
    /// Restarting a Codex session kills the old process and launches the new
    /// one; the launch asks whether the thread is busy, and the old process —
    /// still flushing its rollout on the way out — was holding the lock at that
    /// moment. So the restart read its own predecessor as "another Codex
    /// process", started fresh, and the conversation was lost: "Continue"
    /// that sometimes did not. Waiting for the lock is what makes the restart
    /// see the thread as it is once the old process is actually gone.
    /// - Returns: whether the lock is free.
    @discardableResult
    static func waitUntilReleased(
        codexHome: URL,
        threadID: String,
        timeout: TimeInterval = 5,
        isBusy: @escaping (URL, String) -> Bool = { isBusy(codexHome: $0, threadID: $1) }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy(codexHome, threadID) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
