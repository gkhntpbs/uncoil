import Foundation
import SwiftUI

// MARK: - Actions

/// A resolved thing the palette can do. Pure data so the model stays testable;
/// `MainWindow` performs the side effects (routing, window opening, launches).
enum PaletteAction: Equatable {
    case addProject
    case createTestWorkspace
    case createDebugBundle
    case openExtensions
    case openProject(UUID)
    case focusSession(UUID)
    case newSession(UUID, AgentProvider)
    case createWorktree(UUID)
    case openSettings(String?)          // settings pane rawValue, nil = default
    case restartSession(UUID)
    case closeSession(UUID)
    case popoutSession(UUID)
    case openFile(URL)
    case openArtifact(URL)
    case ask(prompt: String, target: AskTarget, projectID: UUID)
    /// Puts the palette into asking mode without closing it.
    case beginAsk
    /// Appends a task to a project's TODO.md without opening anything.
    case captureTask(text: String, projectID: UUID, sourcePath: String, heading: [String])
}

/// Where a quick question goes.
///
/// An existing session keeps the conversation — the agent already knows what
/// the project looks like — while a new one is the "start this as its own
/// thread" answer. Both are one Enter away, which is the whole point of asking
/// from the palette.
enum AskTarget: Equatable {
    case session(UUID)
    case newSession(AgentProvider)
}

// MARK: - Result model

enum PaletteGroupKind: Int, CaseIterable {
    case ask
    case capture
    case command
    case project
    case session
    case file
    case artifact
    case settings

    var title: String {
        switch self {
        case .ask: String(localized: "Quick Question")
        case .capture: String(localized: "Capture a Task")
        case .command: String(localized: "Commands")
        case .project: String(localized: "Projects")
        case .session: String(localized: "Sessions")
        case .file: String(localized: "Files")
        case .artifact: String(localized: "Artifacts")
        case .settings: String(localized: "Settings")
        }
    }
}

