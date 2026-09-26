import Foundation
import SwiftTerm

/// A structured session with a script instead of an agent, for `-chat-fixture`.
///
/// It is a real `StructuredAgentSession`: it is registered where Codex and
/// Claude sessions are, publishes into the same hub, draws the same terminal
/// through the same renderer, and answers the same control calls. Only what it
/// says is made up — so everything that reads a structured session can be
/// looked at, and driven, without a CLI, a login or a quota.
@MainActor
final class FixtureAgentSession: StructuredAgentSession {
    let sessionID: UUID
    let capabilities: AgentControlCapabilities = [.structuredTurns, .approvals, .events]
    var isReady: Bool { ready && !stopped }
    var draftHandler: ((String) -> Void)?

    private let provider: AgentProvider
    private weak var terminal: TerminalView?
    private weak var sessionStore: SessionStore?
    private let hub: AgentEventHub
    private let delay: UInt64
    private var renderer = AgentTerminalRenderer()
    private var capturedOutput = Data()
    private var ready = false
    private var stopped = false
    private var turn: Task<Void, Never>?
    private var approval: CheckedContinuation<String, Never>?
    private var approvalID: String?
    private var turnNumber = 0

    init(
        record: SessionRecord,
        terminal: TerminalView?,
        sessionStore: SessionStore?,
        hub: AgentEventHub = .shared,
        wordDelay: UInt64 = 28_000_000
    ) {
        sessionID = record.id
        provider = record.provider
        self.terminal = terminal
        self.sessionStore = sessionStore
        self.hub = hub
        delay = wordDelay
    }

    func start() {
        Task { @MainActor in
            publish(.sessionBound(providerSessionID: "fixture-\(sessionID.uuidString.prefix(8).lowercased())"))
            publish(.historyLoaded(Self.history))
            publish(.turnCompleted(turnID: "fixture-history", outcome: .failed("The model is overloaded. Try again in a moment.")))
            ready = true
            publish(.notice(AgentNotice(level: .info, message: "Fixture session ready.")))
            sessionStore?.setStatus(.idle, detail: String(localized: "Fixture session ready"), for: sessionID)
        }
    }

    // MARK: - AgentSessionControl

    func submit(_ prompt: String) async {
        guard isReady, turn == nil else { return }
        turnNumber += 1
        let number = turnNumber
        turn = Task { @MainActor [weak self] in
            await self?.play(prompt: prompt, number: number)
            self?.turn = nil
        }
    }

    func draft(_ prompt: String) async {
        draftHandler?(prompt)
    }

    func attach(_ attachments: [AgentAttachment]) async {
        draftHandler?(SessionImageDrop.promptFragment(relativePaths: attachments.map(\.promptPath)))
    }

    func interrupt() {
        guard let turn else { return }
        turn.cancel()
        // An interrupt withdraws the question the turn was waiting on.
        if let approval, let approvalID {
            publish(.approvalResolved(approvalID: approvalID, decision: "cancelled"))
            approval.resume(returning: "cancelled")
        }
        approval = nil
        approvalID = nil
    }

    @discardableResult
    func respond(toApproval approvalID: String, decision: String) -> Bool {
        guard let approval, approvalID == self.approvalID else { return false }
        self.approval = nil
        self.approvalID = nil
        publish(.approvalResolved(approvalID: approvalID, decision: decision))
        approval.resume(returning: decision)
        return true
    }

    func sendRaw(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        Task { await submit(text.trimmingCharacters(in: .newlines)) }
    }

    func stop(terminateServer: Bool) {
        stopped = true
        interrupt()
    }

    func prepareForApplicationTermination(terminateServer: Bool) {
        stop(terminateServer: terminateServer)
    }

    func outputSnapshot() async -> Data {
        capturedOutput
    }

    // MARK: - The script

