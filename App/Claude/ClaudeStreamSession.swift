import AppKit
import Foundation
import SwiftTerm

/// A Claude Code session driven over its structured interface instead of its
/// TUI: `claude -p` in stream-json mode, with Uncoil answering its permission
/// prompts.
///
/// The second provider on the AgentSession model, beside Codex's app server,
/// and built the same way: what Claude says is normalised into `AgentEvent`s
/// once, here at the edge, and every consumer — the terminal, the control
/// plane, whatever comes next — reads those. The terminal is drawn from the
/// events by `AgentTerminalRenderer`; prompts come in through the same
/// `submit` the control plane calls.
@MainActor
final class ClaudeStreamSession: StructuredAgentSession {
    let recordID: UUID
    var sessionID: UUID { recordID }
    let capabilities: AgentControlCapabilities = [
        .structuredTurns, .approvals, .events, .imageAttachments,
    ]
    var isReady: Bool { ready && !stopped }
    /// Where a drafted prompt goes: the terminal's line editor, today.
    var draftHandler: ((String) -> Void)?

    private let record: SessionRecord
    private let transport: ClaudeStreamTransport
    private let history: () async -> [AgentItem]
    private let hub: AgentEventHub
    private weak var terminal: TerminalView?
    private weak var settings: SettingsStore?
    private weak var sessionStore: SessionStore?
    private weak var projectStore: ProjectStore?
    private let fallback: (String) -> Void
    /// Said once the session starts: why it is not the conversation asked for.
    private let startNotice: String?

    private var normalizer: ClaudeEventNormalizer
    private var renderer = AgentTerminalRenderer()
    /// `can_use_tool` requests waiting on an answer, by request id.
    private var pendingApprovals: [String: [String: JSONValue]] = [:]
    /// Images attached since the last turn; they go with the next one.
    private var stagedImages: [AgentAttachment] = []
    private var capturedOutput = Data()
    private var nextRequest = 1
    private var initializeRequestID: String?
    private var turnInProgress = false
    private var ready = false
    private var stopped = false

    init(
        record: SessionRecord,
        providerSessionID: String,
        startNotice: String? = nil,
        transport: ClaudeStreamTransport,
        history: @escaping () async -> [AgentItem] = { [] },
        terminal: TerminalView?,
        settings: SettingsStore?,
        sessionStore: SessionStore?,
        projectStore: ProjectStore?,
        hub: AgentEventHub = .shared,
        fallback: @escaping (String) -> Void
    ) {
        self.record = record
        recordID = record.id
        self.transport = transport
        self.history = history
        self.terminal = terminal
        self.settings = settings
        self.sessionStore = sessionStore
        self.projectStore = projectStore
        self.hub = hub
        self.fallback = fallback
        self.startNotice = startNotice
        normalizer = ClaudeEventNormalizer(providerSessionID: providerSessionID)
    }

    /// Deferred to its own hop: a terminal is created inside a view update,
    /// where claiming the conversation id on the record may not publish.
    func start() {
        Task { @MainActor in
            // Known before the process says anything: it was handed the id.
            if let id = normalizer.providerSessionID { publish(.sessionBound(providerSessionID: id)) }
            if let startNotice { publish(.notice(AgentNotice(level: .warning, message: startNotice))) }
            let earlier = await history()
            guard !stopped else { return }
            if !earlier.isEmpty { publish(.historyLoaded(earlier)) }
            launch()
        }
    }

    private func launch() {
        transport.onLine = { [weak self] line in self?.receive(line) }
        transport.onExit = { [weak self] code, detail in self?.exited(code: code, detail: detail) }
        do {
            try transport.start()
            let id = requestID()
            initializeRequestID = id
            try send(ClaudeStreamProtocol.initialize(requestID: id))
            sessionStore?.setStatus(.idle, detail: String(localized: "Starting structured Claude"), for: recordID)
        } catch {
            failToFallback(error.localizedDescription)
        }
    }

    // MARK: - AgentSessionControl

    func submit(_ prompt: String) async {
        startTurn(prompt)
    }

    func draft(_ prompt: String) async {
        draftHandler?(prompt)
    }

