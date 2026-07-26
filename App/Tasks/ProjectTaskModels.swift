import Foundation

/// Where a task came from: one `TODO.md` file under a project.
///
/// The file stays the source of truth. Uncoil never invents syntax, never writes
/// its own session or agent identifiers into it, and never regenerates it — so a
/// `TODO.md` keeps working for Claude, Codex or a plain editor with Uncoil
/// nowhere in sight.
struct ProjectTaskSource: Identifiable, Equatable, Codable {
    /// Absolute path of the file.
    let path: String
    let projectID: UUID
    /// Path shown in the UI, relative to the project root.
    var displayPath: String
    /// Hash of the file when it was last read, for change detection.
    var contentHash: String
    var lastReadAt: Date
    var taskCount: Int
    var openTaskCount: Int

    var id: String { path }

    var isRoot: Bool { !displayPath.contains("/") }
}

/// A byte range plus the human coordinates that go with it. Byte offsets are
/// what patching uses; line and column are what a user is shown.
struct TaskSourceRange: Equatable, Codable {
    /// UTF-8 byte offsets, half-open.
    var startByte: Int
    var endByte: Int
    /// 1-based.
    var startLine: Int
    var endLine: Int
    /// 1-based, in characters, on `startLine`.
    var startColumn: Int

    var byteCount: Int { endByte - startByte }
    var lineCount: Int { endLine - startLine + 1 }

    func contains(byte: Int) -> Bool { byte >= startByte && byte < endByte }

    func overlaps(_ other: TaskSourceRange) -> Bool {
        startByte < other.endByte && other.startByte < endByte
    }
}

/// The checkbox as the file spells it — including which marker and which letter
/// were used, so rewriting one preserves the author's style.
struct ProjectTaskCheckboxState: Equatable, Codable {
    enum Mark: String, Equatable, Codable {
        case open
        case done

        var isDone: Bool { self == .done }
    }

    var mark: Mark
    /// `-`, `*`, `+`, or an ordered-list marker such as `1.` or `7)`.
    var listMarker: String
    /// The exact character inside the brackets: " ", "x", "X", "-", "~" or "/".
    var markerCharacter: String
    /// Leading whitespace of the task line — including any blockquote `>`
    /// markers — reproduced verbatim.
    var indent: String
    /// Range of just the `[ ]` bracket pair, so toggling touches nothing else.
    var markerRange: TaskSourceRange

    var isDone: Bool { mark.isDone }

    /// The character to write when toggling, keeping the author's capitalisation.
    func toggledCharacter() -> String {
        isDone ? " " : (markerCharacter == "X" ? "X" : "x")
    }
}

/// A heading in the file, used to give tasks their context chain.
struct ProjectTaskHeading: Equatable, Codable {
    /// 1…6.
    var level: Int
    var text: String
    var range: TaskSourceRange
}

/// Everything in the file is covered by blocks, in order: concatenating their
/// source ranges reproduces the file byte-for-byte. A block the parser does not
/// understand is kept as `.passthrough`, which is what makes editing lossless.
struct ProjectTaskBlock: Identifiable, Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case heading
        case task
        /// Anything else: prose, code fences, tables, HTML comments, blank lines.
        case passthrough
    }

    let id: UUID
    var kind: Kind
    var range: TaskSourceRange
    /// Set for `.task` blocks.
    var taskID: String?

    init(id: UUID = UUID(), kind: Kind, range: TaskSourceRange, taskID: String? = nil) {
        self.id = id
        self.kind = kind
        self.range = range
        self.taskID = taskID
    }
}

/// One checkbox task, as the file has it.
struct ProjectTask: Identifiable, Equatable, Codable {
    /// Stable within one parse: the fingerprint's strong key.
    let id: String
    var sourcePath: String
    var checkbox: ProjectTaskCheckboxState
    /// The task's own text, without the marker or checkbox. Markdown verbatim,
    /// because this is what the file says and what an agent is given.
    var text: String

    /// ``text`` with Markdown's inline marks removed, for drawing in a row.
    /// The file keeps its `**`, backticks and links; only the interface drops
    /// them.
    var displayText: String { MarkdownInline.plain(text) }
    /// Every line of the task: its own line plus indented continuation,
    /// including fenced code that belongs to it.
    var blockRange: TaskSourceRange
    /// Just the task's first line.
    var lineRange: TaskSourceRange
    /// Raw Markdown of the whole block, verbatim.
    var rawBlock: String
    /// Headings above it, outermost first.
    var headingPath: [String]
    /// Nesting depth, 0 for a top-level task.
    var depth: Int
    /// Parent task id when nested.
    var parentID: String?
    /// Child task ids, in file order.
    var childIDs: [String]
    /// Position among the tasks under the same heading, 0-based.
    var orderUnderHeading: Int
    var fingerprint: TaskFingerprint