    private func play(prompt: String, number: Int) async {
        let turnID = "fixture-turn-\(number)"
        publish(.turnStarted(turnID: turnID))
        publish(.itemCompleted(AgentItem(
            id: "\(turnID)-prompt", kind: .userMessage(text: prompt, attachments: []),
            status: .completed, native: nil)))
        sessionStore?.setStatus(.thinking, detail: String(localized: "Fixture thinking"), for: sessionID)

        let thought = "\(turnID)-thought"
        publish(.itemStarted(AgentItem(id: thought, kind: .reasoning(summary: ""), status: .inProgress, native: nil)))
        guard await stream("**Reading the request.** The prompt asks for a change; checking the tree before touching anything.", into: thought) else { return finish(turnID, .interrupted) }
        publish(.itemCompleted(AgentItem(
            id: thought,
            kind: .reasoning(summary: "**Reading the request.** The prompt asks for a change; checking the tree before touching anything."),
            status: .completed, native: nil)))

        let command = "\(turnID)-command"
        publish(.itemStarted(AgentItem(id: command, kind: .command(command: "git status --short", output: "", exitCode: nil), status: .inProgress, native: nil)))
        for line in [" M App/UI/Chat/AgentChatView.swift\n", "?? App/UI/Chat/ChatComposer.swift\n"] {
            guard await pause(6) else { return finish(turnID, .interrupted) }
            publish(.itemDelta(itemID: command, channel: .output, text: line))
        }
        publish(.itemCompleted(AgentItem(id: command, kind: .command(command: "git status --short", output: "", exitCode: 0), status: .completed, native: nil)))

        let edit = "\(turnID)-edit"
        let change = AgentFileChange(
            path: "App/UI/Chat/Greeting.swift",
            kind: .update,
            diff: AgentFileChange.replacementDiff(
                old: "struct Greeting {\n    let text = \"Hello\"\n}",
                new: "struct Greeting {\n    let text = \"Hello\"\n    let prompt: String\n}")
        )
        publish(.itemStarted(AgentItem(id: edit, kind: .fileChange([change]), status: .inProgress, native: nil)))
        publish(.approvalRequested(AgentApproval(
            id: "\(turnID)-approval", kind: .fileChange,
            title: "Edit App/UI/Chat/Greeting.swift",
            detail: "Adds the prompt to the greeting.",
            decisions: ["accept", "acceptForSession", "decline"], native: nil)))
        sessionStore?.setStatus(.waitingForPermission, detail: String(localized: "Fixture approval"), for: sessionID)
        approvalID = "\(turnID)-approval"
        let decision = await withCheckedContinuation { self.approval = $0 }
        guard !Task.isCancelled, decision != "cancelled" else { return finish(turnID, .interrupted) }
        let declined = decision == "decline"
        publish(.itemCompleted(AgentItem(id: edit, kind: .fileChange([change]), status: declined ? .declined : .completed, native: nil)))
        sessionStore?.setStatus(.running, detail: String(localized: "Writing a reply"), for: sessionID)

        let reply = "\(turnID)-reply"
        publish(.itemStarted(AgentItem(id: reply, kind: .agentMessage(text: ""), status: .inProgress, native: nil)))
        let answer = declined
            ? "Understood — I left `Greeting.swift` as it was. Nothing else in the tree changed."
            : """
            Done. `Greeting` now carries the prompt it was asked with:

            ```swift
            struct Greeting {
                let text = "Hello"
                let prompt: String
            }
            ```

            - The initialiser is synthesised, so callers pass `prompt:` explicitly.
            - Nothing else in the tree changed; `git status` showed two files before this.
            """
        guard await stream(answer, into: reply) else { return finish(turnID, .interrupted) }
        publish(.itemCompleted(AgentItem(id: reply, kind: .agentMessage(text: answer), status: .completed, native: nil)))
        finish(turnID, .completed)
    }