    func attach(_ attachments: [AgentAttachment]) async {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind == .file }
        if !images.isEmpty {
            stagedImages.append(contentsOf: images)
            let names = images.map(\.displayName).joined(separator: ", ")
            publish(.notice(AgentNotice(
                level: .info, message: "Attached \(names) — sent with your next prompt.")))
        }
        // Claude reads a file from disk; the path in the prompt is the attachment.
        if !files.isEmpty {
            draftHandler?(SessionImageDrop.promptFragment(relativePaths: files.map(\.promptPath)))
        }
    }

    func interrupt() {
        guard isReady, turnInProgress else { return }
        do {
            try send(ClaudeStreamProtocol.interrupt(requestID: requestID()))
        } catch {
            display(error.localizedDescription)
        }
    }

    @discardableResult
    func respond(toApproval approvalID: String, decision: String) -> Bool {
        guard let request = pendingApprovals.removeValue(forKey: approvalID) else { return false }
        do {
            try send(ClaudeStreamProtocol.permissionResponse(
                requestID: approvalID, request: request, decision: decision))
        } catch {
            display(error.localizedDescription)
            return false
        }
        sessionStore?.setCodexApproval(nil, for: recordID)
        sessionStore?.setStatus(.running, detail: String(localized: "Approval answered"), for: recordID)
        publish(.approvalResolved(approvalID: approvalID, decision: decision))
        return true
    }

    func sendRaw(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        startTurn(text.trimmingCharacters(in: .newlines))
    }

    func startTurn(_ text: String) {
        guard isReady else {
            publish(.notice(AgentNotice(level: .error, message: "The structured Claude session is not ready yet.")))
            return
        }
        let images = stagedImages
        stagedImages.removeAll()
        do {
            try send(ClaudeStreamProtocol.userMessage(
                text: text, images: images, sessionID: normalizer.providerSessionID))
        } catch {
            stagedImages = images + stagedImages
            display(error.localizedDescription)
            return
        }
        // Claude does not echo a prompt back, so the session says it itself.
        turnInProgress = true
        publish(.turnStarted(turnID: nil))
        publish(.itemCompleted(AgentItem(
            id: "prompt-\(UUID().uuidString)",
            kind: .userMessage(text: text, attachments: images),
            status: .completed, native: nil)))
    }

    // MARK: - StructuredAgentSession

    func stop(terminateServer: Bool = true) {
        guard !stopped else { return }
        stopped = true
        transport.terminate()
    }

    func prepareForApplicationTermination(terminateServer: Bool) {
        // No server outlives the app: the conversation is Claude's transcript,
        // and the next launch resumes it.
        stop()
    }

    func outputSnapshot() async -> Data {
        capturedOutput
    }

    // MARK: - Receiving

    private func receive(_ line: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              let object = value.objectValue else { return }
        switch object["type"]?.stringValue {
        case "control_request":
            handleControlRequest(object)
        case "control_response":
            handleControlResponse(object["response"]?.objectValue ?? [:])
        case "control_cancel_request":
            // Claude withdrew a question — an interrupt ends the prompt it was
            // waiting on.
            if let id = object["request_id"]?.stringValue, pendingApprovals.removeValue(forKey: id) != nil {
                sessionStore?.setCodexApproval(nil, for: recordID)
                publish(.approvalResolved(approvalID: id, decision: "cancelled"))
            }
        default:
            for event in normalizer.events(for: value) { publish(event) }
        }
    }

    private func handleControlResponse(_ response: [String: JSONValue]) {
        guard let id = response["request_id"]?.stringValue, id == initializeRequestID else { return }
        initializeRequestID = nil
        guard response["subtype"]?.stringValue == "success" else {
            failToFallback(response["error"]?.stringValue ?? "Claude refused the structured session.")
            return
        }
        ready = true
        publish(.notice(AgentNotice(level: .info, message: "Structured Claude ready.")))
        sessionStore?.setStatus(.idle, detail: String(localized: "Structured Claude ready"), for: recordID)
    }

    private func handleControlRequest(_ object: [String: JSONValue]) {
        guard let id = object["request_id"]?.stringValue else { return }
        let request = object["request"]?.objectValue ?? [:]
        let subtype = request["subtype"]?.stringValue ?? "unknown"
        guard subtype == "can_use_tool" else {
            try? send(ClaudeStreamProtocol.unsupported(requestID: id, subtype: subtype))
            return
        }
        pendingApprovals[id] = request
        let approval = ClaudeEventNormalizer.approval(requestID: id, request: request)
        let kind: CodexApprovalKind = switch approval.kind {
        case .command: .command
        case .fileChange: .fileChange
        case .permissions: .permissions
        }
        let panel = CodexApprovalRequest(
            id: id,
            sessionID: recordID,
            requestID: .string(id),
            kind: kind,
            title: approval.title,
            detail: approval.detail,
            permissions: nil,
            availableDecisions: approval.decisions)
        // The approval panel and the banner are the app's, not Codex's; they
        // answer through `respond(toApproval:)` whichever provider asked.
        sessionStore?.setCodexApproval(panel, for: recordID)
        sessionStore?.setStatus(.waitingForPermission, detail: approval.title, for: recordID)
        publish(.approvalRequested(approval))
        PermissionNotificationCenter.shared.post(panel, projectID: record.projectID)
    }

    private func exited(code: Int32, detail: String) {
        guard !stopped else { return }
        stopped = true
        let reason = ClaudeStreamError.exited(code, detail).localizedDescription
        guard ready else {
            failToFallback(reason)
            return
        }
        publish(.notice(AgentNotice(level: code == 0 ? .info : .error, message: reason)))
        sessionStore?.setStatus(.terminated, detail: reason, for: recordID)
        projectStore?.markSessionEnded(recordID, exitCode: code)
        TerminalRegistry.shared.markDead(recordID)
    }

    /// The session never got going: hand the view to the terminal launch, so
    /// the user still has Claude, just not the structured one.
    private func failToFallback(_ reason: String) {
        stopped = true
        transport.terminate()
        publish(.notice(AgentNotice(level: .warning, message: "\(reason) Starting the terminal instead.")))
        fallback(reason)
    }

    // MARK: - Publishing

    /// Emits a normalized event: into the hub for every consumer, onto the
    /// terminal through its renderer, and into the session's sidebar status.
    private func publish(_ event: AgentEvent) {
        hub.publish(event, sessionID: recordID, provider: .claude)
        if let text = renderer.render(event) { feed(text) }
        reflect(event)
    }

    private func reflect(_ event: AgentEvent) {
        switch event {
        case .sessionBound(let id):
            // A conversation Claude no longer has is one the record must let
            // go of before it can hold the one that started instead.
            let current = projectStore?.sessions.first { $0.id == recordID }?.providerSessionID
            if let current, current != id { projectStore?.clearProviderSessionID(recordID) }
            _ = projectStore?.claimProviderSessionID(id, for: recordID)
        case .turnStarted:
            sessionStore?.setStatus(.thinking, detail: String(localized: "Claude thinking"), for: recordID)
        case .turnCompleted(_, let outcome):
            turnInProgress = false
            let detail = switch outcome {
            case .completed: String(localized: "Claude finished")
            case .interrupted: String(localized: "Claude interrupted")
            case .failed: String(localized: "Claude turn failed")
            }
            sessionStore?.setStatus(.completed, detail: detail, for: recordID)
        case .itemStarted(let item):
            switch item.kind {
            case .command:
                sessionStore?.setStatus(.running, detail: String(localized: "Running a command"), for: recordID)
            case .fileChange:
                sessionStore?.setStatus(.running, detail: String(localized: "Changing files"), for: recordID)
            case .toolCall:
                sessionStore?.setStatus(.running, detail: String(localized: "Running a tool"), for: recordID)
            case .reasoning:
                sessionStore?.setStatus(.thinking, detail: String(localized: "Claude thinking"), for: recordID)
            default:
                break
            }
        case .itemDelta(_, .text, _):
            sessionStore?.setStatus(.running, detail: String(localized: "Writing a reply"), for: recordID)
        default:
            break
        }
    }

    private func display(_ message: String) {
        publish(.notice(AgentNotice(level: .error, message: message)))
    }

    private func feed(_ text: String) {
        let data = Data(text.utf8)
        capturedOutput.append(data)
        if capturedOutput.count > 262_144 {
            capturedOutput.removeFirst(capturedOutput.count - 262_144)
        }
        if let settings {
            settings.transcriptStore.append(
                data, sessionID: recordID, policy: settings.transcriptRetentionPolicy)
        }
        terminal?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    private func send(_ value: JSONValue) throws {
        try transport.send(ClaudeStreamProtocol.line(value))
    }

    private func requestID() -> String {
        defer { nextRequest += 1 }
        return "uncoil-\(nextRequest)"
    }
}