    var isDone: Bool { checkbox.isDone }
    var hasChildren: Bool { !childIDs.isEmpty }
}

/// What Uncoil knows about a task that the file does not: the live state of the
/// work. Deliberately separate from the checkbox — the file records whether a
/// task is done, Uncoil records what is happening right now.
enum ProjectTaskExecutionState: String, Equatable, Codable, CaseIterable {
    case unassigned
    case queued
    case assigned
    case agentStarting
    case running
    case waitingForPermission
    case waitingForUser
    case testsFailing
    case reviewRequested
    case blocked
    case failed
    case completed

    var label: String {
        switch self {
        case .unassigned: String(localized: "Not assigned")
        case .queued: String(localized: "Queued")
        case .assigned: String(localized: "Assigned")
        case .agentStarting: String(localized: "Agent starting")
        case .running: String(localized: "Running")
        case .waitingForPermission: String(localized: "Waiting for permission")
        case .waitingForUser: String(localized: "Waiting for you")
        case .testsFailing: String(localized: "Tests failing")
        case .reviewRequested: String(localized: "Review requested")
        case .blocked: String(localized: "Blocked")
        case .failed: String(localized: "Failed")
        case .completed: String(localized: "Done")
        }
    }

    /// States that want the user, so the Attention Center can pick them up.
    var needsAttention: Bool {
        switch self {
        case .waitingForPermission, .waitingForUser, .testsFailing,
             .reviewRequested, .blocked, .failed:
            true
        case .unassigned, .queued, .assigned, .agentStarting, .running, .completed:
            false
        }
    }

    /// Work is in flight — a second agent must not claim the same task.
    var isActive: Bool {
        switch self {
        case .assigned, .agentStarting, .running, .waitingForPermission,
             .waitingForUser, .reviewRequested:
            true
        case .unassigned, .queued, .testsFailing, .blocked, .failed, .completed:
            false
        }
    }
}

/// What an agent was asked to do for a task.
enum TaskAgentRole: String, Equatable, Codable, CaseIterable, Identifiable {
    /// Accountable for the task, not necessarily doing the work.
    case owner
    case implementer
    case reviewer
    case tester
    /// Watching without changing anything — a reader, not a writer.
    case observer
    /// Coordinates other sessions on this task.
    case orchestrator

    var id: String { rawValue }

    var label: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .implementer: String(localized: "Implementer")
        case .reviewer: String(localized: "Review")
        case .tester: String(localized: "Test")
        case .observer: String(localized: "Observer")
        case .orchestrator: String(localized: "Orchestrator")
        }
    }

    /// Roles that actually change the working tree, so a claim only has to
    /// exclude those from each other.
    var writes: Bool {
        switch self {
        case .implementer, .tester: true
        case .owner, .reviewer, .observer, .orchestrator: false
        }
    }

    /// Names written by an earlier build decode into their current equivalents,
    /// so a stored assignment is never lost to a rename.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "implement": self = .implementer
        case "review": self = .reviewer
        case "test": self = .tester
        case "investigate": self = .observer
        default:
            guard let value = TaskAgentRole(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "bilinmeyen rol: \(raw)"
                ))
            }
            self = value
        }
    }
}

/// One step in a task's execution history: what state it entered and when.
struct TaskExecutionEvent: Identifiable, Equatable, Codable {
    let id: UUID
    var state: ProjectTaskExecutionState
    var at: Date
    /// Free-text reason, e.g. why it was blocked.
    var detail: String?

    init(
        id: UUID = UUID(),
        state: ProjectTaskExecutionState,
        at: Date = .now,
        detail: String? = nil
    ) {
        self.id = id
        self.state = state
        self.at = at
        self.detail = detail
    }
}

/// A session working on a task. Lives in Uncoil's own store — never in the file.
struct TaskSessionAssignment: Identifiable, Equatable, Codable {
    let id: UUID
    var taskID: String
    var sourcePath: String
    var sessionID: UUID
    var role: TaskAgentRole
    var state: ProjectTaskExecutionState
    var worktreePath: String?
    var assignedAt: Date
    var updatedAt: Date
    /// Set when the fingerprint no longer resolves, so the UI can ask the user
    /// which task this session was really working on.
    var needsRelinking: Bool
    /// The task's fingerprint when the assignment was made, so the link can be
    /// re-established after the file changed without consulting the file again.
    var fingerprint: TaskFingerprint?
    /// Every state this assignment passed through, oldest first.
    var history: [TaskExecutionEvent]