    private func finish(_ turnID: String, _ outcome: AgentTurnOutcome) {
        approval = nil
        publish(.turnCompleted(turnID: turnID, outcome: outcome))
        sessionStore?.setStatus(.completed, detail: String(localized: "Fixture finished"), for: sessionID)
    }

    /// Streams the text a word at a time. False when the turn was interrupted.
    private func stream(_ text: String, into itemID: String) async -> Bool {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices.dropLast() { words[index] += " " }
        for word in words {
            guard await pause(1) else { return false }
            publish(.itemDelta(itemID: itemID, channel: .text, text: word))
        }
        return true
    }

    private func pause(_ ticks: UInt64) async -> Bool {
        try? await Task.sleep(nanoseconds: delay * ticks)
        return !Task.isCancelled && !stopped
    }

    private func publish(_ event: AgentEvent) {
        hub.publish(event, sessionID: sessionID, provider: provider)
        if let text = renderer.render(event) {
            let data = Data(text.utf8)
            capturedOutput.append(data)
            terminal?.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    /// An earlier conversation, with one of everything the chat draws.
    static let history: [AgentItem] = [
        AgentItem(id: "h-user-1", kind: .userMessage(text: "Why does the sidebar flicker when a session finishes?", attachments: []), status: .completed, native: nil),
        AgentItem(id: "h-thought-1", kind: .reasoning(summary: "**Tracing the status path.** A finished session publishes twice: once from the hook, once from the exit handler."), status: .completed, native: nil),
        AgentItem(id: "h-plan-1", kind: .plan(AgentPlan(steps: [
            .init(text: "Find where a finished session publishes its status", status: .completed),
            .init(text: "Collapse the two writes into one", status: .completed),
            .init(text: "Cover it with a test", status: .inProgress),
        ])), status: .completed, native: nil),
        AgentItem(id: "h-cmd-1", kind: .command(command: "rg -n \"setStatus\\(.completed\" App", output: "App/Core/HookRouter.swift:88:        sessions.setStatus(.completed, detail: detail, for: id)\nApp/Terminal/TerminalHost.swift:512:        sessionStore.setStatus(.completed, detail: nil, for: recordID)\n", exitCode: 0), status: .completed, native: nil),
        AgentItem(id: "h-edit-1", kind: .fileChange([
            AgentFileChange(path: "App/Terminal/TerminalHost.swift", kind: .update, diff: "@@ -509,6 +509,7 @@\n         guard !deadSessions.contains(recordID) else { return }\n-        sessionStore.setStatus(.completed, detail: nil, for: recordID)\n+        // The hook already said so; a second write only redraws the row.\n+        guard sessionStore.status(of: recordID) != .completed else { return }\n         markDead(recordID)"),
        ]), status: .completed, native: nil),
        AgentItem(id: "h-tool-1", kind: .toolCall(AgentToolCall(origin: .mcp(server: "uncoil"), name: "uncoil_sessions")), status: .completed, native: .object(["action": .string("list"), "arguments": .object(["project": .string("demo")])])),
        AgentItem(id: "h-cmd-2", kind: .command(command: "swift test --filter SidebarRowReloadTests", output: "Building for debugging...\nerror: no such module 'Uncoil'\n", exitCode: 1), status: .failed, native: nil),
        AgentItem(id: "h-other-1", kind: .other(type: "webSearch"), status: .completed, native: .object(["type": .string("webSearch"), "query": .string("SwiftUI List row flicker on update")])),
        AgentItem(id: "h-reply-1", kind: .agentMessage(text: "The flicker was **two writes** for one event: the hook marked the session finished, then the exit handler wrote the same status again and the row redrew.\n\nThe exit handler now leaves a status the hook already set. The test run failed to build here — the package has no `Uncoil` module outside Xcode — so it still needs a run from the project."), status: .completed, native: nil),
        AgentItem(id: "h-user-2", kind: .userMessage(text: "Run it through xcodebuild instead.", attachments: []), status: .completed, native: nil),
    ]
}
