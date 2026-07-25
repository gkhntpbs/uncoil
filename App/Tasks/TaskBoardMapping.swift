import Foundation

/// Turns a file's own Markdown headings into board columns.
///
/// The file is never reshaped to fit the board: headings are recognised, not
/// renamed, and a heading Uncoil does not recognise becomes its own column
/// rather than being forced into one. A manual mapping lives in Uncoil's
/// metadata, so a `TODO.md` never has to carry board vocabulary.
enum TaskBoardMapping {
    /// Board lanes a heading can be recognised as.
    enum Lane: String, Equatable, Codable, CaseIterable, Identifiable {
        case backlog
        case todo
        case inProgress
        case blocked
        case review
        case done
        /// A heading that matched nothing: shown as its own column.
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .backlog: "Backlog"
            case .todo: "Yapılacak"
            case .inProgress: "Devam Eden"
            case .blocked: "Engellendi"
            case .review: "İnceleme"
            case .done: "Tamamlandı"
            case .custom: "Diğer"
            }
        }

        var sortIndex: Int {
            switch self {
            case .backlog: 0
            case .todo: 1
            case .inProgress: 2
            case .blocked: 3
            case .review: 4
            case .done: 5
            case .custom: 6
            }
        }

        /// Execution states that belong in this lane when a task has one.
        var executionStates: [ProjectTaskExecutionState] {
            switch self {
            case .backlog, .todo: [.unassigned, .queued]
            case .inProgress: [.assigned, .agentStarting, .running]
            case .blocked: [.blocked, .failed, .testsFailing]
            case .review: [.reviewRequested, .waitingForUser, .waitingForPermission]
            case .done: [.completed]
            case .custom: ProjectTaskExecutionState.allCases
            }
        }
    }

    /// Heading names recognised without any configuration, per lane. Matching is
    /// case- and diacritic-insensitive and ignores leading numbering, so
    /// "## 2. In Progress" and "## devam eden" both land correctly.
    static let recognisedHeadings: [Lane: [String]] = [
        .backlog: ["backlog", "icebox", "buzdolabı", "beklemede"],
        .todo: ["todo", "to do", "planned", "yapılacak", "yapılacaklar", "planlanan"],
        .inProgress: [
            "in progress", "doing", "wip", "devam eden", "devam edenler",
            "üzerinde çalışılıyor", "çalışılıyor",
        ],
        .blocked: ["blocked", "engellendi", "engelli", "takıldı"],
        .review: ["review", "in review", "inceleme", "kontrol", "gözden geçir"],
        .done: ["done", "completed", "complete", "shipped", "tamamlandı", "bitenler", "bitti"],
    ]

    /// One board column: which heading it came from and what it accepts.
    struct Column: Identifiable, Equatable {
        /// The heading text, verbatim — this is what a move writes into the file.
        var heading: String
        var lane: Lane
        var title: String
        var sortIndex: Int
        /// True when the column exists only because the heading was unrecognised.
        var isCustom: Bool { lane == .custom }

        var id: String { heading }
    }

    /// The recognised names, normalised the same way an incoming heading is.
    /// Comparing a normalised heading against un-normalised needles is how the
    /// Turkish entries silently stopped matching.
    private static let normalizedHeadings: [Lane: [String]] = recognisedHeadings
        .mapValues { $0.map(normalize) }

    /// Recognises a heading, honouring a manual override first.
    static func lane(for heading: String, overrides: [String: Lane] = [:]) -> Lane {
        if let override = overrides[heading] { return override }
        let normalized = normalize(heading)
        guard !normalized.isEmpty else { return .custom }
        for lane in Lane.allCases where lane != .custom {
            guard let names = normalizedHeadings[lane] else { continue }
            // Exact match first, so "review" does not win over "in review".
            if names.contains(normalized) { return lane }
        }
        for lane in Lane.allCases where lane != .custom {
            guard let names = normalizedHeadings[lane] else { continue }
            if names.contains(where: { normalized.hasPrefix($0) || normalized.hasSuffix($0) }) {
                return lane
            }
        }
        return .custom
    }

    /// Columns for a document: one per leaf heading that holds tasks, in board
    /// order, with unrecognised headings kept as their own columns.
    static func columns(
        for document: TaskDocument,
        overrides: [String: Lane] = [:],
        columnOrder: [String] = []
    ) -> [Column] {
        var seen: Set<String> = []
        var columns: [Column] = []
        for task in document.tasks {
            guard let heading = task.headingPath.last else { continue }
            guard seen.insert(heading).inserted else { continue }
            let lane = lane(for: heading, overrides: overrides)
            columns.append(Column(
                heading: heading,
                lane: lane,
                title: lane == .custom ? heading : lane.title,
                sortIndex: lane.sortIndex
            ))
        }
        // Tasks with no heading at all still need somewhere to live.
        if document.tasks.contains(where: { $0.headingPath.isEmpty }) {
            columns.append(Column(
                heading: "", lane: .custom, title: "Başlıksız", sortIndex: Lane.custom.sortIndex
            ))
        }
        return sort(columns, order: columnOrder)
    }

    /// Applies a user-defined column order, keeping anything unlisted in lane
    /// order behind it.
    static func sort(_ columns: [Column], order: [String]) -> [Column] {
        guard !order.isEmpty else {
            return columns.sorted {
                $0.sortIndex != $1.sortIndex
                    ? $0.sortIndex < $1.sortIndex
                    : $0.heading < $1.heading
            }
        }
        let position = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        return columns.sorted {
            let left = position[$0.heading]
            let right = position[$1.heading]
            switch (left, right) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return $0.sortIndex != $1.sortIndex
                    ? $0.sortIndex < $1.sortIndex
                    : $0.heading < $1.heading
            }
        }
    }

    /// Tasks in a column: top-level only, since nested ones are shown inside
    /// their parent's card.
    static func tasks(in column: Column, of document: TaskDocument) -> [ProjectTask] {
        document.tasks.filter { task in
            guard task.depth == 0 else { return false }
            return (task.headingPath.last ?? "") == column.heading
        }
    }

    /// Strips numbering, punctuation and diacritics so headings people actually
    /// write are recognised.
    static func normalize(_ heading: String) -> String {
        // Turkish dotless ı and dotted İ are separate letters, not accented
        // ones, so diacritic folding leaves them alone and "tamamlandı" would
        // never match "tamamlandi". They are mapped explicitly.
        let transliterated = heading
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
        let folded = transliterated
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var result = folded
        // Drop a leading "1.", "2)", "Aşama 3 —" style prefix.
        if let range = result.range(of: #"^\s*[\p{L}]*\s*\d+[\.\)]?\s*[—–-]?\s*"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        let cleaned = result
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
        return cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

/// Per-project task view preferences. Uncoil's own state, never the file's.
struct ProjectTaskViewPreferences: Equatable, Codable {
    enum Mode: String, Equatable, Codable, CaseIterable, Identifiable {
        case document
        case list
        case kanban
        case sessions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .document: "Document"
            case .list: "List"
            case .kanban: "Kanban"
            case .sessions: "Sessions"
            }
        }
    }

    /// Whether the board reflects the file's headings (default) or a board Uncoil
    /// keeps on its own. Only file-backed exists today; the flag is the seam.
    enum BoardMode: String, Equatable, Codable {
        case fileBacked
        case virtual
    }

    var mode: Mode = .document
    var boardMode: BoardMode = .fileBacked
    /// Selected source path, or nil for the aggregate view.
    var selectedSourcePath: String?
    var columnOrder: [String] = []
    var headingOverrides: [String: TaskBoardMapping.Lane] = [:]
    var expandedTaskIDs: Set<String> = []
    var filter = TaskFilter()

    static let `default` = ProjectTaskViewPreferences()
}

