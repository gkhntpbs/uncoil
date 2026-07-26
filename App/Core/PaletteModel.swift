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
    case askClaude(String, UUID)        // prompt, project id
}

// MARK: - Result model

enum PaletteGroupKind: Int, CaseIterable {
    case ask
    case command
    case project
    case session
    case file
    case artifact
    case settings

    var title: String {
        switch self {
        case .ask: "Quick Question"
        case .command: "Komutlar"
        case .project: "Projeler"
        case .session: "Oturumlar"
        case .file: "Dosyalar"
        case .artifact: "Artefaktlar"
        case .settings: "Settings"
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
}

/// Pure result computation — no stores, no view state. Unit-tested directly.
enum PaletteEngine {
    private static let perGroupLimit = 20
    private static let fileLimit = 30

    static func compute(_ ctx: PaletteContext) -> [PaletteGroup] {
        let raw = ctx.query.trimmingCharacters(in: .whitespaces)
        let commandsOnly = raw.hasPrefix(">")
        let query = commandsOnly ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
        let isEmpty = query.isEmpty

        var groups: [PaletteGroup] = []

        // Ask-Claude action: query ends with "?" or starts with "soru:".
        if let ask = askItem(raw: raw, ctx: ctx), !commandsOnly {
            groups.append(PaletteGroup(kind: .ask, items: [ask]))
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
                    id: "settings.\(pane.id)", title: "Settings: \(pane.title)",
                    iconName: "settings", kind: .settings,
                    action: .openSettings(pane.id))
            }
            groups.append(contentsOf: grouped(.settings, panes, query: query, isEmpty: false))
        }

        return groups.filter { !$0.items.isEmpty }
    }

    // MARK: Helpers

    private static func commandItems(ctx: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "cmd.addProject", title: "Add a New Project",
                        iconName: "folder-plus", kind: .command, action: .addProject),
            PaletteItem(id: "cmd.testWorkspace", title: "Create a Test Workspace",
                        iconName: "flask", kind: .command, action: .createTestWorkspace),
            PaletteItem(id: "cmd.debugBundle", title: "Create Debug Bundle",
                        iconName: "package-export", kind: .command, action: .createDebugBundle),
            PaletteItem(id: "cmd.extensions", title: "Extensions",
                        iconName: "puzzle", kind: .command, action: .openExtensions),
            PaletteItem(id: "cmd.settings", title: "Settings",
                        iconName: "settings", kind: .command, action: .openSettings(nil)),
        ]

        for project in ctx.projects {
            for provider in [AgentProvider.claude, .codex, .terminal] {
                items.append(PaletteItem(
                    id: "cmd.new.\(provider.rawValue).\(project.id)",
                    title: "New Session: \(provider.displayName) [\(project.name)]",
                    iconName: "plus", provider: provider,
                    kind: .command, action: .newSession(project.id, provider)))
            }
            items.append(PaletteItem(
                id: "cmd.worktree.\(project.id)",
                title: "Create Worktree… [\(project.name)]",
                iconName: "git-branch", kind: .command,
                action: .createWorktree(project.id)))
        }

        if let sid = ctx.currentSessionID {
            items.append(PaletteItem(id: "cmd.restart", title: "Restart the Session",
                                     iconName: "refresh", kind: .command,
                                     action: .restartSession(sid)))
            items.append(PaletteItem(id: "cmd.close", title: "Close the Session",
                                     iconName: "x", kind: .command,
                                     action: .closeSession(sid)))
            items.append(PaletteItem(id: "cmd.popout", title: "Open in a Popout Window",
                                     iconName: "external-link", kind: .command,
                                     action: .popoutSession(sid)))
        }
        return items
    }

    private static func askItem(raw: String, ctx: PaletteContext) -> PaletteItem? {
        guard let pid = ctx.currentProjectID else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var prompt: String?
        if trimmed.lowercased().hasPrefix("soru:") {
            prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasSuffix("?") && trimmed.count > 1 {
            prompt = trimmed
        }
        guard let prompt, !prompt.isEmpty else { return nil }
        return PaletteItem(
            id: "ask.claude", title: "Claude'a sor: \(prompt)",
            subtitle: "Bu projede Claude oturumunda sorulur",
            iconName: "sparkles", provider: .claude,
            kind: .ask, action: .askClaude(prompt, pid))
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
    }

    func move(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    func executeSelected() {
        guard let item = selectedItem else { return }
        close()
        pendingAction = item.action
    }

    func execute(_ item: PaletteItem) {
        close()
        pendingAction = item.action
    }

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
            settingsPanes: settingsPanes
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
            await MainActor.run { [weak self] in
                guard let self, self.isOpen, self.indexedRoot == root else { return }
                self.files = indexed
                self.artifacts = arts
                self.recomputeNow()
            }
        }
    }
}
