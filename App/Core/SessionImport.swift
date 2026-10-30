import Foundation

/// A conversation an agent CLI already has on disk for a project, found by
/// reading the CLI's own store — work done before Uncoil, or beside it.
///
/// Importing one does not copy anything: the transcript stays where the CLI
/// keeps it, and the session Uncoil records points at it by the provider's
/// own id, so opening it is `claude --resume <id>` / `codex resume <id>` — the
/// conversation the user had, not a summary of it.
struct ImportableSession: Identifiable, Equatable {
    var id: String { Self.key(provider: provider, providerSessionID: providerSessionID) }
    let provider: AgentProvider
    let providerSessionID: String
    let title: String
    /// Where the CLI held the conversation. Resuming has to happen here: Claude
    /// files transcripts by directory and finds nothing from anywhere else.
    let cwd: String
    /// nil when it ran in the project root, otherwise the worktree it ran in.
    let worktreePath: String?
    let startedAt: Date
    let lastActivityAt: Date
    /// The account profile whose config root holds the transcript, so the
    /// resume reads the same store. nil = the provider's own default home.
    let accountID: UUID?
    /// Which store it came from, for the list: "~/.claude", a profile name.
    let sourceName: String

    static func key(provider: AgentProvider, providerSessionID: String) -> String {
        "\(provider.rawValue):\(providerSessionID)"
    }
}

/// One place an agent CLI keeps conversations: its default home, or the
/// isolated config root of an Uncoil account profile.
struct SessionImportSource: Equatable {
    let provider: AgentProvider
    let root: URL
    let accountID: UUID?
    let name: String
}

/// Where a conversation sits relative to the project, if it belongs to it.
enum SessionImportPlacement: Equatable {
    case root
    case worktree(String)

    /// The project root itself, or a linked git worktree of it. A plain
    /// subdirectory is not offered: Uncoil would have to run the session there
    /// to resume it, and a session's directory is the project or a worktree,
    /// nothing in between.
    static func place(
        cwd: String,
        projectRoot: String,
        linkedWorktrees: Set<String>
    ) -> SessionImportPlacement? {
        let cwd = normalized(cwd)
        if cwd == normalized(projectRoot) { return .root }
        if linkedWorktrees.contains(cwd) { return .worktree(cwd) }
        return nil
    }

    static func normalized(_ path: String) -> String {
        var path = URL(fileURLWithPath: path).standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The repository's linked worktrees, read the way git records them —
    /// `.git/worktrees/<name>/gitdir` holds the path of the worktree's own
    /// `.git` file — so finding them costs a few small reads, not a `git`
    /// process per project.
    static func linkedWorktrees(
        of projectRoot: String,
        manager: FileManager = .default
    ) -> Set<String> {
        let admin = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        guard let entries = try? manager.contentsOfDirectory(
            at: admin, includingPropertiesForKeys: nil
        ) else { return [] }
        var paths: Set<String> = []
        for entry in entries {
            guard let text = try? String(
                contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8
            ) else { continue }
            let gitFile = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gitFile.isEmpty else { continue }
            paths.insert(normalized(URL(fileURLWithPath: gitFile).deletingLastPathComponent().path))
        }
        return paths
    }
}

enum SessionImportScanner {
    /// How much of a transcript's start is read for its directory, start time
    /// and first prompt. Attachments and hook output come before the first
    /// prompt, so this is generous; it is still a bounded read of a file that
    /// can run to megabytes.
    static let headBytes = 512 * 1024
    /// How much of the end is read for the latest title. Claude rewrites its
    /// title line as the conversation goes, so the last one is the current one.
    static let tailBytes = 256 * 1024

