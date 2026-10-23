import Foundation
import SwiftTerm

/// What Uncoil Auto needs from the rest of the app, and nothing more.
///
/// Closures rather than the stores themselves, so the conversation's rules —
/// who a prompt goes to, what is mirrored back, what is relayed — can be tested
/// without a window, a PTY or an agent.
@MainActor
struct UncoilAutoEnvironment {
    /// The project's agents, by handle.
    var roster: () -> [UncoilAutoRoster.Entry]
    /// Starts a new session of the agent in the project; nil when it cannot.
    var startSession: (AgentProvider) -> UncoilAutoRoster.Entry?
    /// Makes sure the session's process is running, launching it if not.
    var ensureRunning: (UUID) -> Void
    /// Types a prompt into the session's own terminal and submits it.
    var deliver: (_ text: String, _ sessionID: UUID, _ provider: AgentProvider) async -> Void
    /// Types text Uncoil sends on its own account, which must not name the
    /// session: an Auto run's prompts.
    var deliverQuietly: ((_ text: String, _ sessionID: UUID, _ provider: AgentProvider) async -> Void)? = nil
    /// Whether this conversation may address the agent at all.
    var allows: (AgentProvider) -> Bool = { _ in true }
    /// How Auto runs are set up now.
    var autoSettings: () -> AutoHarnessSettings = { AutoHarnessSettings() }
    /// The harness an Auto run is driven through, given Main and the way
    /// this conversation delivers prompts; nil where runs are not possible.
    var harness: (
        _ main: @escaping () async -> AgentItemSource?,
        _ deliver: @escaping (AutoSessionHandle, String) async -> Void
    ) -> AutoHarnessEnvironment? = { _, _ in nil }
    var interrupt: (UUID) -> Void
    var isWorking: (UUID) -> Bool
    /// Starts and stops reading the session's transcript.
    var follow: (UUID) -> Void
    var unfollow: (UUID) -> Void
    /// How far the session's transcript has been read, while it is followed.
    var position: (UUID) -> NativeTranscriptPosition? = { _ in nil }
    /// What the session wrote after `position`: what happened while this
    /// conversation was not listening.
    var catchUp: (UUID, NativeTranscriptPosition) -> (events: [AgentEvent], position: NativeTranscriptPosition)? = { _, _ in nil }
    /// Reads every followed transcript now, before the app lets go of them.
    var pollTranscripts: () -> Void = {}
}

/// Uncoil's own session: the conversation a project's agents are directed from.
///
/// It sits beside the agents rather than in front of them. Claude, Codex and
/// the rest keep running as themselves in their own terminals; a prompt that
/// names one with `@` is typed into that terminal, and what the agent then
/// writes in its transcript is mirrored back here, marked with who said it.
/// Mentioning two agents sends the prompt to both; mentioning one that was not
/// the last to speak hands it the last reply as context — that is how agents
/// hear each other.
///
/// A prompt that names nobody goes to the conversation's target — the agent
/// chosen on the composer's target button, or the one `UncoilAutoRouting`
/// picks — and stays in the conversation only when there is no agent at all.
///
/// `/auto <task>` — or any such prompt, when Settings makes every message a
/// task — starts an Auto run instead: the target becomes Main, and an
/// `AutoOrchestrator` brings in the specialists around it.
@MainActor
final class UncoilAutoSession: StructuredAgentSession {
    let sessionID: UUID
    let capabilities: AgentControlCapabilities = [.structuredTurns, .events]
    var isReady: Bool { !stopped }
    var draftHandler: ((String) -> Void)?

    /// How much of another agent's reply is handed on as context.
    static let relayLimit = 6_000

    private weak var terminal: TerminalView?
    private let hub: AgentEventHub
    private let transcripts: AgentEventHub
    private let environment: UncoilAutoEnvironment
    private let store: UncoilAutoStore?
    let conversation: UncoilAutoConversationState
    /// The Auto run in progress, if any.
    private(set) var orchestrator: AutoOrchestrator?
    private var renderer = AgentTerminalRenderer()
    private var capturedOutput = Data()
    private var stopped = false

