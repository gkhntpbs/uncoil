import Darwin
import Foundation

/// uncoil-mcp — a stdio MCP (Model Context Protocol) server bundled into
/// Uncoil.app and registered with agent CLIs per session.
///
/// JSON-RPC 2.0 over newline-delimited stdin/stdout. Handles `initialize`,
/// `tools/list`, `tools/call`, `ping` and `notifications/cancelled`. Every
/// `tools/call` forwards `{capability, action, args, caller_session_id,
/// session_token}` as one line-JSON request to the in-app control plane over
/// UNCOIL_CONTROL_SOCKET and returns the app's JSON response envelope verbatim
/// as the tool result text.
///
/// Provider-neutral by construction: the same binary, the same tools and the
/// same environment names serve every agent. Who is calling is read from the
/// environment at runtime; the provider's own config only decides how that
/// environment arrives.
///
/// Calls run concurrently. The stdin loop never waits on the app, so a long
/// `wait_for_children` does not stop the server from reading the client's
/// next call — or its cancellation, which closes that call's socket; the app
/// sees the hang-up and cancels the work.
///
/// Env: UNCOIL_SESSION_ID, UNCOIL_SESSION_TOKEN, UNCOIL_PROJECT_ID,
/// UNCOIL_CONTROL_SOCKET.

/// MCP revisions this server answers in, newest first. A client asking for
/// one of these gets it; anything else gets the newest.
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let serverVersion = "\(ControlProtocol.version).0.0"
let clientName = "uncoil-mcp/\(ControlProtocol.version)"

let env = ProcessInfo.processInfo.environment
let callerSessionID = env[ControlProtocol.Environment.sessionID].flatMap { $0.isEmpty ? nil : $0 }
let sessionToken = env[ControlProtocol.Environment.sessionToken].flatMap { $0.isEmpty ? nil : $0 }
let controlSocketPath = env[ControlProtocol.Environment.controlSocket]

let instructions = """
Uncoil's control plane. One tool per domain; every call is {"action": ..., ...}. \
Call {"action":"help"} on a tool for its actions, or uncoil_system {"action":"describe"} \
for the whole contract. Prefer structured session actions (capabilities, timeline, \
events, submit) over reading terminal output.
"""

// MARK: - Tool catalogue (kept small; full docs live behind the `help` action)

struct ToolDef { let name: String; let description: String }

let tools: [ToolDef] = [
    ToolDef(name: "uncoil_sessions",
            description: "Inspect agent sessions and what each supports, read structured timelines and events, submit prompts, interrupt turns, answer approvals, and create sessions with a chosen agent, account, model and effort. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_agents",
            description: "Discover the agents Uncoil can run: installed providers, their accounts, and the models, efforts and working modes each offers. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_projects",
            description: "Inspect Uncoil projects and their git worktrees, create new worktrees, and read or write the project blueprints a new project can be set up from. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_artifacts",
            description: "List, read, and register text artifacts inside session artifact roots. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_tasks",
            description: "Read and update the project's TODO.md-backed task board: list/inspect tasks, claim and update status, and (with opt-in grants) orchestrate agents, worktrees and merges. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_run",
            description: "Project run / dev preview: detect the project's dev workflows into the repo-owned .uncoil/run.json, then start/stop/restart them, read structured status and log tails, and repair configurations. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_system",
            description: "Report Uncoil control-plane status, version, the full contract (describe), granted capabilities, and health diagnostics. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_browser",
            description: "Drive an isolated headless browser (open, snapshot, click element refs, fill, screenshot) via the optional agent-browser CLI; needs the browser.use grant. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_computer",
            description: "Inspect and control native macOS apps through a per-session window binding via the optional cua-driver CLI; graded computer.inspect/background_control/foreground_control grants. Call {\"action\":\"help\"} for full documentation."),
]

// MARK: - stdout

let stdoutLock = NSLock()

func writeMessage(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    data.append(UInt8(ascii: "\n"))
    // Calls finish on their own threads; one line at a time, whole.
    stdoutLock.lock()
    FileHandle.standardOutput.write(data)
    stdoutLock.unlock()
}