    /// Every conversation the sources hold for this project, newest first.
    ///
    /// The same conversation found in two stores is listed once — the first
    /// source wins, so callers list the default home before profiles.
    static func scan(
        projectRoot: String,
        sources: [SessionImportSource],
        manager: FileManager = .default
    ) -> [ImportableSession] {
        let worktrees = SessionImportPlacement.linkedWorktrees(of: projectRoot, manager: manager)
        var seen: Set<String> = []
        var found: [ImportableSession] = []
        for source in sources {
            let sessions: [ImportableSession]
            switch source.provider {
            case .claude:
                sessions = claude(
                    projectRoot: projectRoot, worktrees: worktrees, source: source, manager: manager
                )
            case .codex:
                sessions = codex(
                    projectRoot: projectRoot, worktrees: worktrees, source: source, manager: manager
                )
            default:
                sessions = []
            }
            for session in sessions where seen.insert(session.id).inserted {
                found.append(session)
            }
        }
        return found.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    // MARK: - Claude

    /// Claude keeps one directory per working directory under `projects/`,
    /// named by `ClaudeSessionStore.projectSlug`. The project's own directory
    /// is read, and so is every directory whose name extends it — a worktree
    /// inside the project, `.claude/worktrees/x`, is filed as the project's
    /// slug plus more — and the directories of its linked worktrees. A name
    /// match is only a hint (`uncoil` is a prefix of `uncoil-landing`), so
    /// every transcript is placed by the `cwd` it records.
    static func claude(
        projectRoot: String,
        worktrees: Set<String>,
        source: SessionImportSource,
        manager: FileManager = .default
    ) -> [ImportableSession] {
        let projects = source.root.appendingPathComponent("projects", isDirectory: true)
        guard let directories = try? manager.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        let rootSlug = ClaudeSessionStore.projectSlug(for: SessionImportPlacement.normalized(projectRoot))
        let worktreeSlugs = Set(worktrees.map(ClaudeSessionStore.projectSlug(for:)))
        var sessions: [ImportableSession] = []
        for directory in directories {
            let name = directory.lastPathComponent
            guard name == rootSlug || name.hasPrefix(rootSlug + "-") || worktreeSlugs.contains(name),
                  let files = try? manager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
                  )
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let summary = ClaudeTranscriptSummary.read(at: file),
                      let placement = SessionImportPlacement.place(
                          cwd: summary.cwd, projectRoot: projectRoot, linkedWorktrees: worktrees
                      )
                else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                sessions.append(ImportableSession(
                    provider: .claude,
                    providerSessionID: summary.sessionID,
                    title: summary.title,
                    cwd: summary.cwd,
                    worktreePath: placement.worktreePath,
                    startedAt: summary.startedAt,
                    lastActivityAt: max(modified ?? summary.lastTimestamp, summary.startedAt),
                    accountID: source.accountID,
                    sourceName: source.name
                ))
            }
        }
        return sessions
    }

    // MARK: - Codex

    /// Codex files rollouts by date, not by directory, so every rollout is
    /// opened and placed by the `cwd` in its `session_meta`. Thread names come
    /// from `session_index.jsonl`, which is where the TUI writes a renamed or
    /// auto-named thread.
    static func codex(
        projectRoot: String,
        worktrees: Set<String>,
        source: SessionImportSource,
        manager: FileManager = .default
    ) -> [ImportableSession] {
        let root = source.root.appendingPathComponent("sessions", isDirectory: true)
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let names = CodexRolloutSummary.threadNames(codexHome: source.root)
        var sessions: [ImportableSession] = []
        for case let file as URL in walker
        where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
            guard let summary = CodexRolloutSummary.read(at: file),
                  let placement = SessionImportPlacement.place(
                      cwd: summary.cwd, projectRoot: projectRoot, linkedWorktrees: worktrees
                  ),
                  let title = names[summary.threadID] ?? summary.firstPrompt
            else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            sessions.append(ImportableSession(
                provider: .codex,
                providerSessionID: summary.threadID,
                title: title,
                cwd: summary.cwd,
                worktreePath: placement.worktreePath,
                startedAt: summary.startedAt,
                lastActivityAt: max(modified ?? summary.startedAt, summary.startedAt),
                accountID: source.accountID,
                sourceName: source.name
            ))
        }
        return sessions
    }

    // MARK: - Reading

    /// The first `count` bytes of a file.
    static func head(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    /// The last `count` bytes of a file, or nil when the head already covers it.
    static func tail(of url: URL, count: Int, after headCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(headCount) else { return nil }
        let start = max(UInt64(headCount), size > UInt64(count) ? size - UInt64(count) : 0)
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    /// JSON objects, one per line. A line cut by a bounded read fails to
    /// parse and is skipped, which is all a cut line deserves.
    static func objects(in data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    /// What a user turn is, for naming a session after it.
    enum Prompt: Equatable {
        /// Something the user typed.
        case typed(String)
        /// A block the user pasted, without its wrapper — a fallback name, as
        /// the first line of a paste says less than a typed sentence does.
        case pasted(String)
        /// Filed as a user turn without anyone writing it: slash-command
        /// echoes, `<local-command-…>` caveats, injected instructions and
        /// environment blocks, which all open with a tag.
        case ignored
    }

    static func classify(_ text: String) -> Prompt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<pasted_content") {
            let inner = trimmed
                .replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? .ignored : .pasted(inner)
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md") else {
            return .ignored
        }
        return .typed(trimmed)
    }

    /// Whether a prompt is one Uncoil Auto wrote for a role it ran. Those
    /// conversations are Uncoil's own working papers, not sessions anybody
    /// had. Recognised by the handoff block every role prompt carries — the
    /// instructions around it are the user's to rewrite, the block is not.
    static func isUncoilRun(_ text: String) -> Bool {
        text.contains("```" + AutoHandoff.fence)
    }
}