struct PaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    var subtitle: String?
    var iconName: String
    /// When set, the row renders the provider's mark instead of `iconName`.
    var provider: AgentProvider?
    /// When set, the row shows a trailing status orb.
    var status: AgentSessionStatus?
    let kind: PaletteGroupKind
    let action: PaletteAction
    /// Attention/priority boost used to break score ties (higher = earlier).
    var rank: Int = 0

    static func == (lhs: PaletteItem, rhs: PaletteItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct PaletteGroup: Identifiable {
    let kind: PaletteGroupKind
    let items: [PaletteItem]
    var id: Int { kind.rawValue }
    var title: String { kind.title }
}

// MARK: - Engine (pure)

/// Everything the engine needs to produce results, as plain values.
struct PaletteContext {
    var query: String
    var projects: [Project]
    var sessions: [SessionRecord]
    var statuses: [UUID: AgentSessionStatus]
    var currentProjectID: UUID?
    var currentSessionID: UUID?
    var files: [URL]
    var artifacts: [URL]
    var projectRoot: String?
    var settingsPanes: [(id: String, title: String)]
    /// Where a captured task may be filed. Empty when the project has no task
    /// file, which is what makes capture silently unavailable rather than
    /// offering to write somewhere that does not exist.
    var captureTargets: [PaletteCaptureTarget] = []
}

/// One place a captured task can land: a heading inside a task file.
struct PaletteCaptureTarget: Equatable {
    var sourcePath: String
    /// Relative to the project root, for display.
    var displayPath: String
    var heading: [String]
    /// Higher sorts first. The root file's first heading is the obvious
    /// destination and should not have to be hunted for.
    var rank: Int = 0
}

/// Pure result computation — no stores, no view state. Unit-tested directly.
enum PaletteEngine {
    /// The question inside a palette query, or nil when this is not one.
    ///
    /// A leading `?` is the deliberate way in, so a question can be typed
    /// before it is finished. A trailing `?` also counts, because that is how
    /// people type a question without thinking about the palette's rules.
    static func askPrompt(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(">") else { return nil }
        for prefix in ["?", "soru:", "ask:"] where trimmed.lowercased().hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? "" : body
        }
        if trimmed.hasSuffix("?"), trimmed.count > 1 { return trimmed }
        return nil
    }

    /// The task inside a palette query, or nil when this is not one.
    ///
    /// A leading `+` is the way in. Deliberately not a word: capturing is meant
    /// to cost one keystroke more than the thought did, and every prefix that
    /// reads as English collides with something someone might search for.
    static func capturePrompt(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(">") else { return nil }
        for prefix in ["+", "todo:", "task:"] where trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Where a captured task can go: one entry per heading of every task file
    /// the project has.
    ///
    /// Headings rather than files alone, because "which file" is rarely the
    /// question — a TODO.md with `## Next` and `## Later` is a decision about
    /// *when*, and that is exactly what someone capturing a thought wants to
    /// say in the same keystroke.
    static func captureItems(raw: String, ctx: PaletteContext) -> [PaletteItem] {
        guard let pid = ctx.currentProjectID,
              let text = capturePrompt(in: raw), !text.isEmpty else { return [] }
        var items: [PaletteItem] = []
        for target in ctx.captureTargets {
            let heading = target.heading.joined(separator: " › ")
            items.append(PaletteItem(
                id: "capture.\(target.sourcePath).\(heading)",
                title: heading.isEmpty ? target.displayPath : heading,
                subtitle: heading.isEmpty
                    ? String(localized: "Add to this file")
                    : target.displayPath,
                iconName: "plus",
                kind: .capture,
                action: .captureTask(
                    text: text, projectID: pid,
                    sourcePath: target.sourcePath, heading: target.heading
                ),
                rank: target.rank))
        }
        return items
    }

    private static let perGroupLimit = 20
    private static let fileLimit = 30

    static func compute(_ ctx: PaletteContext) -> [PaletteGroup] {
        let raw = ctx.query.trimmingCharacters(in: .whitespaces)
        let commandsOnly = raw.hasPrefix(">")
        let query = commandsOnly ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
        let isEmpty = query.isEmpty

        var groups: [PaletteGroup] = []

        // A question takes the palette over: mixing "which agent do I ask" with
        // file and project results would make Enter ambiguous, and the whole
        // flow is meant to be answerable without looking.
        let asks = askItems(raw: raw, ctx: ctx)
        if !asks.isEmpty {
            return [PaletteGroup(kind: .ask, items: asks)]
        }
        // Capturing takes the palette over for the same reason asking does:
        // Enter has to mean one thing, and here it means "file this".
        let captures = captureItems(raw: raw, ctx: ctx)
        if !captures.isEmpty {
            return [PaletteGroup(kind: .capture, items: captures)]
        }
        if !commandsOnly, askPrompt(in: raw) != nil, ctx.currentProjectID == nil {
            return []
        }

        // Commands
        let commands = commandItems(ctx: ctx)
        groups.append(contentsOf: grouped(.command, commands, query: query, isEmpty: isEmpty))

        if !commandsOnly {
            // Projects
            let projects = ctx.projects.map { project in
                PaletteItem(
                    id: "project.\(project.id)", title: project.name,
                    subtitle: shortPath(project.rootPath), iconName: project.iconName ?? "folder",
                    kind: .project, action: .openProject(project.id))
            }
            groups.append(contentsOf: grouped(.project, projects, query: query, isEmpty: isEmpty))

            // Sessions — running/attention ranked higher.
            let sessions = ctx.sessions.map { record -> PaletteItem in
                let status = ctx.statuses[record.id] ?? .terminated
                let projectName = ctx.projects.first { $0.id == record.projectID }?.name
                return PaletteItem(
                    id: "session.\(record.id)", title: record.displayTitle,
                    subtitle: [record.provider.displayName, projectName, status.label]
                        .compactMap { $0 }.joined(separator: " · "),
                    iconName: "message", provider: record.provider, status: status,
                    kind: .session, action: .focusSession(record.id),
                    rank: status.attentionPriority)
            }
            groups.append(contentsOf: grouped(.session, sessions, query: query, isEmpty: isEmpty))

            // Files (only when searching — the index is large).
            if !isEmpty {
                let root = ctx.projectRoot
                let files = ctx.files.map { url -> PaletteItem in
                    let rel = relativePath(url, root: root)
                    return PaletteItem(
                        id: "file.\(url.path)", title: url.lastPathComponent,
                        subtitle: rel, iconName: "file", kind: .file,
                        action: .openFile(url))
                }
                groups.append(contentsOf: grouped(.file, files, query: query,
                                                  isEmpty: false, limit: fileLimit,
                                                  matchSubtitle: true))

                let artifacts = ctx.artifacts.map { url -> PaletteItem in
                    PaletteItem(
                        id: "artifact.\(url.path)", title: url.lastPathComponent,
                        subtitle: url.deletingLastPathComponent().lastPathComponent,
                        iconName: "file-text", kind: .artifact,
                        action: .openArtifact(url))
                }
                groups.append(contentsOf: grouped(.artifact, artifacts, query: query, isEmpty: false))
            }
        }

        // Settings panes (direct jumps) only surface when the user is actually
        // searching, so an empty palette isn't flooded with every pane.
        if !isEmpty {
            let panes = ctx.settingsPanes.map { pane in
                PaletteItem(
                    id: "settings.\(pane.id)", title: String(localized: "Settings: \(pane.title)"),
                    iconName: "settings", kind: .settings,
                    action: .openSettings(pane.id))
            }
            groups.append(contentsOf: grouped(.settings, panes, query: query, isEmpty: false))
        }

        return groups.filter { !$0.items.isEmpty }
    }

    // MARK: Helpers

    /// Boost for commands aimed at the project the user is currently in. Below
    /// `Ask an agent…` at 30, which is about the session in front of them and
    /// so is nearer still, and above everything with no project at all.
    static let currentProjectRank = 20

    private static func commandItems(ctx: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if ctx.currentProjectID != nil {
            items.append(PaletteItem(
                id: "cmd.ask", title: String(localized: "Ask an agent…"),
                subtitle: String(localized: "Type ? and your question"),
                iconName: "sparkles", kind: .command, action: .beginAsk, rank: 30))
        }
        items += [
            PaletteItem(id: "cmd.addProject", title: String(localized: "Add a New Project"),
                        iconName: "folder-plus", kind: .command, action: .addProject),
            PaletteItem(id: "cmd.testWorkspace", title: String(localized: "Create a Test Workspace"),
                        iconName: "flask", kind: .command, action: .createTestWorkspace),
            PaletteItem(id: "cmd.debugBundle", title: String(localized: "Create Debug Bundle"),
                        iconName: "package-export", kind: .command, action: .createDebugBundle),
            PaletteItem(id: "cmd.extensions", title: String(localized: "Extensions"),
                        iconName: "puzzle", kind: .command, action: .openExtensions),
            PaletteItem(id: "cmd.settings", title: String(localized: "Settings"),
                        iconName: "settings", kind: .command, action: .openSettings(nil)),
        ]

        // Every project offers the same commands, so with more than a couple
        // open the one you are looking at was buried among the rest in store
        // order — and "new terminal" meant scrolling past four other projects
        // to reach the obvious answer. Rank puts the current project first,
        // both in the empty palette and as the tie-break when several match a
        // query equally.
        for project in ctx.projects {
            let rank = project.id == ctx.currentProjectID ? currentProjectRank : 0
            for provider in AgentProvider.sessionKinds {
                items.append(PaletteItem(
                    id: "cmd.new.\(provider.rawValue).\(project.id)",
                    title: String(localized: "New Session: \(provider.displayName) [\(project.name)]"),
                    iconName: "plus", provider: provider,
                    kind: .command, action: .newSession(project.id, provider),
                    rank: rank))
            }
            items.append(PaletteItem(
                id: "cmd.worktree.\(project.id)",
                title: String(localized: "Create Worktree… [\(project.name)]"),
                iconName: "git-branch", kind: .command,
                action: .createWorktree(project.id),
                rank: rank))
        }

        if let sid = ctx.currentSessionID {
            items.append(PaletteItem(id: "cmd.restart", title: String(localized: "Restart the Session"),
                                     iconName: "refresh", kind: .command,
                                     action: .restartSession(sid)))
            items.append(PaletteItem(id: "cmd.close", title: String(localized: "Close the Session"),
                                     iconName: "x", kind: .command,
                                     action: .closeSession(sid)))
            items.append(PaletteItem(id: "cmd.popout", title: String(localized: "Open in a Popout Window"),
                                     iconName: "external-link", kind: .command,
                                     action: .popoutSession(sid)))
        }
        return items
    }

    /// The targets a question can go to, in the order a keyboard reaches them:
    /// the project's live agents first (most recently active first), then a
    /// fresh session per provider.
    static func askItems(raw: String, ctx: PaletteContext) -> [PaletteItem] {
        guard let pid = ctx.currentProjectID,
              let prompt = askPrompt(in: raw), !prompt.isEmpty else { return [] }

        var items: [PaletteItem] = []
        let live = ctx.sessions
            .filter {
                $0.projectID == pid && $0.provider != .terminal && $0.endedAt == nil
                    && ctx.statuses[$0.id] != .terminated
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }

        for session in live {
            items.append(PaletteItem(
                id: "ask.session.\(session.id)",
                title: session.displayTitle,
                subtitle: String(localized: "Ask in this session"),
                iconName: "message", provider: session.provider,
                status: ctx.statuses[session.id],
                kind: .ask, action: .ask(prompt: prompt, target: .session(session.id), projectID: pid),
                rank: 10))
        }

        for provider in AgentProvider.agents {
            items.append(PaletteItem(
                id: "ask.new.\(provider.rawValue)",
                title: String(localized: "New \(provider.displayName) session"),
                subtitle: String(localized: "Ask in a session of its own"),
                iconName: "plus", provider: provider,
                kind: .ask,
                action: .ask(prompt: prompt, target: .newSession(provider), projectID: pid)))
        }
        return items
    }

    /// Scores/sorts a candidate list into (at most one) group.
    private static func grouped(
        _ kind: PaletteGroupKind, _ candidates: [PaletteItem],
        query: String, isEmpty: Bool, limit: Int = perGroupLimit,
        matchSubtitle: Bool = false
    ) -> [PaletteGroup] {
        guard !candidates.isEmpty else { return [] }

        if isEmpty {
            let items = Array(candidates
                .sorted { $0.rank > $1.rank }
                .prefix(limit))
            return items.isEmpty ? [] : [PaletteGroup(kind: kind, items: items)]
        }

        let scored: [(item: PaletteItem, score: Int)] = candidates.compactMap { item in
            var best = FuzzyScore.score(query: query, candidate: item.title)
            if matchSubtitle, let sub = item.subtitle,
               let subScore = FuzzyScore.score(query: query, candidate: sub) {
                best = max(best ?? Int.min, subScore)
            }
            guard let score = best, score != Int.min else { return nil }
            return (item, score)
        }
        let items = scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.item.rank != $1.item.rank { return $0.item.rank > $1.item.rank }
                return $0.item.title.count < $1.item.title.count
            }
            .prefix(limit)
            .map(\.item)
        return items.isEmpty ? [] : [PaletteGroup(kind: kind, items: Array(items))]
    }

    private static func relativePath(_ url: URL, root: String?) -> String {
        guard let root, url.path.hasPrefix(root) else { return url.path }
        return String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    private static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - File indexer (pure, filesystem)

/// Walks a project root collecting file URLs, skipping VCS/build/dep dirs and
/// hidden directories, capped so a huge tree never stalls the palette.
enum FileIndexer {
    static let cap = 5000
    static let skippedDirNames: Set<String> = [
        ".git", "node_modules", ".uncoil-worktrees",
    ]

    static func shouldSkipDir(_ name: String) -> Bool {
        if skippedDirNames.contains(name) { return true }
        if name.hasPrefix(".build") { return true }
        if name.hasPrefix(".") { return true }     // hidden dirs
        return false
    }

    static func index(root: URL, cap: Int = cap) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if shouldSkipDir(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.lastPathComponent.hasPrefix(".") { continue }
            results.append(url)
            if results.count >= cap { break }
        }
        return results
    }
}

// MARK: - Palette model

@MainActor
final class PaletteModel: ObservableObject {
    @Published var isOpen = false
    @Published var query = "" {
        didSet { if isOpen { scheduleRecompute() } }
    }
    @Published private(set) var groups: [PaletteGroup] = []
    @Published var selectedIndex = 0
    /// Set when the user runs an item; observed by MainWindow to perform it.
    @Published var pendingAction: PaletteAction?

    private weak var projectStore: ProjectStore?
    private weak var sessionStore: SessionStore?
    private var settingsPanes: [(id: String, title: String)] = []

    var currentProjectID: UUID?
    var currentSessionID: UUID?

    private var files: [URL] = []
    private var artifacts: [URL] = []
    private var indexedRoot: String?
    private var recomputeTask: Task<Void, Never>?
    private var dataDirectory: URL = ProjectStore.defaultDirectory()

    func configure(
        projectStore: ProjectStore,
        sessionStore: SessionStore,
        settingsPanes: [(id: String, title: String)],
        dataDirectory: URL = ProjectStore.defaultDirectory()
    ) {
        self.projectStore = projectStore
        self.sessionStore = sessionStore
        self.settingsPanes = settingsPanes
        self.dataDirectory = dataDirectory
    }

    var flatItems: [PaletteItem] { groups.flatMap(\.items) }

    var selectedItem: PaletteItem? {
        let items = flatItems
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        isOpen = true
        selectedIndex = 0
        recomputeNow()
        refreshIndex()
    }

    func close() {
        isOpen = false
        recomputeTask?.cancel()
        query = ""
        groups = []
        selectedIndex = 0
        // The index is thousands of URLs; `open()` rebuilds it anyway, so
        // holding it between palette uses is pure resident memory.
        files = []
        artifacts = []
        indexedRoot = nil
    }

    func move(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    func executeSelected() {
        guard let item = selectedItem else { return }
        execute(item)
    }

    func execute(_ item: PaletteItem) {
        // Asking is the one action that keeps the palette open: it only sets up
        // the question, and the next Enter is the one that sends it.
        if case .beginAsk = item.action {
            query = "? "
            selectedIndex = 0
            return
        }
        close()
        pendingAction = item.action
    }

    /// The project a question would go to, named for the ask banner.
    var askProjectName: String? {
        guard let id = currentProjectID else { return nil }
        return projectStore?.projects.first(where: { $0.id == id })?.name
    }

    /// The question currently typed, for the header the ask mode shows.
    var askPrompt: String? { PaletteEngine.askPrompt(in: query) }

    // MARK: Recompute

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.recomputeNow()
        }
    }

    /// Builds a context snapshot from the live stores and recomputes results.
    /// Where a captured task could go, from the task stores the app already
    /// keeps for the current project.
    ///
    /// Read on demand rather than cached: the palette recomputes on every
    /// keystroke, but these come from documents already parsed and held in
    /// memory, so there is nothing to save by caching and a cache would go
    /// stale the moment an agent edited the file.
    private var captureTargets: [PaletteCaptureTarget] {
        guard let projectID = currentProjectID,
              let root = currentProjectRoot else { return [] }
        let sources = ProjectTaskStores.sources(projectID: projectID, projectRoot: root)
        var targets: [PaletteCaptureTarget] = []
        for source in sources.sources {
            guard let document = sources.document(for: source.path) else { continue }
            // A jump from h1 to h3 leaves a short stack; the chain is whatever
            // the file actually nests, not an invented level.
            var stack: [String] = []
            var chains: [[String]] = []
            for heading in document.headings {
                while stack.count >= heading.level { stack.removeLast() }
                stack.append(heading.text)
                chains.append(stack)
            }
            // A document's single top title is its name, not a place to file
            // things under; deeper headings are real destinations.
            let destinations = chains.filter { $0.count > 1 }
            for (index, chain) in destinations.enumerated() {
                targets.append(PaletteCaptureTarget(
                    sourcePath: source.path,
                    displayPath: source.displayPath,
                    heading: chain,
                    // The root file's first heading is the obvious destination.
                    rank: (source.isRoot ? 100 : 0) - index
                ))
            }
            if destinations.isEmpty {
                targets.append(PaletteCaptureTarget(
                    sourcePath: source.path,
                    displayPath: source.displayPath,
                    heading: [],
                    rank: source.isRoot ? 100 : 0
                ))
            }
        }
        return targets.sorted { $0.rank > $1.rank }
    }

    func recomputeNow() {
        guard let projectStore else { groups = []; return }
        let statuses = sessionStore?.statuses ?? [:]
        let ctx = PaletteContext(
            query: query,
            projects: projectStore.projects,
            sessions: projectStore.sessions,
            statuses: statuses,
            currentProjectID: currentProjectID,
            currentSessionID: currentSessionID,
            files: files,
            artifacts: artifacts,
            projectRoot: currentProjectRoot,
            settingsPanes: settingsPanes,
            captureTargets: captureTargets
        )
        groups = PaletteEngine.compute(ctx)
        let count = flatItems.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        }
    }

    private var currentProjectRoot: String? {
        guard let pid = currentProjectID else { return nil }
        return projectStore?.projects.first { $0.id == pid }?.rootPath
    }

    /// Rebuilds the file + artifact index off the main thread when the palette
    /// opens on a new project, then recomputes.
    private func refreshIndex() {
        guard let pid = currentProjectID,
              let root = currentProjectRoot else {
            files = []; artifacts = []; indexedRoot = nil
            return
        }
        let sessionIDs = projectStore?.sessions(for: pid).map(\.id) ?? []
        let dataDir = dataDirectory
        let artifactRoots = sessionIDs.map { sid in
            dataDir
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(pid.uuidString, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(sid.uuidString, isDirectory: true)
                .appendingPathComponent("artifacts", isDirectory: true)
        }
        let rootURL = URL(fileURLWithPath: root)
        indexedRoot = root

        Task.detached(priority: .userInitiated) { [weak self] in
            let indexed = FileIndexer.index(root: rootURL)
            var arts: [URL] = []
            let fm = FileManager.default
            for artRoot in artifactRoots {
                guard let items = try? fm.contentsOfDirectory(
                    at: artRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                arts.append(contentsOf: items.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                })
            }
            // Same cap the file index uses; a project with years of artifacts
            // should not pin an unbounded URL list.
            let cappedArts = Array(arts.prefix(FileIndexer.cap))
            await MainActor.run { [weak self] in
                guard let self, self.isOpen, self.indexedRoot == root else { return }
                self.files = indexed
                self.artifacts = cappedArts
                self.recomputeNow()
            }
        }
    }
}