func respond(id: Any, result: [String: Any]) {
    writeMessage(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(id: Any, code: Int, message: String) {
    writeMessage(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

// MARK: - In-flight calls

/// Calls being answered, by JSON-RPC id, so a cancellation can find the
/// socket to close.
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [String: Int32] = [:]
    private var cancelled: Set<String> = []

    /// False when the call was cancelled before it got a socket.
    func register(_ key: String, fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled.contains(key) else { return false }
        sockets[key] = fd
        return true
    }

    func cancel(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        cancelled.insert(key)
        // Wakes the blocked read and tells the app nobody is listening.
        if let fd = sockets[key] { shutdown(fd, SHUT_RDWR) }
    }

    /// Ends the call; true when it was cancelled and must not be answered.
    func finish(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sockets[key] = nil
        return cancelled.remove(key) != nil
    }
}

let inFlight = InFlight()
let callQueue = DispatchQueue(label: "uncoil-mcp.calls", attributes: .concurrent)

func rpcKey(_ id: Any) -> String {
    if let number = id as? NSNumber { return "n:\(number.stringValue)" }
    return "s:\(id)"
}

// MARK: - Control-plane forwarding

/// A structured error envelope produced locally when the control plane can't
/// be reached (mirrors the app's ControlEnvelope error shape).
func errorEnvelopeText(capability: String, action: String, code: String, message: String, retryable: Bool) -> String {
    let envelope: [String: Any] = [
        "ok": false,
        "capability": capability,
        "action": action,
        "request_id": UUID().uuidString,
        "caller_session_id": callerSessionID as Any,
        "artifacts": [],
        "warnings": [],
        "next_actions": [],
        "error": ["code": code, "message": message, "retryable": retryable],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

/// How long to wait for the app: `ControlProtocol.callTimeout`, read from the
/// same arguments the app will see.
func callTimeout(_ args: [String: Any]) -> TimeInterval {
    let decoded = (try? JSONSerialization.data(withJSONObject: args))
        .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
    return ControlProtocol.callTimeout(args: decoded)
}

/// Connects, sends one request line, reads one response line. Returns the raw
/// response JSON, or a locally made error envelope on failure.
func forwardToControlPlane(
    key: String, capability: String, action: String, args: [String: Any]
) -> (text: String, isError: Bool) {
    func failure(_ code: String, _ message: String, retryable: Bool) -> (String, Bool) {
        (errorEnvelopeText(capability: capability, action: action, code: code,
                           message: message, retryable: retryable), true)
    }
    guard let path = controlSocketPath, !path.isEmpty else {
        return failure("CONTROL_PLANE_UNAVAILABLE", "UNCOIL_CONTROL_SOCKET is not set", retryable: false)
    }

    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return failure("CONTROL_PLANE_UNAVAILABLE", "socket() failed", retryable: true) }
    defer { close(sock) }
    guard inFlight.register(key, fd: sock) else {
        return failure("CANCELLED", "the request was cancelled", retryable: false)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        return failure("CONTROL_PLANE_UNAVAILABLE", "socket path too long", retryable: false)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        return failure("CONTROL_PLANE_UNAVAILABLE", "cannot reach Uncoil control plane", retryable: true)
    }

    let limit = callTimeout(args)
    var timeout = timeval(tv_sec: Int(limit), tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var request: [String: Any] = [
        "version": ControlProtocol.version,
        "capability": capability,
        "action": action,
        "args": args,
        "client": clientName,
        "request_id": UUID().uuidString,
    ]
    if let callerSessionID { request["caller_session_id"] = callerSessionID }
    if let sessionToken { request["session_token"] = sessionToken }
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
        return failure("INVALID_ARGUMENT", "could not encode request", retryable: false)
    }
    payload.append(UInt8(ascii: "\n"))
    let writeOK = payload.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let written = write(sock, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
    guard writeOK else { return failure("CONTROL_PLANE_UNAVAILABLE", "write failed", retryable: true) }

    // Read one newline-terminated response.
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(sock, &chunk, chunk.count)
        if count > 0 {
            response.append(contentsOf: chunk[0..<count])
            if response.last == UInt8(ascii: "\n") { break }
        } else if count == 0 {
            break
        } else {
            if errno == EINTR { continue }
            // errno EAGAIN/EWOULDBLOCK from SO_RCVTIMEO ⇒ timeout.
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return failure("TIMEOUT", "control plane did not respond within \(Int(limit))s", retryable: true)
            }
            break
        }
    }
    guard !response.isEmpty else {
        return failure("CONTROL_PLANE_UNAVAILABLE", "empty response", retryable: true)
    }
    let text = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    var isError = false
    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
       let ok = obj["ok"] as? Bool {
        isError = !ok
    }
    return (text, isError)
}

// MARK: - JSON-RPC dispatch

func handleToolsCall(id: Any, params: [String: Any]) {
    guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
        respondError(id: id, code: -32602, message: "unknown tool")
        return
    }
    let arguments = (params["arguments"] as? [String: Any]) ?? [:]
    let action = (arguments["action"] as? String) ?? "help"
    var args = arguments
    args.removeValue(forKey: "action")

    let key = rpcKey(id)
    callQueue.async {
        let result = forwardToControlPlane(key: key, capability: name, action: action, args: args)
        // A cancelled call gets no response: the client has already moved on.
        guard !inFlight.finish(key) else { return }
        respond(id: id, result: [
            "content": [["type": "text", "text": result.text]],
            "isError": result.isError,
        ])
    }
}

func toolListEntry(_ tool: ToolDef) -> [String: Any] {
    [
        "name": tool.name,
        "description": tool.description,
        "inputSchema": [
            "type": "object",
            "properties": ["action": ["type": "string", "description": "The operation to perform."]],
            "required": ["action"],
            "additionalProperties": true,
        ],
    ]
}

func dispatch(_ message: [String: Any]) {
    let method = message["method"] as? String
    let id = message["id"]

    // Notifications carry no id and expect no reply.
    guard let id else {
        if method == "notifications/cancelled",
           let params = message["params"] as? [String: Any],
           let requestID = params["requestId"] {
            inFlight.cancel(rpcKey(requestID))
        }
        return
    }
    guard let method else {
        respondError(id: id, code: -32600, message: "missing method")
        return
    }

    switch method {
    case "initialize":
        let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        let version = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? supportedProtocolVersions[0]
        respond(id: id, result: [
            "protocolVersion": version,
            "serverInfo": ["name": "uncoil", "version": serverVersion],
            "capabilities": ["tools": [:] as [String: Any]],
            "instructions": instructions,
        ])
    case "tools/list":
        respond(id: id, result: ["tools": tools.map(toolListEntry)])
    case "tools/call":
        handleToolsCall(id: id, params: (message["params"] as? [String: Any]) ?? [:])
    case "ping":
        respond(id: id, result: [:])
    default:
        respondError(id: id, code: -32601, message: "method not found: \(method)")
    }
}

// MARK: - stdin loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue
    }
    dispatch(message)
}

// stdin closed: let calls already on their way finish writing.
callQueue.sync(flags: .barrier) {}