    /// Sessions this conversation has spoken to, and is listening to.
    private(set) var participants: [UUID: AgentItemSource] = [:]
    private var observations: [UUID: AgentEventObservation] = [:]
    /// Prompts sent to a session that its transcript has not echoed yet. The
    /// echo is the same prompt, already in the conversation once.
    private var pendingEchoes: [UUID: [String]] = [:]
    /// Everything this session published, to be written down.
    private var log: [AgentEvent] = []
    /// How far each participant's transcript had been mirrored, kept so a
    /// relaunch carries on from there instead of from whatever is new.
    private var positions: [UUID: NativeTranscriptPosition] = [:]

    init(
        record: SessionRecord,
        terminal: TerminalView?,
        environment: UncoilAutoEnvironment,
        store: UncoilAutoStore?,
        hub: AgentEventHub = .shared,
        transcripts: AgentEventHub = .transcripts,
        conversation: UncoilAutoConversationState? = nil
    ) {
        sessionID = record.id
        self.terminal = terminal
        self.environment = environment
        self.store = store
        self.hub = hub
        self.transcripts = transcripts
        self.conversation = conversation ?? .for(record.id)
        self.conversation.onChange = { [weak self] in self?.persist() }
        self.conversation.cancelRun = { [weak self] in self?.cancelRun() }
    }

    /// Picks the conversation up where it was left: what was said, whom it
    /// was said to, and what those agents did while Uncoil was closed.
    func start() {
        guard let saved = store?.load() else { return }
        conversation.restore(
            excluded: Set(saved.excludedAgents ?? []),
            target: saved.target,
            runs: saved.runs ?? [])
        for event in saved.events { publish(event) }
        for (key, texts) in saved.echoes ?? [:] {
            if let id = UUID(uuidString: key) { pendingEchoes[id] = texts }
        }
        for (key, position) in saved.positions ?? [:] {
            if let id = UUID(uuidString: key) { positions[id] = position }
        }
        for source in saved.participants {
            catchUp(with: source)
            listen(to: source)
        }
    }

    /// Mirrors what the agent wrote since the conversation last read its
    /// transcript, and says so when there was anything.
    private func catchUp(with source: AgentItemSource) {
        guard let position = positions[source.sessionID],
              let result = environment.catchUp(source.sessionID, position) else { return }
        positions[source.sessionID] = result.position
        let before = hub.timeline(for: sessionID)?.items.count ?? 0
        for event in result.events { mirror(event, from: source) }
        let added = (hub.timeline(for: sessionID)?.items.count ?? 0) - before
        if added > 0 {
            note(.info, "@\(source.handle) carried on while Uncoil was closed: \(added) update\(added == 1 ? "" : "s") above.")
        }
    }

    // MARK: - AgentSessionControl

    func submit(_ prompt: String) async {
        guard isReady else { return }
        switch UncoilAutoInput.parse(prompt) {
        case .command(let command, let argument, let mentions):
            await run(command, argument: argument, mentions: mentions, raw: prompt)
        case .message(let text, let mentions):
            await send(text, to: mentions, raw: prompt)
        }
    }

    func draft(_ prompt: String) async {
        draftHandler?(prompt)
    }

    func attach(_ attachments: [AgentAttachment]) async {
        draftHandler?(SessionImageDrop.promptFragment(relativePaths: attachments.map(\.promptPath)))
    }

    /// Stops the Auto run, and every agent in the conversation that is working.
    func interrupt() {
        orchestrator?.cancel()
        for id in participants.keys where environment.isWorking(id) {
            environment.interrupt(id)
        }
    }

    @discardableResult
    func respond(toApproval approvalID: String, decision: String) -> Bool {
        false
    }

    func sendRaw(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        Task { await submit(text.trimmingCharacters(in: .newlines)) }
    }

    // MARK: - StructuredAgentSession

    func stop(terminateServer: Bool) {
        guard !stopped else { return }
        orchestrator?.cancel()
        // Whatever the agents wrote in the last moments is read before the
        // positions are written down, so the next launch does not skip it.
        environment.pollTranscripts()
        persist()
        stopped = true
        store?.saveNow()
        conversation.participants = []
        for id in Array(observations.keys) {
            observations.removeValue(forKey: id)?.cancel()
            environment.unfollow(id)
        }
    }

