import SwiftUI

/// What kind of attention a single Attention Center row asks for.
enum AttentionKind: String, CaseIterable, Identifiable, Codable {
    case permission
    case input
    case testFailure
    case mergeConflict
    case authentication
    case runtime
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .permission: "İzin bekliyor"
        case .input: "Yanıt bekliyor"
        case .testFailure: "Test başarısız"
        case .mergeConflict: "Merge conflict"
        case .authentication: "Giriş gerekli"
        case .runtime: "Runtime sorunu"
        case .completed: "Tamamlandı"
        }
    }

    var iconName: String {
        switch self {
        case .permission: "shield-lock"
        case .input: "message-question"
        case .testFailure: "flask-off"
        case .mergeConflict: "git-merge"
        case .authentication: "user-exclamation"
        case .runtime: "plug-off"
        case .completed: "circle-check"
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .permission: Theme.claude
        case .input: Theme.warn
        case .testFailure, .runtime: Theme.danger
        case .mergeConflict: Theme.warn
        case .authentication: Theme.warn
        case .completed: Theme.codex
        }
    }

    /// Higher sorts first in the panel and wins the menu-bar summary.
    var priority: Int {
        switch self {
        case .permission: 6
        case .runtime: 5
        case .mergeConflict: 4
        case .testFailure: 4
        case .authentication: 3
        case .input: 3
        case .completed: 1
        }
    }
}

struct AttentionItem: Identifiable, Equatable {
    let id: String
    let kind: AttentionKind
    let title: String
    let detail: String?
    let projectID: UUID?
    let sessionID: UUID?
    let createdAt: Date
    var isRead = false

    /// Derived items mirror live state and disappear on their own; reported
    /// items (test results) stay until the user resolves them.
    var isDerived = true
}

/// Everything the pure engine needs to derive the current attention list.
struct AttentionSnapshot {
    var sessions: [SessionRecord] = []
    var statuses: [UUID: AgentSessionStatus] = [:]
    var details: [UUID: String] = [:]
    var projectNames: [UUID: String] = [:]
    var codexAuthentication: [UUID: CodexAuthenticationState] = [:]
    var runtimePhase: RuntimeClient.Phase = .idle
    /// projectID → unresolved conflict paths.
    var conflicts: [UUID: [String]] = [:]
}

/// Derives attention rows from live app state. Pure and synchronous so the
/// whole surface is unit-testable without a running app.
enum AttentionEngine {
    static func permissionID(_ sessionID: UUID) -> String { "permission:\(sessionID.uuidString)" }
    static func inputID(_ sessionID: UUID) -> String { "input:\(sessionID.uuidString)" }
    static func completedID(_ sessionID: UUID) -> String { "completed:\(sessionID.uuidString)" }
    static func authenticationID(_ sessionID: UUID) -> String { "auth:\(sessionID.uuidString)" }
    static func conflictID(_ projectID: UUID) -> String { "conflict:\(projectID.uuidString)" }
    static let runtimeID = "runtime"

