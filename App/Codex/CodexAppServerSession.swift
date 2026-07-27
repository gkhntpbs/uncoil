import AppKit
import Darwin
import Foundation
import SwiftTerm

@MainActor
final class CodexAppServerSession {
    let recordID: UUID

    private let record: SessionRecord
    private let project: Project
    private let binaryPath: String
    private let environment: [String: String]
    private let config: JSONValue
    private let approvalPolicy: String
    private let sandbox: String
    private weak var terminal: TerminalView?
    private weak var settings: SettingsStore?
    private weak var sessionStore: SessionStore?
    private weak var projectStore: ProjectStore?
    private let fallback: (String) -> Void
    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var transport: CodexUnixWebSocket?
    private var receiveBuffer = Data()
    private var nextRequestID = 1
    private var continuations: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var threadID: String?
    private var activeTurnID: String?
    private var streamedAgentItems: Set<String> = []
    private var startedItems: Set<String> = []
    private var streamedOutputItems: Set<String> = []
    private var capturedOutput = Data()
    private var stopped = false
    private var ready = false
    private var reconnectingExistingServer = false
    private var restartedStaleServer = false
    private let socketURL: URL
    private let pidURL: URL
    private let logURL: URL

    init(
        record: SessionRecord,
        project: Project,
        binaryPath: String,
        environment: [String: String],
        config: JSONValue,
        approvalPolicy: String,
        sandbox: String,
        terminal: TerminalView,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore,
        fallback: @escaping (String) -> Void
    ) {
        recordID = record.id
        self.record = record
        self.project = project
        self.binaryPath = binaryPath
        self.environment = environment
        self.config = config
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.terminal = terminal
        self.settings = settings
        self.sessionStore = sessionStore
        self.projectStore = projectStore
        self.fallback = fallback
        let directory = ProjectStore.defaultDirectory()
            .appendingPathComponent("cas", isDirectory: true)
            .appendingPathComponent(String(record.id.uuidString.prefix(8)), isDirectory: true)
        socketURL = directory.appendingPathComponent("s.sock")
        pidURL = directory.appendingPathComponent("server.pid")
        logURL = directory.appendingPathComponent("server.log")
    }

    func start() {
        feed("\u{001B}[2mCodex app-server denetleniyor…\u{001B}[0m\r\n")
        let binaryPath = binaryPath
        let environment = environment
        Task {
            let compatibility = await Task.detached(priority: .utility) {
                Self.probeCompatibility(binaryPath: binaryPath, environment: environment)
            }.value
            guard !stopped else { return }
            guard compatibility.isSupported else {
                failToFallback(CodexAppServerProtocolError.incompatibleVersion(compatibility.version))
                return
            }
            launch()
        }
    }

