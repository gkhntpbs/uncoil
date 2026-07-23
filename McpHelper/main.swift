import Darwin
import Foundation

/// uncoil-mcp — a stdio MCP (Model Context Protocol) server bundled into
/// Uncoil.app and registered with agent CLIs per session.
///
/// JSON-RPC 2.0 over newline-delimited stdin/stdout. Handles `initialize`,
/// `tools/list`, `tools/call`; ignores notifications. Every `tools/call`
/// forwards `{capability, action, args, caller_session_id}` as one line-JSON
/// request to the in-app control plane over UNCOIL_CONTROL_SOCKET and returns
/// the app's JSON response envelope verbatim as the tool result text.
///
/// Env: UNCOIL_SESSION_ID, UNCOIL_PROJECT_ID, UNCOIL_CONTROL_SOCKET.

let protocolVersion = "2025-06-18"
let serverVersion = "0.1.0"

let env = ProcessInfo.processInfo.environment
let callerSessionID = env["UNCOIL_SESSION_ID"]
let controlSocketPath = env["UNCOIL_CONTROL_SOCKET"]

// MARK: - Tool catalogue (kept small; full docs live behind the `help` action)

struct ToolDef { let name: String; let description: String }

let tools: [ToolDef] = [
    ToolDef(name: "uncoil_projects",
            description: "Inspect Uncoil projects and their git worktrees, and create new worktrees. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_sessions",
            description: "Inspect agent sessions, read their output, spawn and coordinate child sessions from presets, and (for direct children) send input or stop them. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_artifacts",
            description: "List, read, and register text artifacts inside session artifact roots. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_system",
            description: "Report Uncoil control-plane status, version, granted capabilities, and health diagnostics. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_browser",
            description: "Drive an isolated headless browser (open, snapshot, click element refs, fill, screenshot) via the optional agent-browser CLI; needs the browser.use grant. Call {\"action\":\"help\"} for full documentation."),
    ToolDef(name: "uncoil_computer",
            description: "Inspect and control native macOS apps through a per-session window binding via the optional cua-driver CLI; graded computer.inspect/background_control/foreground_control grants. Call {\"action\":\"help\"} for full documentation."),
]

// MARK: - stdout

let stdoutHandle = FileHandle.standardOutput

func writeMessage(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    data.append(UInt8(ascii: "\n"))
    stdoutHandle.write(data)
}

func respond(id: Any, result: [String: Any]) {
    writeMessage(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(id: Any, code: Int, message: String) {
    writeMessage(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
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

/// Connects, sends one request line, reads one response line. Returns the raw
/// response JSON, or nil on connect/timeout failure (caller substitutes an
/// error envelope).
func forwardToControlPlane(capability: String, action: String, args: [String: Any]) -> (text: String, isError: Bool) {
    guard let path = controlSocketPath, !path.isEmpty else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "UNCOIL_CONTROL_SOCKET is not set", retryable: false), true)
    }

    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "socket() failed", retryable: true), true)
    }
    defer { close(sock) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "socket path too long", retryable: false), true)
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
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "cannot reach Uncoil control plane", retryable: true), true)
    }

    // 30s receive timeout → typed TIMEOUT error.
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var request: [String: Any] = [
        "version": 1,
        "capability": capability,
        "action": action,
        "args": args,
        "request_id": UUID().uuidString,
    ]
    if let callerSessionID { request["caller_session_id"] = callerSessionID }
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "INVALID_ARGUMENT", message: "could not encode request", retryable: false), true)
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
    guard writeOK else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "write failed", retryable: true), true)
    }

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
            // errno EAGAIN/EWOULDBLOCK from SO_RCVTIMEO ⇒ timeout.
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return (errorEnvelopeText(capability: capability, action: action,
                    code: "TIMEOUT", message: "control plane did not respond within 30s", retryable: true), true)
            }
            break
        }
    }
    guard !response.isEmpty else {
        return (errorEnvelopeText(capability: capability, action: action,
            code: "CONTROL_PLANE_UNAVAILABLE", message: "empty response", retryable: true), true)
    }
    let text = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    // Determine isError from the envelope's `ok` field.
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

    let result = forwardToControlPlane(capability: name, action: action, args: args)
    respond(id: id, result: [
        "content": [["type": "text", "text": result.text]],
        "isError": result.isError,
    ])
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
    guard let id else { return }
    guard let method else {
        respondError(id: id, code: -32600, message: "missing method")
        return
    }

    switch method {
    case "initialize":
        respond(id: id, result: [
            "protocolVersion": protocolVersion,
            "serverInfo": ["name": "uncoil", "version": serverVersion],
            "capabilities": ["tools": [:] as [String: Any]],
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