private extension SessionImportPlacement {
    var worktreePath: String? {
        if case .worktree(let path) = self { return path }
        return nil
    }
}

// MARK: - Claude transcript

/// What one Claude Code transcript says about itself.
struct ClaudeTranscriptSummary: Equatable {
    let firstPrompt: String
    let sessionID: String
    let cwd: String
    let title: String
    let startedAt: Date
    let lastTimestamp: Date

    /// Reads the head and tail of a transcript.
    ///
    /// The title is, in order: one the user gave (`custom-title`), the one
    /// Claude generated (`ai-title`), the first prompt. A transcript with no
    /// prompt at all — opened and closed, or only ever `/clear`ed — is not a
    /// conversation and is skipped, as is a sub-agent's sidechain.
    static func read(at url: URL) -> ClaudeTranscriptSummary? {
        guard let head = SessionImportScanner.head(of: url, count: SessionImportScanner.headBytes)
        else { return nil }
        let tail = SessionImportScanner.tail(
            of: url, count: SessionImportScanner.tailBytes, after: head.count
        )
        return summarize(
            head: SessionImportScanner.objects(in: head),
            tail: tail.map(SessionImportScanner.objects(in:)) ?? [],
            fallbackID: url.deletingPathExtension().lastPathComponent
        )
    }