/// Filters and search over tasks. Pure, so the list view's behaviour is testable
/// without any views.
struct TaskFilter: Equatable, Codable {
    enum Status: String, Equatable, Codable, CaseIterable, Identifiable {
        case all
        case open
        case done
        case assigned
        case unassigned
        case running
        case awaitingReview
        case blocked

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Tümü"
            case .open: "Açık"
            case .done: "Tamamlanmış"
            case .assigned: "Atanmış"
            case .unassigned: "Atanmamış"
            case .running: "Agent çalışıyor"
            case .awaitingReview: "Review bekliyor"
            case .blocked: "Blocked"
            }
        }
    }

    var status: Status = .all
    var sourcePath: String?
    var heading: String?
    var sessionID: UUID?
    var query: String = ""

    var isActive: Bool {
        status != .all || sourcePath != nil || heading != nil
            || sessionID != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Applies the filter. `assignments` maps task id → the sessions working it.
    func apply(
        to tasks: [ProjectTask],
        assignments: [String: [TaskSessionAssignment]] = [:]
    ) -> [ProjectTask] {
        var result = tasks.filter { task in
            let taskAssignments = assignments[task.id] ?? []
            switch status {
            case .all:
                return true
            case .open:
                return !task.isDone
            case .done:
                return task.isDone
            case .assigned:
                return !taskAssignments.isEmpty
            case .unassigned:
                return taskAssignments.isEmpty
            case .running:
                return taskAssignments.contains { $0.state == .running || $0.state == .agentStarting }
            case .awaitingReview:
                return taskAssignments.contains { $0.state == .reviewRequested }
            case .blocked:
                return taskAssignments.contains {
                    $0.state == .blocked || $0.state == .failed || $0.state == .testsFailing
                }
            }
        }
        if let sourcePath {
            result = result.filter { $0.sourcePath == sourcePath }
        }
        if let heading {
            result = result.filter { $0.headingPath.contains(heading) }
        }
        if let sessionID {
            result = result.filter { task in
                (assignments[task.id] ?? []).contains { $0.sessionID == sessionID }
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        // Fuzzy, and ranked: the closest match should be first in a long list.
        return result
            .compactMap { task -> (task: ProjectTask, score: Int)? in
                let candidates = [task.text] + task.headingPath
                let best = candidates
                    .compactMap { FuzzyScore.score(query: trimmed, candidate: $0) }
                    .max()
                guard let best else { return nil }
                return (task, best)
            }
            .sorted { $0.score > $1.score }
            .map(\.task)
    }
}