    init(
        id: UUID = UUID(),
        taskID: String,
        sourcePath: String,
        sessionID: UUID,
        role: TaskAgentRole,
        state: ProjectTaskExecutionState = .assigned,
        worktreePath: String? = nil,
        assignedAt: Date = .now,
        updatedAt: Date = .now,
        needsRelinking: Bool = false,
        fingerprint: TaskFingerprint? = nil,
        history: [TaskExecutionEvent] = []
    ) {
        self.id = id
        self.taskID = taskID
        self.sourcePath = sourcePath
        self.sessionID = sessionID
        self.role = role
        self.state = state
        self.worktreePath = worktreePath
        self.assignedAt = assignedAt
        self.updatedAt = updatedAt
        self.needsRelinking = needsRelinking
        self.fingerprint = fingerprint
        self.history = history.isEmpty
            ? [TaskExecutionEvent(state: state, at: assignedAt)]
            : history
    }
}

/// A time-boxed claim so two agents never work the same task at once.
struct TaskClaimLease: Identifiable, Equatable, Codable {
    let id: UUID
    var taskID: String
    var sourcePath: String
    var sessionID: UUID
    var acquiredAt: Date
    var expiresAt: Date
    /// Bumped on every renewal, so a stale holder cannot overwrite a newer one.
    var generation: Int

    init(
        id: UUID = UUID(),
        taskID: String,
        sourcePath: String,
        sessionID: UUID,
        acquiredAt: Date = .now,
        duration: TimeInterval = 15 * 60,
        generation: Int = 1
    ) {
        self.id = id
        self.taskID = taskID
        self.sourcePath = sourcePath
        self.sessionID = sessionID
        self.acquiredAt = acquiredAt
        self.expiresAt = acquiredAt.addingTimeInterval(duration)
        self.generation = generation
    }

    func isExpired(at date: Date = .now) -> Bool { date >= expiresAt }

    func isHeld(by sessionID: UUID, at date: Date = .now) -> Bool {
        self.sessionID == sessionID && !isExpired(at: date)
    }
}

/// How a board column maps onto file and execution state. The mapping is
/// Uncoil's, so a board never requires the file to carry column names.
struct TaskBoardColumnMapping: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    /// Execution states shown in this column.
    var executionStates: [ProjectTaskExecutionState]
    /// When set, only tasks whose checkbox matches land here.
    var checkboxMark: ProjectTaskCheckboxState.Mark?
    var sortIndex: Int

    /// The default board: file state on the outside, execution state in between.
    static let defaults: [TaskBoardColumnMapping] = [
        .init(
            id: "open", title: "On",
            executionStates: [.unassigned, .queued], checkboxMark: .open, sortIndex: 0
        ),
        .init(
            id: "inProgress", title: String(localized: "Being worked on"),
            executionStates: [.assigned, .agentStarting, .running],
            checkboxMark: nil, sortIndex: 1
        ),
        .init(
            id: "needsUser", title: String(localized: "Waiting"),
            executionStates: [.waitingForPermission, .waitingForUser, .reviewRequested],
            checkboxMark: nil, sortIndex: 2
        ),
        .init(
            id: "problems", title: String(localized: "Problem"),
            executionStates: [.testsFailing, .blocked, .failed],
            checkboxMark: nil, sortIndex: 3
        ),
        .init(
            id: "done", title: String(localized: "Done"),
            executionStates: [.completed], checkboxMark: .done, sortIndex: 4
        ),
    ]

    func accepts(task: ProjectTask, state: ProjectTaskExecutionState) -> Bool {
        if let checkboxMark, task.checkbox.mark != checkboxMark { return false }
        return executionStates.contains(state)
    }
}

/// Versioned envelope for the task metadata Uncoil stores next to a project, so
/// a schema change can migrate rather than discard.
struct ProjectTaskMetadataDocument: Equatable, Codable {
    static let currentVersion = 1

    var version = ProjectTaskMetadataDocument.currentVersion
    var assignments: [TaskSessionAssignment] = []
    var leases: [TaskClaimLease] = []
    var columns: [TaskBoardColumnMapping] = TaskBoardColumnMapping.defaults
    /// Task ids whose fingerprint stopped resolving; shown as Needs relinking.
    var needsRelinking: [String] = []
    /// Opt-in: write a portable HTML-comment id into the file.
    var portableIDsEnabled = false
}
