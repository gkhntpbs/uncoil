import Darwin
import Foundation

/// Claude Code's structured interface: `claude -p` reading and writing
/// newline-delimited JSON, with a control channel on the same pipes.
///
/// Measured against Claude Code 2.1 rather than taken from documentation:
/// - A `control_request` with `subtype: initialize` is answered before the
///   first turn; the answer is how Uncoil knows the session is live.
/// - `--permission-prompt-tool stdio` is what routes a permission prompt to
///   Uncoil as a `can_use_tool` control request. `--permission-prompts host`
///   alone does not: the CLI denies the tool itself and reports
///   `permission_denied`.
/// - An `interrupt` control request ends the turn; the turn's `result` then
///   carries `terminal_reason: aborted_streaming`.
/// - The process stays up between turns, reading the next user message.
enum ClaudeStreamProtocol {
    /// The command line for one structured session. Pure, so every choice it
    /// makes is a test away.
    static func arguments(
        record: SessionRecord,
        resume: AgentResumeDecision,
        newSessionID: String,
        mcpConfigPath: String?,
        scope: ProjectExtensionScope,
        modeArguments: [String],
        projectContext: String? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if let sid = resume.sessionID {
            arguments += ["--resume", sid]
        } else {
            // Named up front, so the record knows its conversation before the
            // first line comes back — and still knows it if the app quits first.
            arguments += ["--session-id", newSessionID]
        }
        if let mcpConfigPath {
            arguments += ["--mcp-config", mcpConfigPath]
            if !scope.excludedMCPNames.isEmpty { arguments.append("--strict-mcp-config") }
        }
        if let projectContext, !projectContext.isEmpty {
            arguments += ["--append-system-prompt", projectContext]
        }
        // The same selection flags the terminal launch uses: model, effort and
        // mode mean the same thing to `claude -p`.
        if let selection = record.launchSelection {
            arguments += AgentLaunchCatalog.launchArguments(for: .claude, selection: selection)
        }
        if record.launchSelection?.workingMode == nil {
            arguments += modeArguments
        }
        return arguments
    }

    static func initialize(requestID: String) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(["subtype": .string("initialize")]),
        ])
    }

    static func interrupt(requestID: String) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(["subtype": .string("interrupt")]),
        ])
    }

    /// A prompt, with images as images. Files are already named in the text.
    static func userMessage(
        text: String, images: [AgentAttachment], sessionID: String?
    ) -> JSONValue {
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for image in images {
            if let source = imageSource(image) {
                content.append(.object(["type": .string("image"), "source": source]))
            }
        }
        return .object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array(content)]),
            "parent_tool_use_id": .null,
            "session_id": sessionID.map(JSONValue.string) ?? .null,
        ])
    }

    /// Images Claude accepts inline, at the size its API takes.
    static let imageByteLimit = 5 * 1024 * 1024

    private static func imageSource(_ image: AgentAttachment) -> JSONValue? {
        guard image.url.isFileURL else {
            return .object(["type": .string("url"), "url": .string(image.url.absoluteString)])
        }
        let mediaType: String
        switch image.url.pathExtension.lowercased() {
        case "png": mediaType = "image/png"
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: return nil
        }
        guard let data = try? Data(contentsOf: image.url), data.count <= imageByteLimit else { return nil }
        return .object([
            "type": .string("base64"),
            "media_type": .string(mediaType),
            "data": .string(data.base64EncodedString()),
        ])
    }

    /// The answer to a `can_use_tool` request.
    ///
    /// "For this session" allows the call and hands back the rules Claude
    /// itself suggested, scoped to the session instead of the settings file
    /// it proposed: saying yes in Uncoil must not quietly rewrite the
    /// project's `.claude/settings.local.json`.
    static func permissionResponse(
        requestID: String, request: [String: JSONValue], decision: String
    ) -> JSONValue {
        let answer: JSONValue
        switch decision {
        case "accept", "acceptForSession":
            var allow: [String: JSONValue] = [
                "behavior": .string("allow"),
                "updatedInput": request["input"] ?? .object([:]),
            ]
            if decision == "acceptForSession" {
                let rules = (request["permission_suggestions"]?.arrayValue ?? [])
                    .compactMap(\.objectValue)
                    .filter { ["addRules", "addDirectories"].contains($0["type"]?.stringValue ?? "") }
                    .map { suggestion -> JSONValue in
                        var scoped = suggestion
                        scoped["destination"] = .string("session")
                        return .object(scoped)
                    }
                if !rules.isEmpty { allow["updatedPermissions"] = .array(rules) }
            }
            answer = .object(allow)
        default:
            answer = .object([
                "behavior": .string("deny"),
                "message": .string("The user declined this in Uncoil."),
            ])
        }
        return .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": answer,
            ]),
        ])
    }

    /// A control request Uncoil does not serve still gets an answer, so the
    /// CLI never waits on one.
    static func unsupported(requestID: String, subtype: String) -> JSONValue {
        .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("error"),
                "request_id": .string(requestID),
                "error": .string("Uncoil does not handle \(subtype) requests."),
            ]),
        ])
    }

    static func line(_ value: JSONValue) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

// MARK: - Transport

/// The pipes a structured Claude session talks over. A protocol so a session
/// can be driven line by line in a test, with no CLI and no account.
@MainActor
protocol ClaudeStreamTransport: AnyObject {
    /// One complete stdout line, without its newline, in order.
    var onLine: ((Data) -> Void)? { get set }
    /// The process ended: its exit code and the end of what it wrote to stderr.
    var onExit: ((Int32, String) -> Void)? { get set }
    func start() throws
    func send(_ line: Data) throws
    func terminate()
}

/// `claude -p` as a child process on plain pipes. No PTY: nothing here is a
/// terminal, and a PTY would echo, wrap and mangle the JSON.
@MainActor
final class ClaudeProcessTransport: ClaudeStreamTransport {
    var onLine: ((Data) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var buffer = Data()
    private var errorTail = Data()

    init(executable: String, arguments: [String], directory: String, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing to a pipe whose reader has exited raises SIGPIPE, and its
        // default action ends Uncoil, not Claude. With this the write fails
        // with EPIPE instead, and `send` reports it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        // Read off the main thread, delivered on it in order.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receivedError(data) }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            DispatchQueue.main.async { self?.exited(code) }
        }
        try process.run()
    }

    func send(_ line: Data) throws {
        guard process.isRunning else {
            throw ClaudeStreamError.notRunning
        }
        try stdin.fileHandleForWriting.write(contentsOf: line)
    }

    func terminate() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        onLine = nil
        onExit = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(...newline)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }

    private func receivedError(_ data: Data) {
        errorTail.append(data)
        if errorTail.count > 4096 { errorTail.removeFirst(errorTail.count - 4096) }
    }

    private func exited(_ code: Int32) {
        // What is still in the pipe was written before the exit.
        received(stdout.fileHandleForReading.readDataToEndOfFile())
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let tail = String(decoding: errorTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onExit?(code, tail)
    }
}

enum ClaudeStreamError: LocalizedError {
    case notRunning
    case exited(Int32, String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "The structured Claude session is not running."
        case .exited(let code, let detail):
            detail.isEmpty
                ? "Claude exited with code \(code)."
                : "Claude exited with code \(code): \(detail.split(separator: "\n").last ?? "")"
        }
    }
}