    func prepareForApplicationTermination(terminateServer: Bool) {
        stop(terminateServer: terminateServer)
    }

    func outputSnapshot() async -> Data {
        capturedOutput
    }

    // MARK: - Sending

    private func send(_ text: String, to mentions: [String], raw: String) async {
        let auto = environment.autoSettings()
        if mentions.isEmpty, auto.enabled, auto.mode == .everyMessage, !text.hasPrefix("/") {
            await startRun(text, raw: raw)
            return
        }
        let roster = environment.roster()
        // A prompt that names nobody goes to the conversation's target, which
        // the first such send pins so it stays put until the user changes it.
        var mentions = mentions
        if mentions.isEmpty, let routed = UncoilAutoRouting.target(
            chosen: conversation.target, roster: roster, allows: environment.allows) {
            mentions = [routed.handle]
            if conversation.target == nil { conversation.target = routed.handle }
        }
        var targets: [AgentItemSource] = []
        var unknown: [String] = []
        var blocked: [String] = []
        for handle in mentions {
            if let entry = roster.first(where: { $0.handle == handle }) {
                if !environment.allows(entry.provider) {
                    blocked.append(handle)
                } else if let source = entry.source {
                    targets.append(source)
                } else if let started = environment.startSession(entry.provider)?.source {
                    targets.append(started)
                    note(.info, "Started \(started.provider.displayName) as @\(started.handle).")
                }
            } else {
                unknown.append(handle)
            }
        }
        // An agent's own command goes to it exactly as written. Anything else
        // carries the last reply of an agent not being addressed — read
        // before this prompt joins the conversation and becomes the latest.
        let isAgentCommand = text.hasPrefix("/")
        let relay = isAgentCommand || targets.isEmpty ? nil : lastReply(excluding: Set(targets.map(\.sessionID)))
        let turnID = UUID().uuidString
        publish(.itemCompleted(AgentItem(
            id: "prompt-\(turnID)",
            kind: .userMessage(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), attachments: []),
            status: .completed,
            native: nil,
            recipients: targets.isEmpty ? nil : targets
        )))
        if !unknown.isEmpty {
            note(.warning, "No agent called \(unknown.map { "@\($0)" }.joined(separator: ", ")) in this project.")
        }
        if !blocked.isEmpty {
            note(.warning, "\(blocked.map { "@\($0)" }.joined(separator: ", ")) is not open to Uncoil Auto. Allow it in the agents panel or in Settings.")
        }
        guard !targets.isEmpty else {
            if mentions.isEmpty {
                note(.info, "Not sent: choose an agent with the button beside the field, or mention one with @.")
            }
            return
        }
        guard !text.isEmpty else { return }
        if let relay {
            note(.info, "Included @\(relay.source.handle)'s last reply for \(targets.map { "@\($0.handle)" }.joined(separator: ", ")).")
        }
        for target in targets {
            listen(to: target)
            environment.ensureRunning(target.sessionID)
            let body = relay.map { Self.withContext(text, from: $0.source, reply: $0.text) } ?? text
            pendingEchoes[target.sessionID, default: []].append(body)
            await environment.deliver(body, target.sessionID, target.provider)
            if isAgentCommand, NativeAgentCommands.answersInTerminal(text, provider: target.provider) {
                publish(.notice(AgentNotice(
                    level: .info,
                    message: "\(text.split(separator: " ").first ?? "") answers in @\(target.handle)'s own terminal.",
                    action: .openTerminal(sessionID: target.sessionID, handle: target.handle))))
            }
        }
    }

    /// The prompt with another agent's reply attached below it.
    static func withContext(_ prompt: String, from source: AgentItemSource, reply: String) -> String {
        let clipped = reply.count > relayLimit ? String(reply.prefix(relayLimit)) + "…" : reply
        return "\(prompt)\n\nFor context, @\(source.handle) (\(source.provider.displayName)) replied:\n\n\(clipped)"
    }

    /// The last thing an agent said in this conversation, when it was not one
    /// of the agents now being addressed.
    private func lastReply(excluding targets: Set<UUID>) -> (source: AgentItemSource, text: String)? {
        guard let items = hub.timeline(for: sessionID)?.items else { return nil }
        for item in items.reversed() {
            if case .userMessage = item.kind, item.source == nil { return nil }
            guard case .agentMessage(let text) = item.kind, let source = item.source, !text.isEmpty else { continue }
            return targets.contains(source.sessionID) ? nil : (source, text)
        }
        return nil
    }

    // MARK: - Commands

    private func run(_ command: UncoilAutoCommand, argument: String, mentions: [String], raw: String) async {
        publish(.itemCompleted(AgentItem(
            id: "command-\(UUID().uuidString)",
            kind: .userMessage(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), attachments: []),
            status: .completed, native: nil)))
        switch command {
        case .new:
            let name = argument.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            guard let provider = AgentProvider.agents.first(where: {
                $0.rawValue == name || $0.displayName.lowercased() == name
            }) else {
                note(.warning, "Say which agent to start: \(AgentProvider.agents.map(\.rawValue).joined(separator: ", ")).")
                return
            }
            guard environment.allows(provider) else {
                note(.warning, "\(provider.displayName) is not open to Uncoil Auto. Allow it in the agents panel or in Settings.")
                return
            }
            guard let started = environment.startSession(provider)?.source else {
                note(.error, "\(provider.displayName) could not be started here.")
                return
            }
            note(.info, "Started \(provider.displayName) as @\(started.handle).")
            listen(to: started)
            let prompt = String(argument.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            if !prompt.isEmpty {
                pendingEchoes[started.sessionID, default: []].append(prompt)
                await environment.deliver(prompt, started.sessionID, provider)
            }
        case .stop:
            let roster = environment.roster().filter { environment.allows($0.provider) }
            let named = mentions.compactMap { handle in roster.first { $0.handle == handle }?.sessionID }
            let ids = named.isEmpty ? Array(participants.keys) : named
            let working = ids.filter(environment.isWorking)
            working.forEach(environment.interrupt)
            note(.info, working.isEmpty ? "No agent was working." : "Stopped \(working.count) agent\(working.count == 1 ? "" : "s").")
        case .agents:
            let lines = environment.roster().filter { environment.allows($0.provider) }.map { entry -> String in
                let state = entry.sessionID.map { environment.isWorking($0) ? "working" : "idle" } ?? "not started"
                return "@\(entry.handle) — \(entry.provider.displayName), \(state)"
            }
            note(.info, lines.isEmpty ? "No agents in this project yet." : lines.joined(separator: "\n"))
        case .auto:
            await startRun(argument, raw: nil)
        case .cancel:
            if orchestrator?.isRunning == true {
                cancelRun()
            } else {
                note(.info, "No Auto run is going.")
            }
        case .clear:
            hub.reset(sessionID)
            log.removeAll()
            note(.info, "Conversation cleared.")
        case .help:
            note(.info, (UncoilAutoCommand.allCases.map { "\($0.usage) — \($0.summary)" }
                + ["@agent message — send to an agent", "@agent /command — run the agent's own command"])
                .joined(separator: "\n"))
        }
    }

    // MARK: - Listening

    /// Mirrors what the session writes in its transcript into this
    /// conversation, from now on.
    private func listen(to source: AgentItemSource) {
        participants[source.sessionID] = source
        conversation.participants.insert(source.sessionID)
        guard observations[source.sessionID] == nil else { return }
        environment.follow(source.sessionID)
        observations[source.sessionID] = transcripts.observe(source.sessionID) { [weak self] record in
            self?.mirror(record.event, from: source)
        }
        persist()
    }

    private func mirror(_ event: AgentEvent, from source: AgentItemSource) {
        switch event {
        case .itemStarted(let item), .itemCompleted(let item):
            if case .userMessage(let text, _) = item.kind, consumeEcho(text, for: source.sessionID) { return }
            let id = "\(source.sessionID.uuidString.prefix(8)):\(item.id)"
            var kind = item.kind
            // The block an Auto run reads is for the run; the conversation
            // shows the prose around it.
            if case .agentMessage(let text) = kind, text.contains("```\(AutoHandoff.fence)") {
                kind = .agentMessage(text: Self.withoutHandoff(text))
            }
            // A tool's result read without its start — the start was mirrored
            // before a relaunch — knows only that "a tool" finished. What the
            // tool was is already here; keep it, and take the result.
            if case .toolCall(let call) = item.kind, call.origin == .agent, call.name == "tool",
               let existing = hub.timeline(for: sessionID)?.item(id: id) {
                kind = existing.kind
                if case .command(let command, _, let exitCode) = existing.kind,
                   case .command(_, let output, _) = item.kind {
                    kind = .command(command: command, output: output, exitCode: exitCode)
                }
            }
            publish(.itemCompleted(AgentItem(
                id: id, kind: kind, status: item.status, native: item.native, source: source)))
        case .notice(let notice):
            note(notice.level, "@\(source.handle): \(notice.message)")
        case .turnCompleted(_, let outcome):
            switch outcome {
            case .interrupted: note(.info, "@\(source.handle) was interrupted.")
            case .failed(let message): note(.error, "@\(source.handle)'s turn failed\(message.map { ": \($0)" } ?? ".")")
            case .completed: break
            }
        default:
            // A history read when following starts is what the agent did
            // before it joined this conversation; it stays in its terminal.
            break
        }
    }

    /// Whether the transcript's user message is a prompt this conversation
    /// sent. Compared loosely: a terminal may fold whitespace on the way in.
    private func consumeEcho(_ text: String, for sessionID: UUID) -> Bool {
        let seen = Self.normalized(text)
        guard var pending = pendingEchoes[sessionID],
              let index = pending.firstIndex(where: { Self.normalized($0).hasPrefix(seen.prefix(80)) || seen.hasPrefix(Self.normalized($0).prefix(80)) })
        else { return false }
        pending.remove(at: index)
        pendingEchoes[sessionID] = pending
        return true
    }

    /// Whitespace folded, and Claude's paste markers taken off: a prompt
    /// long enough to be pasted comes back wrapped in them.
    private static func normalized(_ text: String) -> String {
        ClaudeTranscriptText.clean(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Publishing

    private func note(_ level: AgentNotice.Level, _ message: String) {
        publish(.notice(AgentNotice(level: level, message: message)))
    }

    private func publish(_ event: AgentEvent) {
        hub.publish(event, sessionID: sessionID, provider: .uncoil)
        log.append(event)
        if log.count > UncoilAutoStore.eventLimit { log.removeFirst(log.count - UncoilAutoStore.eventLimit) }
        persist()
        if let text = renderer.render(event) {
            let data = Data(text.utf8)
            capturedOutput.append(data)
            terminal?.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    private func persist() {
        guard !stopped else { return }
        for id in participants.keys {
            if let position = environment.position(id) { positions[id] = position }
        }
        store?.save(
            events: log,
            participants: Array(participants.values),
            positions: positions,
            echoes: pendingEchoes,
            excludedAgents: conversation.excludedAgents,
            target: conversation.target,
            runs: conversation.runs)
    }

    // MARK: - Auto runs

    /// Starts an Auto run on `task`, with the conversation's target as Main.
    private func startRun(_ task: String, raw: String?) async {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw {
            publish(.itemCompleted(AgentItem(
                id: "auto-\(UUID().uuidString)",
                kind: .userMessage(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), attachments: []),
                status: .completed, native: nil)))
        }
        guard environment.autoSettings().enabled else {
            note(.warning, "Auto runs are turned off in Settings › Uncoil Auto.")
            return
        }
        guard !task.isEmpty else {
            note(.info, "Say what the run should do: /auto <task>.")
            return
        }
        guard orchestrator?.isRunning != true else {
            note(.warning, "An Auto run is already going. /cancel stops it.")
            return
        }
        guard let harness = environment.harness(
            { [weak self] in await self?.mainForRun() },
            { [weak self] handle, text in await self?.deliverForRun(text, to: handle) }
        ) else {
            note(.error, "Auto runs are not available here.")
            return
        }
        let orchestrator = AutoOrchestrator(task: task, environment: harness) { [weak self] report in
            self?.take(report)
        }
        self.orchestrator = orchestrator
        orchestrator.start()
    }

    func cancelRun() {
        orchestrator?.cancel()
    }

    /// Main: the conversation's target, started when it has no session yet.
    private func mainForRun() async -> AgentItemSource? {
        let roster = environment.roster()
        guard let entry = UncoilAutoRouting.target(chosen: conversation.target, roster: roster, allows: environment.allows)
        else { return nil }
        var source = entry.source
        if source == nil, let started = environment.startSession(entry.provider)?.source {
            note(.info, "Started \(started.provider.displayName) as @\(started.handle).")
            source = started
        }
        guard let source else { return nil }
        if conversation.target == nil { conversation.target = source.handle }
        listen(to: source)
        environment.ensureRunning(source.sessionID)
        return source
    }

    /// A run's prompt, typed without naming the session. Main's is expected
    /// back in its transcript and not shown twice; a specialist is not part
    /// of this conversation, so nothing it says is mirrored here.
    private func deliverForRun(_ text: String, to handle: AutoSessionHandle) async {
        if participants[handle.sessionID] != nil {
            pendingEchoes[handle.sessionID, default: []].append(text)
        }
        let deliver = environment.deliverQuietly ?? environment.deliver
        await deliver(text, handle.sessionID, handle.provider)
    }

    private func take(_ report: AutoOrchestrator.Report) {
        switch report {
        case .run(let run):
            conversation.update(run)
        case .notice(let level, let message, let open):
            publish(.notice(AgentNotice(
                level: level, message: message,
                action: open.map { .openTerminal(sessionID: $0.sessionID, handle: $0.handle) })))
        case .handoff(let role, let handle, let handoff):
            publish(.itemCompleted(AgentItem(
                id: "auto-\(role.rawValue)-\(UUID().uuidString)",
                kind: .agentMessage(text: handoff.digest()),
                status: .completed, native: nil,
                source: AgentItemSource(sessionID: handle.sessionID, provider: handle.provider, handle: handle.handle))))
        }
    }

    /// The text with its handoff block taken out.
    nonisolated static func withoutHandoff(_ text: String) -> String {
        guard let open = text.range(of: "```\(AutoHandoff.fence)") else { return text }
        let after = text[open.upperBound...]
        let close = after.range(of: "```").map { $0.upperBound } ?? text.endIndex
        return (String(text[..<open.lowerBound]) + String(text[close...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where an Uncoil Auto conversation is kept between launches: the events it
/// published and the agents it was listening to, one file per session.
@MainActor
final class UncoilAutoStore {
    struct Saved: Codable, Equatable {
        var version = 1
        var events: [AgentEvent]
        var participants: [AgentItemSource]
        /// How far each participant's transcript was read, by session id.
        var positions: [String: NativeTranscriptPosition]?
        /// Prompts sent that the agent had not echoed yet, by session id.
        var echoes: [String: [String]]?
        /// Agents this conversation was narrowed away from, by provider.
        var excludedAgents: [String]?
        /// Where prompts naming nobody go, by handle.
        var target: String?
        /// The conversation's Auto runs and their diagnostics.
        var runs: [AutoRun]?
    }

    static let eventLimit = 3_000

    let url: URL
    private var pending: Saved?
    private var scheduled = false
    private let delay: TimeInterval

    init(url: URL, delay: TimeInterval = 1) {
        self.url = url
        self.delay = delay
    }

    static func url(for sessionID: UUID, in directory: URL = ProjectStore.defaultDirectory()) -> URL {
        directory
            .appendingPathComponent("uncoil-auto", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    func load() -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Written a moment later, so a burst of events is one write.
    func save(
        events: [AgentEvent],
        participants: [AgentItemSource],
        positions: [UUID: NativeTranscriptPosition] = [:],
        echoes: [UUID: [String]] = [:],
        excludedAgents: Set<String> = [],
        target: String? = nil,
        runs: [AutoRun] = []
    ) {
        pending = Saved(
            events: events,
            participants: participants.sorted { $0.handle < $1.handle },
            positions: Dictionary(uniqueKeysWithValues: positions.map { ($0.key.uuidString, $0.value) }),
            echoes: Dictionary(uniqueKeysWithValues: echoes.filter { !$0.value.isEmpty }.map { ($0.key.uuidString, $0.value) }),
            excludedAgents: excludedAgents.isEmpty ? nil : excludedAgents.sorted(),
            target: target,
            runs: runs.isEmpty ? nil : runs)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.saveNow()
        }
    }

    func saveNow() {
        scheduled = false
        guard let pending else { return }
        self.pending = nil
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
