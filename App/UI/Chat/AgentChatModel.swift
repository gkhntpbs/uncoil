import Combine
import Foundation

/// What the chat can do to its session, and nothing else.
///
/// Every verb is the session's own `AgentSessionControl` call — the chat never
/// reaches for a PTY, a provider or a protocol. Kept as closures so a test can
/// stand in for the session without starting one.
@MainActor
struct AgentChatActions {
    var submit: (String) async -> Void
    var interrupt: () -> Void
    var respond: (_ approvalID: String, _ decision: String) -> Bool
    var isReady: () -> Bool

    /// The session as the rest of the app reaches it: through the registry,
    /// which hands back whichever control is behind the session right now — a
    /// relaunch replaces it, so it is looked up on every call, never kept.
    static func registry(sessionID: UUID, provider: AgentProvider) -> AgentChatActions {
        let registry = TerminalRegistry.shared
        return AgentChatActions(
            // Through the registry's submit, not the control's, so a first
            // prompt still names the session the way a typed one does.
            submit: { await registry.submitText($0, for: sessionID, provider: provider) },
            interrupt: { registry.control(for: sessionID, provider: provider).interrupt() },
            respond: { registry.control(for: sessionID, provider: provider).respond(toApproval: $0, decision: $1) },
            isReady: { registry.control(for: sessionID, provider: provider).isReady }
        )
    }
}

/// One item of the transcript, observed on its own.
///
/// A streamed reply changes one item many times a second. Held per item, that
/// redraws the one row it belongs to; held as one array, it would ask SwiftUI
/// to compare the whole transcript on every word.
@MainActor
final class AgentChatItemModel: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var item: AgentItem
    /// Whether the row shows its output, diff or details. Held with the item,
    /// not in the row: a lazy list forgets a row's own state when it scrolls
    /// away, and an opened diff should still be open when the reader returns.
    @Published var isExpanded = false

    init(_ item: AgentItem) {
        id = item.id
        self.item = item
    }

    func update(_ item: AgentItem) {
        if item != self.item { self.item = item }
    }
}

/// The chat's view of one session: its timeline, as rows, kept current from
/// the event hub.
///
/// The timeline stays the source of truth. The model holds no conversation of
/// its own — every flush reads the hub's timeline again — so it cannot drift
/// from what the control plane and the terminal see, and a model created late,
/// or after a relaunch reset the timeline, is right from its first frame.
@MainActor
final class AgentChatModel: ObservableObject {
    /// How often streamed text reaches the screen. Deltas arrive by the word;
    /// drawing each one costs more than it shows.
    static let flushInterval: TimeInterval = 1.0 / 30

    let sessionID: UUID
    @Published private(set) var rows: [AgentChatRow] = []
    @Published private(set) var turnInProgress = false
    @Published private(set) var isReady = false
    /// What the composer holds. Here rather than in the view so a draft handed
    /// to the session — a dispatched task, a dropped file — lands in it.
    @Published var draft = ""
    /// Bumped when the transcript should move to its end whatever the reader
    /// was doing: the user just sent something.
    @Published private(set) var followRequest = 0
    /// Sessions this conversation has addressed or heard from.
    @Published private(set) var participantIDs: Set<UUID> = []

    // MARK: Completion

    /// What the popup above the composer offers for the word being typed.
    @Published private(set) var suggestions: [ChatSuggestion] = []
    @Published var selectedSuggestion = 0
    /// Where the composer's cursor should go after the text was changed from
    /// here — a suggestion taken — rather than by typing.
    @Published private(set) var cursorRequest: Int?
    /// Asked for the suggestions for a word; nil offers none.
    var suggestionProvider: ((ComposerToken) -> [ChatSuggestion])?
    private var completionToken: ComposerToken?

    private let hub: AgentEventHub
    private let actions: AgentChatActions
    private var itemModels: [String: AgentChatItemModel] = [:]
    private var observation: AgentEventObservation?
    private var dirtyItems: Set<String> = []
    private var refreshAll = true
    private var flushScheduled = false

    init(sessionID: UUID, hub: AgentEventHub = .shared, actions: AgentChatActions) {
        self.sessionID = sessionID
        self.hub = hub
        self.actions = actions
        observation = hub.observe(sessionID) { [weak self] record in
            self?.receive(record.event)
        }
        flush()
    }

    convenience init(sessionID: UUID, provider: AgentProvider) {
        self.init(sessionID: sessionID, actions: .registry(sessionID: sessionID, provider: provider))
    }

    /// The model for one item row; made on first use from the timeline.
    func itemModel(for id: String) -> AgentChatItemModel? {
        if let existing = itemModels[id] { return existing }
        guard let item = hub.timeline(for: sessionID)?.item(id: id) else { return nil }
        let model = AgentChatItemModel(item)
        itemModels[id] = model
        return model
    }

    // MARK: - Actions