    static func summarize(
        head: [[String: Any]],
        tail: [[String: Any]],
        fallbackID: String
    ) -> ClaudeTranscriptSummary? {
        var sessionID: String?
        var cwd: String?
        var startedAt: Date?
        var typed: String?
        var pasted: String?
        var sawPrompt = false
        for object in head {
            if object["isSidechain"] as? Bool == true { return nil }
            sessionID = sessionID ?? object["sessionId"] as? String
            cwd = cwd ?? object["cwd"] as? String
            if let stamp = (object["timestamp"] as? String).flatMap(CodexSessionLocator.parseTimestamp) {
                startedAt = min(startedAt ?? stamp, stamp)
            }
            guard typed == nil,
                  object["type"] as? String == "user",
                  object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let content = text(of: message["content"])
            else { continue }
            switch SessionImportScanner.classify(content) {
            case .typed(let text):
                if !sawPrompt, SessionImportScanner.isUncoilRun(text) { return nil }
                sawPrompt = true
                typed = text
            case .pasted(let text):
                if !sawPrompt, SessionImportScanner.isUncoilRun(text) { return nil }
                sawPrompt = true
                pasted = pasted ?? text
            case .ignored:
                continue
            }
        }
        guard let cwd, let startedAt, let firstPrompt = typed ?? pasted else { return nil }

        // Latest wins, and a title the user set outranks a generated one
        // wherever each was written.
        var customTitle: String?
        var aiTitle: String?
        var lastTimestamp = startedAt
        for object in head + tail {
            switch object["type"] as? String {
            case "custom-title": customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            default: break
            }
            if let stamp = (object["timestamp"] as? String).flatMap(CodexSessionLocator.parseTimestamp) {
                lastTimestamp = max(lastTimestamp, stamp)
            }
        }
        let title = [customTitle, aiTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? SessionAutoTitle.candidate(from: firstPrompt)
            ?? firstPrompt
        return ClaudeTranscriptSummary(
            firstPrompt: firstPrompt,
            sessionID: sessionID ?? fallbackID,
            cwd: cwd,
            title: title,
            startedAt: startedAt,
            lastTimestamp: lastTimestamp
        )
    }

    /// A message's text: a plain string, or the text blocks of a block list.
    /// A turn that is only tool results has none.
    private static func text(of content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

// MARK: - Codex rollout

/// What one Codex rollout says about itself.
struct CodexRolloutSummary: Equatable {
    let threadID: String
    let cwd: String
    let startedAt: Date
    let firstPrompt: String?

    static func read(at url: URL) -> CodexRolloutSummary? {
        guard let head = SessionImportScanner.head(of: url, count: SessionImportScanner.headBytes)
        else { return nil }
        return summarize(SessionImportScanner.objects(in: head))
    }

    /// A thread someone started: Codex also writes rollouts for the reviewers
    /// and sub-agents it spawns, and those say so in `thread_source`.
    static func summarize(_ objects: [[String: Any]]) -> CodexRolloutSummary? {
        guard let meta = objects.first(where: { $0["type"] as? String == "session_meta" }),
              let payload = meta["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String,
              let startedAt = (payload["timestamp"] as? String).flatMap(CodexSessionLocator.parseTimestamp)
        else { return nil }
        if let origin = payload["thread_source"] as? String, origin != "user" { return nil }

        var typed: String?
        var pasted: String?
        var sawPrompt = false
        for object in objects where typed == nil {
            guard object["type"] as? String == "response_item",
                  let item = object["payload"] as? [String: Any],
                  item["type"] as? String == "message",
                  item["role"] as? String == "user",
                  let content = item["content"] as? [[String: Any]]
            else { continue }
            for text in content.compactMap({ $0["text"] as? String }) {
                switch SessionImportScanner.classify(text) {
                case .typed(let text):
                    if !sawPrompt, SessionImportScanner.isUncoilRun(text) { return nil }
                    sawPrompt = true
                    typed = typed ?? text
                case .pasted(let text):
                    if !sawPrompt, SessionImportScanner.isUncoilRun(text) { return nil }
                    sawPrompt = true
                    pasted = pasted ?? text
                case .ignored:
                    continue
                }
            }
        }
        guard let firstPrompt = typed ?? pasted else { return nil }
        return CodexRolloutSummary(
            threadID: id,
            cwd: cwd,
            startedAt: startedAt,
            firstPrompt: SessionAutoTitle.candidate(from: firstPrompt) ?? firstPrompt
        )
    }

    /// Thread names from `session_index.jsonl`, latest entry per thread.
    static func threadNames(codexHome: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("session_index.jsonl"))
        else { return [:] }
        var names: [String: String] = [:]
        for object in SessionImportScanner.objects(in: data) {
            guard let id = object["id"] as? String,
                  let name = (object["thread_name"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            names[id] = name
        }
        return names
    }
}

extension SessionImportSource {
    /// Every store worth reading: each provider's own home, then each account
    /// profile with an isolated config root. The home comes first so that a
    /// conversation found in both is attributed to it.
    @MainActor
    static func all(settings: SettingsStore) -> [SessionImportSource] {
        var sources: [SessionImportSource] = []
        for provider in [AgentProvider.claude, .codex] {
            let home = provider == .claude
                ? ClaudeSessionStore.defaultConfigDirectory()
                : CodexSessionStore.defaultHome()
            let profiles = settings.accounts(for: provider)
            sources.append(SessionImportSource(
                provider: provider,
                root: home,
                // The profile standing for the provider's own home, if there
                // is one, so an imported session runs under the login it had.
                accountID: profiles.first { $0.directoryName == nil }?.id,
                name: "~/\(home.lastPathComponent)"
            ))
            for profile in profiles {
                guard let root = profile.configDirectory(profilesRoot: settings.profilesRootURL)
                else { continue }
                sources.append(SessionImportSource(
                    provider: provider, root: root, accountID: profile.id, name: profile.name
                ))
            }
        }
        return sources
    }
}