    func submit(_ text: String) {
        guard ready, let threadID else {
            feed("\r\n\u{001B}[31mThe structured Codex session is not ready yet.\u{001B}[0m\r\n")
            return
        }
        sessionStore?.setStatus(.thinking, detail: String(localized: "Codex thinking"), for: recordID)
        Task {
            do {
                let result = try await request(
                    method: "turn/start",
                    params: .object([
                        "threadId": .string(threadID),
                        "input": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(text),
                            ]),
                        ]),
                    ])
                )
                activeTurnID = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue
            } catch {
                display(error)
            }
        }
    }

    func interrupt() {
        guard ready, let threadID, let activeTurnID else { return }
        Task {
            do {
                _ = try await request(
                    method: "turn/interrupt",
                    params: .object([
                        "threadId": .string(threadID),
                        "turnId": .string(activeTurnID),
                    ])
                )
            } catch {
                display(error)
            }
        }
    }

    func respondToApproval(_ request: CodexApprovalRequest, decision: String) {
        guard request.sessionID == recordID else { return }
        let result: JSONValue
        if request.kind == .permissions {
            result = .object([
                "permissions": decision == "decline" ? .object([:]) : (request.permissions ?? .object([:])),
                "scope": .string(decision == "acceptForSession" ? "session" : "turn"),
            ])
        } else {
            result = .object(["decision": .string(decision)])
        }
        do {
            try write(CodexAppServerJSON.response(id: request.requestID, result: result))
            sessionStore?.setCodexApproval(nil, for: recordID)
            sessionStore?.setStatus(.running, detail: String(localized: "Approval answered"), for: recordID)
        } catch {
            display(error)
        }
    }

    func stop(terminateServer: Bool = true) {
        stopped = true
        transport?.onClose = nil
        transport?.close()
        transport = nil
        if terminateServer {
            terminatePersistentServer()
        } else {
            // The server keeps running, but this session is done with it: the
            // open log handle and the Process reference would otherwise live
            // for the rest of the app.
            try? serverLogHandle?.close()
            serverLogHandle = nil
            serverProcess = nil
        }
        continuations.values.forEach {
            $0.resume(throwing: CodexAppServerProtocolError.server("Codex app-server shut down."))
        }
        continuations.removeAll()
    }

    func prepareForApplicationTermination(terminateServer: Bool) {
        stop(terminateServer: terminateServer)
        if terminateServer {
            projectStore?.markSessionEnded(recordID, exitCode: 0)
        }
    }

    func outputSnapshot() async -> Data {
        capturedOutput
    }

    private func launch() {
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            failToFallback(error)
            return
        }
        if FileManager.default.fileExists(atPath: socketURL.path) {
            reconnectingExistingServer = true
            Task { await connectSocket() }
        } else {
            launchServer()
        }
    }

    private func launchServer() {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binaryPath)
        server.arguments = ["app-server", "--listen", "unix://\(socketURL.path)"]
        server.currentDirectoryURL = URL(fileURLWithPath: record.workingDirectory(in: project))
        server.environment = environment
        server.standardInput = FileHandle.nullDevice
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            server.standardOutput = log
            server.standardError = log
            server.terminationHandler = { [weak self] process in
                Task { @MainActor in self?.serverTerminated(code: process.terminationStatus) }
            }
            try server.run()
            serverProcess = server
            serverLogHandle = log
            try Data(String(server.processIdentifier).utf8).write(to: pidURL, options: .atomic)
            Task { await waitForSocket() }
        } catch {
            failToFallback(CodexAppServerProtocolError.processLaunch(error.localizedDescription))
        }
    }

    private func waitForSocket() async {
        for _ in 0..<100 {
            guard !stopped else { return }
            if FileManager.default.fileExists(atPath: socketURL.path) {
                await connectSocket()
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        failToFallback(CodexAppServerProtocolError.processLaunch("Codex app-server created no socket."))
    }

    private func connectSocket() async {
        do {
            let transport = try await CodexUnixWebSocket.connect(path: socketURL.path)
            guard !stopped else {
                transport.close()
                return
            }
            self.transport = transport
            transport.onMessage = { [weak self] data in
                var line = data
                line.append(0x0A)
                self?.receive(line)
            }
            transport.onClose = { [weak self] in
                self?.transportClosed()
            }
            Task { await initialize() }
        } catch {
            if reconnectingExistingServer, !restartedStaleServer {
                restartedStaleServer = true
                reconnectingExistingServer = false
                terminatePersistentServer()
                launchServer()
            } else {
                failToFallback(CodexAppServerProtocolError.processLaunch(error.localizedDescription))
            }
        }
    }

    private func initialize() async {
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("uncoil"),
                        "title": .string("Uncoil"),
                        "version": .string(version),
                    ]),
                ])
            )
            try write(CodexAppServerJSON.notification(method: "initialized"))
            async let account: Void = readAccount()
            try await openThread()
            await account
            ready = true
            feed("\u{001B}[2mStructured Codex ready.\u{001B}[0m\r\n")
            sessionStore?.setStatus(.idle, detail: String(localized: "Structured Codex ready"), for: recordID)
        } catch {
            failToFallback(error)
        }
    }

    private func readAccount() async {
        do {
            let result = try await request(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            applyAccount(result)
        } catch {
            sessionStore?.setCodexAuthentication(.error(error.localizedDescription), for: recordID)
        }
    }

    private func openThread() async throws {
        var params: [String: JSONValue] = [
            "cwd": .string(record.workingDirectory(in: project)),
            "approvalPolicy": .string(approvalPolicy),
            "approvalsReviewer": .string("user"),
            "sandbox": .string(sandbox),
            "config": config,
        ]
        let method: String
        if let providerSessionID = record.providerSessionID {
            method = "thread/resume"
            params["threadId"] = .string(providerSessionID)
            params["initialTurnsPage"] = .object([
                "limit": .int(50),
                "itemsView": .string("full"),
                "sortDirection": .string("asc"),
            ])
        } else {
            method = "thread/start"
        }
        let result = try await request(method: method, params: .object(params))
        guard let id = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerProtocolError.invalidResponse
        }
        threadID = id
        _ = projectStore?.claimProviderSessionID(id, for: recordID)
        let history = CodexStructuredFormatter.history(from: result)
        if !history.isEmpty {
            feed(history)
        }
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            do {
                try write(CodexAppServerJSON.data(id: id, method: method, params: params))
            } catch {
                continuations.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ data: Data) throws {
        guard let transport else {
            throw CodexAppServerProtocolError.processLaunch("Codex app-server socket is unavailable.")
        }
        var payload = data
        if payload.last == 0x0A {
            payload.removeLast()
        }
        try transport.send(payload)
    }

    private func receive(_ data: Data) {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let message = try CodexAppServerMessage(data: Data(line))
                handle(message)
            } catch {
                display(error)
            }
        }
    }

    private func handle(_ message: CodexAppServerMessage) {
        if let id = message.id?.intValue, let continuation = continuations.removeValue(forKey: id) {
            if let error = message.error {
                continuation.resume(throwing: CodexAppServerProtocolError.server(serverError(error)))
            } else {
                continuation.resume(returning: message.result ?? .null)
            }
            return
        }
        if let method = message.method, message.id != nil {
            handleApproval(method: method, id: message.id!, params: message.params ?? .object([:]))
            return
        }
        guard let method = message.method else { return }
        let params = message.params ?? .object([:])
        switch method {
        case "thread/started":
            if let id = params.objectValue?["thread"]?.objectValue?["id"]?.stringValue {
                threadID = id
                _ = projectStore?.claimProviderSessionID(id, for: recordID)
            }
        case "thread/status/changed":
            applyThreadStatus(params)
        case "turn/started":
            activeTurnID = params.objectValue?["turn"]?.objectValue?["id"]?.stringValue
            // Per-turn item bookkeeping; an interrupted or failed turn never
            // delivers item/completed for its members, so these are reset at
            // the turn boundaries rather than trusted to drain themselves.
            streamedAgentItems.removeAll()
            startedItems.removeAll()
            streamedOutputItems.removeAll()
            sessionStore?.setStatus(.thinking, detail: String(localized: "Codex thinking"), for: recordID)
        case "turn/completed":
            activeTurnID = nil
            streamedAgentItems.removeAll()
            startedItems.removeAll()
            streamedOutputItems.removeAll()
            let status = params.objectValue?["turn"]?.objectValue?["status"]?.stringValue
            if status == "failed" {
                sessionStore?.setStatus(.completed, detail: String(localized: "Codex turn failed"), for: recordID)
                feed("\r\n\u{001B}[31mTurn failed.\u{001B}[0m\r\n")
            } else {
                sessionStore?.setStatus(.completed, detail: String(localized: "Codex finished"), for: recordID)
            }
        case "item/started":
            handleItemStarted(params)
        case "item/completed":
            handleItemCompleted(params)
        case "item/agentMessage/delta":
            if let delta = params.objectValue?["delta"]?.stringValue {
                if let itemID = params.objectValue?["itemId"]?.stringValue {
                    streamedAgentItems.insert(itemID)
                }
                feed(delta)
                sessionStore?.setStatus(.running, detail: String(localized: "Writing a reply"), for: recordID)
            }
        case "item/commandExecution/outputDelta":
            if let delta = params.objectValue?["delta"]?.stringValue {
                if let itemID = params.objectValue?["itemId"]?.stringValue {
                    streamedOutputItems.insert(itemID)
                }
                feed(delta)
            }
        case "account/updated":
            applyAccount(params)
        default:
            break
        }
    }

    private func handleApproval(method: String, id: JSONValue, params: JSONValue) {
        let kind: CodexApprovalKind
        let title: String
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command
            title = params.objectValue?["command"]?.stringValue ?? "Command run request"
        case "item/fileChange/requestApproval":
            kind = .fileChange
            title = String(localized: "File change request")
        case "item/permissions/requestApproval":
            kind = .permissions
            title = String(localized: "Additional permission request")
        default:
            do {
                try write(CodexAppServerJSON.response(id: id, result: .object(["decision": .string("decline")])))
            } catch {
                display(error)
            }
            return
        }
        let object = params.objectValue ?? [:]
        let itemID = object["itemId"]?.stringValue ?? UUID().uuidString
        let decisions = object["availableDecisions"]?.arrayValue?
            .compactMap(\.stringValue)
            ?? ["accept", "acceptForSession", "decline"]
        let request = CodexApprovalRequest(
            id: "\(itemID)-\(id.displayString ?? "")",
            sessionID: recordID,
            requestID: id,
            kind: kind,
            title: title,
            detail: object["reason"]?.stringValue ?? object["cwd"]?.stringValue,
            permissions: object["permissions"],
            availableDecisions: decisions
        )
        sessionStore?.setCodexApproval(request, for: recordID)
        sessionStore?.setStatus(.waitingForPermission, detail: title, for: recordID)
        PermissionNotificationCenter.shared.post(request, projectID: record.projectID)
    }

    private func handleItemStarted(_ params: JSONValue) {
        guard let item = params.objectValue?["item"] else { return }
        if let itemID = CodexStructuredFormatter.itemID(item) {
            startedItems.insert(itemID)
        }
        if let output = CodexStructuredFormatter.startedItem(item) {
            feed(output)
        }
        let type = item.objectValue?["type"]?.stringValue
        let detail: String
        switch type {
        case "commandExecution":
            detail = String(localized: "Running a command")
        case "fileChange":
            detail = String(localized: "Changing files")
        case "mcpToolCall":
            detail = String(localized: "Running an MCP tool")
        case "dynamicToolCall", "collabAgentToolCall":
            detail = String(localized: "Running a tool")
        case "reasoning":
            sessionStore?.setStatus(.thinking, detail: String(localized: "Codex thinking"), for: recordID)
            return
        default:
            detail = String(localized: "Codex running")
        }
        sessionStore?.setStatus(.running, detail: detail, for: recordID)
    }

    private func handleItemCompleted(_ params: JSONValue) {
        guard let item = params.objectValue?["item"] else { return }
        let itemID = CodexStructuredFormatter.itemID(item)
        let streamed = itemID.map { streamedAgentItems.remove($0) != nil } ?? false
        let type = item.objectValue?["type"]?.stringValue
        if let itemID, startedItems.remove(itemID) != nil {
            if type == "commandExecution",
               streamedOutputItems.remove(itemID) == nil,
               let output = item.objectValue?["aggregatedOutput"]?.stringValue,
               !output.isEmpty {
                feed(output.hasSuffix("\n") ? output : output + "\r\n")
            }
            if type != "agentMessage" && type != "fileChange" {
                return
            }
        }
        if let output = CodexStructuredFormatter.completedItem(item, agentMessageWasStreamed: streamed) {
            feed(output)
        }
    }

    private func applyThreadStatus(_ params: JSONValue) {
        let status = params.objectValue?["status"]?.stringValue
            ?? params.objectValue?["thread"]?.objectValue?["status"]?.stringValue
        switch status {
        case "active":
            sessionStore?.setStatus(.running, detail: String(localized: "Codex running"), for: recordID)
        case "idle":
            sessionStore?.setStatus(.idle, detail: String(localized: "Structured Codex ready"), for: recordID)
        case "systemError":
            sessionStore?.setStatus(.completed, detail: String(localized: "Codex system error"), for: recordID)
        default:
            break
        }
    }

    private func applyAccount(_ value: JSONValue) {
        let object = value.objectValue ?? [:]
        if let account = object["account"]?.objectValue {
            let label = account["email"]?.stringValue ?? account["type"]?.stringValue
            sessionStore?.setCodexAuthentication(.authenticated(label), for: recordID)
            return
        }
        if object["requiresOpenaiAuth"]?.boolValue == true {
            sessionStore?.setCodexAuthentication(.required, for: recordID)
            sessionStore?.setStatus(.waitingForInput, detail: String(localized: "Codex login required"), for: recordID)
        } else {
            sessionStore?.setCodexAuthentication(.authenticated(nil), for: recordID)
        }
    }

    private func transportClosed() {
        guard !stopped else { return }
        if ready {
            sessionStore?.setStatus(.terminated, detail: String(localized: "Codex app-server connection closed"), for: recordID)
            projectStore?.markSessionEnded(recordID, exitCode: nil)
            TerminalRegistry.shared.markDead(recordID)
        } else {
            failToFallback(CodexAppServerProtocolError.processLaunch("The Codex app-server connection closed."))
        }
    }

    private func serverTerminated(code: Int32) {
        guard !stopped else { return }
        transport?.onClose = nil
        transport?.close()
        transport = nil
        failToFallback(
            CodexAppServerProtocolError.processLaunch("Codex app-server closed with code \(code).")
        )
    }

    private func failToFallback(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        transport?.onClose = nil
        transport?.close()
        transport = nil
        terminatePersistentServer()
        continuations.values.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
        let message = error.localizedDescription
        feed("\r\n\u{001B}[33m\(message) Starting the PTY fallback.\u{001B}[0m\r\n")
        fallback(message)
    }

    private func display(_ error: Error) {
        feed("\r\n\u{001B}[31m\(error.localizedDescription)\u{001B}[0m\r\n")
        sessionStore?.setStatus(.completed, detail: error.localizedDescription, for: recordID)
    }

    private func feed(_ text: String) {
        let data = Data(text.utf8)
        capturedOutput.append(data)
        if capturedOutput.count > 262_144 {
            capturedOutput.removeFirst(capturedOutput.count - 262_144)
        }
        if let settings {
            settings.transcriptStore.append(
                data,
                sessionID: recordID,
                policy: settings.transcriptRetentionPolicy
            )
        }
        terminal?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    private func serverError(_ value: JSONValue) -> String {
        value.objectValue?["message"]?.stringValue
            ?? value.displayString
            ?? "Codex app-server error"
    }

    private func terminatePersistentServer() {
        if serverProcess?.isRunning == true {
            serverProcess?.terminate()
        } else if let data = try? Data(contentsOf: pidURL),
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let pid = Int32(value),
                  pid > 1,
                  isExpectedServerProcess(pid) {
            Darwin.kill(pid, SIGTERM)
        }
        try? serverLogHandle?.close()
        serverLogHandle = nil
        removeServerFiles()
    }

    private func removeServerFiles() {
        try? FileManager.default.removeItem(at: socketURL)
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func isExpectedServerProcess(_ pid: Int32) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let command = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            return command.contains(binaryPath)
                && command.contains("app-server")
                && command.contains(socketURL.path)
        } catch {
            return false
        }
    }

    nonisolated private static func probeCompatibility(
        binaryPath: String,
        environment: [String: String]
    ) -> CodexAppServerCompatibility {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return CodexAppServerCompatibility.evaluate(String(decoding: data, as: UTF8.self))
        } catch {
            return CodexAppServerCompatibility(version: error.localizedDescription, isSupported: false)
        }
    }
}

final class CodexStructuredTerminalDelegate: TerminalViewDelegate {
    private weak var session: CodexAppServerSession?
    private weak var terminal: TerminalView?
    private var editor = PromptLineEditor()

    init(session: CodexAppServerSession, terminal: TerminalView) {
        self.session = session
        self.terminal = terminal
    }

    /// Puts a dispatched prompt into the line editor without submitting it, so
    /// the user starts the turn themselves.
    func prefill(_ text: String) {
        editor.prefill(text)
        redraw()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let actions = editor.consume(data)
        redraw()
        for action in actions {
            switch action {
            case .interrupt:
                Task { @MainActor [weak session] in session?.interrupt() }
            case .submit(let prompt):
                echo("\r\n")
                Task { @MainActor [weak session] in session?.submit(prompt) }
            }
        }
    }

    /// Repaints the prompt line from the editor's state, which is what lets an
    /// edit happen anywhere in the line rather than only at its end.
    private func redraw() {
        echo(PromptLineRenderer.render(text: editor.text, cursor: editor.cursor))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    private func echo(_ text: String) {
        terminal?.feed(byteArray: ArraySlice([UInt8](text.utf8)))
    }
}
