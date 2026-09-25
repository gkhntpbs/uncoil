import Foundation

/// The structured state of one agent session, folded from its events.
///
/// This is what a consumer reads when it needs "the conversation so far"
/// rather than a stream: a chat view drawing its first frame, the control
/// plane answering a question about a session, a handoff summarising it.
/// It is a value and it is pure — `apply` is the whole of its behaviour — so
/// the same events always fold to the same timeline.
struct AgentTimeline: Equatable {
    /// Oldest items are dropped past this; a long session must not grow without end.
    static let itemLimit = 1_000
    /// Command output kept per item; the terminal still has all of it.
    static let outputLimit = 64 * 1024

    private(set) var providerSessionID: String?
    private(set) var items: [AgentItem] = []
    private(set) var activeTurnID: String?
    private(set) var turnInProgress = false
    private(set) var lastTurnOutcome: AgentTurnOutcome?
    private(set) var runState: AgentRunState?
    private(set) var pendingApprovals: [AgentApproval] = []
    private(set) var account: AgentAccountState?
    private(set) var notices: [AgentNotice] = []
    /// Sequence of the last event folded in.
    private(set) var sequence = 0

    func item(id: String) -> AgentItem? {
        items.first { $0.id == id }
    }

    mutating func apply(_ record: AgentEventRecord) {
        sequence = record.sequence
        apply(record.event)
    }

    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .sessionBound(let id):
            providerSessionID = id
        case .historyLoaded(let history):
            for item in history { upsert(item) }
        case .turnStarted(let turnID):
            activeTurnID = turnID
            turnInProgress = true
        case .turnCompleted(_, let outcome):
            activeTurnID = nil
            turnInProgress = false
            lastTurnOutcome = outcome
            // A turn that ends leaves nothing it started still running.
            for index in items.indices where items[index].status == .inProgress {
                items[index].status = outcome == .completed ? .completed : .failed
            }
        case .itemStarted(let item):
            upsert(item)
        case .itemDelta(let itemID, let channel, let text):
            appendDelta(text, channel: channel, to: itemID)
        case .itemCompleted(let item):
            var completed = item
            // A provider's final item may omit output it already streamed.
            if case .command(let command, let output, let exitCode) = item.kind,
               output.isEmpty,
               case .command(_, let streamed, _)? = self.item(id: item.id)?.kind {
                completed.kind = .command(command: command, output: streamed, exitCode: exitCode)
            }
            upsert(completed)
        case .runState(let state):
            runState = state
        case .approvalRequested(let approval):
            pendingApprovals.removeAll { $0.id == approval.id }
            pendingApprovals.append(approval)
        case .approvalResolved(let approvalID, _):
            pendingApprovals.removeAll { $0.id == approvalID }
        case .account(let state):
            account = state
        case .notice(let notice):
            notices.append(notice)
            if notices.count > 50 { notices.removeFirst(notices.count - 50) }
        }
    }

    private mutating func upsert(_ item: AgentItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            if items.count > Self.itemLimit {
                items.removeFirst(items.count - Self.itemLimit)
            }
        }
    }

    private mutating func appendDelta(_ text: String, channel: AgentDeltaChannel, to itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            // A delta for an item nobody announced: keep the words anyway.
            let kind: AgentItemKind = channel == .output
                ? .command(command: "", output: text, exitCode: nil)
                : .agentMessage(text: text)
            upsert(AgentItem(id: itemID, kind: kind, status: .inProgress, native: nil))
            return
        }
        switch (items[index].kind, channel) {
        case (.agentMessage(let current), .text):
            items[index].kind = .agentMessage(text: current + text)
        case (.reasoning(let current), .text):
            items[index].kind = .reasoning(summary: current + text)
        case (.command(let command, let current, let exitCode), .output):
            var output = current + text
            if output.utf8.count > Self.outputLimit {
                output = String(output.suffix(Self.outputLimit))
            }
            items[index].kind = .command(command: command, output: output, exitCode: exitCode)
        default:
            break
        }
    }
}

/// Where agent events are published and where consumers find them.
///
/// Each session has one timeline and any number of observers. An integration
/// publishes; the terminal, and whatever comes after it, observe. Nothing here
/// knows which provider produced an event or which surface will show it.
@MainActor
final class AgentEventHub {
    static let shared = AgentEventHub()

    typealias Observer = (AgentEventRecord) -> Void

    private var timelines: [UUID: AgentTimeline] = [:]
    private var observers: [UUID: [UUID: Observer]] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func timeline(for sessionID: UUID) -> AgentTimeline? {
        timelines[sessionID]
    }

    /// Whether a structured integration has published anything for the session.
    func hasTimeline(for sessionID: UUID) -> Bool {
        timelines[sessionID] != nil
    }

    @discardableResult
    func publish(_ event: AgentEvent, sessionID: UUID, provider: AgentProvider) -> AgentEventRecord {
        var timeline = timelines[sessionID] ?? AgentTimeline()
        let record = AgentEventRecord(
            sequence: timeline.sequence + 1,
            sessionID: sessionID,
            provider: provider,
            date: now(),
            event: event
        )
        timeline.apply(record)
        timelines[sessionID] = timeline
        for observer in Array((observers[sessionID] ?? [:]).values) {
            observer(record)
        }
        return record
    }

    /// Delivers every event published for the session from now on. Keep the
    /// returned token; the observation ends when it is cancelled or released.
    func observe(_ sessionID: UUID, _ observer: @escaping Observer) -> AgentEventObservation {
        let token = UUID()
        observers[sessionID, default: [:]][token] = observer
        return AgentEventObservation { [weak self] in
            self?.observers[sessionID]?[token] = nil
        }
    }

    /// The session is gone; its timeline goes with it.
    func end(_ sessionID: UUID) {
        timelines[sessionID] = nil
        observers[sessionID] = nil
    }
}

@MainActor
final class AgentEventObservation {
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    deinit {
        // `deinit` is nonisolated and the hub is main-actor state.
        guard let action = cancelAction else { return }
        Task { @MainActor in action() }
    }
}