    /// Sends what the composer holds. False when there was nothing to send or
    /// the session cannot take it yet — the text stays where it was.
    @discardableResult
    func send() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, actions.isReady(), !turnInProgress else { return false }
        draft = ""
        followRequest += 1
        let submit = actions.submit
        Task { await submit(text) }
        return true
    }

    func interrupt() {
        actions.interrupt()
    }

    @discardableResult
    func respond(to approvalID: String, decision: String) -> Bool {
        actions.respond(approvalID, decision)
    }

    /// Sends a line the app composed, as if typed: a command from a menu.
    func submitLine(_ line: String) {
        followRequest += 1
        let submit = actions.submit
        Task { await submit(line) }
    }

    // MARK: - Completion

    /// Re-reads the word under the cursor and what it could become.
    func updateCompletion(cursor: Int) {
        guard let provider = suggestionProvider,
              let token = ComposerToken.at(draft, cursor: cursor) else {
            dismissCompletion()
            return
        }
        let found = provider(token)
        completionToken = found.isEmpty ? nil : token
        if found != suggestions {
            suggestions = found
            selectedSuggestion = 0
        }
    }

    func moveSuggestion(by step: Int) {
        guard !suggestions.isEmpty else { return }
        selectedSuggestion = (selectedSuggestion + step + suggestions.count) % suggestions.count
    }

    /// Replaces the word with the suggestion. False when nothing was offered.
    @discardableResult
    func acceptSuggestion(at index: Int? = nil) -> Bool {
        let index = index ?? selectedSuggestion
        guard let token = completionToken, suggestions.indices.contains(index) else { return false }
        let result = UncoilAutoCompletions.apply(suggestions[index], to: token, in: draft)
        draft = result.text
        cursorRequest = result.cursor
        dismissCompletion()
        return true
    }

    func dismissCompletion() {
        completionToken = nil
        if !suggestions.isEmpty { suggestions = [] }
    }

    func cursorRequestHandled() {
        cursorRequest = nil
    }

    /// A prompt someone else wrote for the user to finish: added to what is
    /// already there, never in place of it.
    func receiveDraft(_ text: String) {
        draft = draft.isEmpty ? text : draft + (draft.hasSuffix(" ") ? "" : " ") + text
    }

    // MARK: - Events

    private func receive(_ event: AgentEvent) {
        switch event {
        case .itemStarted(let item), .itemCompleted(let item):
            dirtyItems.insert(item.id)
        case .itemDelta(let itemID, _, _):
            dirtyItems.insert(itemID)
        case .historyLoaded, .turnCompleted, .sessionBound:
            // Many items at once: a history, or a turn's end settling every
            // item it left running.
            refreshAll = true
        case .turnStarted, .runState, .approvalRequested, .approvalResolved, .account, .notice:
            break
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    /// Brings rows and item models up to the hub's timeline. Public so a test
    /// can see the result without waiting out the frame interval.
    func flush() {
        flushScheduled = false
        let timeline = hub.timeline(for: sessionID) ?? AgentTimeline()
        if refreshAll {
            let current = Dictionary(timeline.items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            itemModels = itemModels.filter { current[$0.key] != nil }
            for (id, model) in itemModels {
                if let item = current[id] { model.update(item) }
            }
        } else {
            for id in dirtyItems {
                if let item = timeline.item(id: id) { itemModels[id]?.update(item) }
            }
        }
        dirtyItems.removeAll()
        refreshAll = false

        let newRows = AgentChatTranscript.rows(for: timeline)
        if newRows != rows { rows = newRows }
        if timeline.turnInProgress != turnInProgress { turnInProgress = timeline.turnInProgress }
        let ready = actions.isReady()
        if ready != isReady { isReady = ready }
        var participants: Set<UUID> = []
        for item in timeline.items {
            if let source = item.source { participants.insert(source.sessionID) }
            for recipient in item.recipients ?? [] { participants.insert(recipient.sessionID) }
        }
        if participants != participantIDs { participantIDs = participants }
    }
}

/// Where a prompt drafted for a session goes when that session's chat is open.
///
/// A dispatched task, a handoff's opening line, a dropped file's path: each is
/// "put this where the user types". For a structured session with its chat on
/// screen, that is the composer, not the terminal's line editor behind it.
@MainActor
final class AgentChatDrafts {
    static let shared = AgentChatDrafts()

    private var sinks: [UUID: [ObjectIdentifier: (String) -> Void]] = [:]
    private var order: [UUID: [ObjectIdentifier]] = [:]

    func register(_ model: AgentChatModel) {
        let key = ObjectIdentifier(model)
        sinks[model.sessionID, default: [:]][key] = { [weak model] in model?.receiveDraft($0) }
        order[model.sessionID, default: []].removeAll { $0 == key }
        order[model.sessionID, default: []].append(key)
    }

    func unregister(_ model: AgentChatModel) {
        let key = ObjectIdentifier(model)
        sinks[model.sessionID]?[key] = nil
        order[model.sessionID]?.removeAll { $0 == key }
    }

    /// Hands the text to the chat most recently shown for the session. False
    /// when none is open, so the caller can put it somewhere else.
    func deliver(_ text: String, to sessionID: UUID) -> Bool {
        guard let key = order[sessionID]?.last, let sink = sinks[sessionID]?[key] else { return false }
        sink(text)
        return true
    }
}