    static func items(_ snapshot: AttentionSnapshot, now: Date = .now) -> [AttentionItem] {
        var items: [AttentionItem] = []

        for session in snapshot.sessions {
            let project = snapshot.projectNames[session.projectID]
            let where_ = project.map { "\($0) › \(session.displayTitle)" } ?? session.displayTitle
            let detail = snapshot.details[session.id]

            switch snapshot.statuses[session.id] {
            case .waitingForPermission:
                items.append(AttentionItem(
                    id: permissionID(session.id), kind: .permission, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .waitingForInput:
                items.append(AttentionItem(
                    id: inputID(session.id), kind: .input, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .completed:
                items.append(AttentionItem(
                    id: completedID(session.id), kind: .completed, title: where_,
                    detail: detail, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            default:
                break
            }

            // Provider/MCP authentication: the agent cannot work until the
            // user finishes a login flow the CLI owns.
            switch snapshot.codexAuthentication[session.id] {
            case .required:
                items.append(AttentionItem(
                    id: authenticationID(session.id), kind: .authentication, title: where_,
                    detail: "Codex hesabında oturum açılmalı.",
                    projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .error(let message):
                items.append(AttentionItem(
                    id: authenticationID(session.id), kind: .authentication, title: where_,
                    detail: message, projectID: session.projectID, sessionID: session.id,
                    createdAt: session.lastActivityAt
                ))
            case .authenticated, .unknown, nil:
                break
            }
        }

        for (projectID, paths) in snapshot.conflicts where !paths.isEmpty {
            let name = snapshot.projectNames[projectID] ?? "Proje"
            items.append(AttentionItem(
                id: conflictID(projectID), kind: .mergeConflict, title: name,
                detail: conflictDetail(paths), projectID: projectID, sessionID: nil,
                createdAt: now
            ))
        }

        switch snapshot.runtimePhase {
        case .failed:
            items.append(AttentionItem(
                id: runtimeID, kind: .runtime, title: "Runtime daemon",
                detail: "uncoil-runtimed erişilemiyor; oturumlar uygulama içi PTY ile çalışıyor.",
                projectID: nil, sessionID: nil, createdAt: now
            ))
        case .incompatible(let message):
            items.append(AttentionItem(
                id: runtimeID, kind: .runtime, title: "Runtime uyumsuzluğu",
                detail: message, projectID: nil, sessionID: nil, createdAt: now
            ))
        case .idle, .connecting, .ready:
            break
        }

        return items
    }

    static func conflictDetail(_ paths: [String]) -> String {
        let shown = paths.prefix(3).joined(separator: ", ")
        return paths.count > 3
            ? "\(paths.count) dosyada çözülmemiş conflict: \(shown)…"
            : "Çözülmemiş conflict: \(shown)"
    }

    /// Panel order: urgency first, then most recent.
    static func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted {
            $0.kind.priority != $1.kind.priority
                ? $0.kind.priority > $1.kind.priority
                : $0.createdAt > $1.createdAt
        }
    }
}

/// Observable Attention Center state: derived rows refreshed from live state,
/// plus reported rows (failing tests) that stick until resolved. Read and
/// resolved marks are keyed by item id, so a row that comes back after the
/// condition cleared is unread again.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var items: [AttentionItem] = []

    private var readIDs: Set<String> = []
    private var resolvedIDs: Set<String> = []
    private var reported: [AttentionItem] = []

    var unreadCount: Int { items.filter { !$0.isRead }.count }

    func count(of kind: AttentionKind) -> Int {
        items.filter { $0.kind == kind }.count
    }

    /// Recomputes derived rows and merges them with reported ones.
    func refresh(_ snapshot: AttentionSnapshot, now: Date = .now) {
        let derived = AttentionEngine.items(snapshot, now: now)
        // A resolved condition that cleared may fire again — forget its marks
        // so the next occurrence shows up unread.
        let liveIDs = Set(derived.map(\.id)).union(reported.map(\.id))
        resolvedIDs.formIntersection(liveIDs)
        readIDs.formIntersection(liveIDs)

        items = AttentionEngine.sorted(derived + reported)
            .filter { !resolvedIDs.contains($0.id) }
            .map {
                var item = $0
                item.isRead = readIDs.contains($0.id)
                return item
            }
    }

    /// Records an item that no live state can re-derive (a failing test run).
    func report(
        kind: AttentionKind,
        title: String,
        detail: String?,
        projectID: UUID?,
        sessionID: UUID?,
        id: String? = nil,
        now: Date = .now
    ) {
        let itemID = id ?? "\(kind.rawValue):\(sessionID?.uuidString ?? "-"):\(title)"
        let item = AttentionItem(
            id: itemID, kind: kind, title: title, detail: detail,
            projectID: projectID, sessionID: sessionID, createdAt: now,
            isDerived: false
        )
        reported.removeAll { $0.id == itemID }
        reported.append(item)
        // Re-reporting is a fresh event: clear both marks.
        readIDs.remove(itemID)
        resolvedIDs.remove(itemID)
        if reported.count > 100 { reported.removeFirst(reported.count - 100) }
        items = AttentionEngine.sorted(items.filter { $0.id != itemID } + [item])
    }

    func markRead(_ id: String) {
        readIDs.insert(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = true
    }

    func markAllRead() {
        readIDs.formUnion(items.map(\.id))
        for index in items.indices { items[index].isRead = true }
    }

    /// Marks a row handled: it leaves the list until the condition recurs.
    func resolve(_ id: String) {
        resolvedIDs.insert(id)
        reported.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
    }

    func resolveAll() {
        resolvedIDs.formUnion(items.map(\.id))
        reported.removeAll()
        items.removeAll()
    }
}

/// Bridges the live stores to `AttentionStore`: builds snapshots on demand and
/// keeps a cached merge-conflict scan (git is too slow to run inline).
@MainActor
final class AttentionRefresher {
    static let shared = AttentionRefresher()

    private var conflicts: [UUID: [String]] = [:]
    private var scanning = false

    func refresh(projectStore: ProjectStore, sessionStore: SessionStore) {
        AttentionStore.shared.refresh(
            snapshot(projectStore: projectStore, sessionStore: sessionStore)
        )
    }

    func snapshot(projectStore: ProjectStore, sessionStore: SessionStore) -> AttentionSnapshot {
        var snapshot = AttentionSnapshot()
        snapshot.sessions = projectStore.sessions
        snapshot.statuses = sessionStore.statuses
        snapshot.details = sessionStore.details
        snapshot.codexAuthentication = sessionStore.codexAuthentication
        snapshot.projectNames = Dictionary(
            projectStore.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        snapshot.runtimePhase = RuntimeClient.shared.phase
        snapshot.conflicts = conflicts
        return snapshot
    }

    /// Rescans every project (and its session worktrees) for unresolved
    /// conflicts off the main thread, then refreshes the store.
    func scanConflicts(projectStore: ProjectStore, sessionStore: SessionStore) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        var roots: [UUID: Set<String>] = [:]
        for project in projectStore.projects {
            roots[project.id, default: []].insert(project.rootPath)
        }
        for session in projectStore.sessions {
            guard let worktree = session.worktreePath else { continue }
            roots[session.projectID, default: []].insert(worktree)
        }

        let scanned = await Task.detached(priority: .utility) {
            roots.mapValues { paths in
                Array(Set(paths.flatMap { path in
                    GitService.conflictedFiles(repoPath: path)
                })).sorted()
            }
        }.value

        conflicts = scanned.filter { !$0.value.isEmpty }
        refresh(projectStore: projectStore, sessionStore: sessionStore)
    }
}
