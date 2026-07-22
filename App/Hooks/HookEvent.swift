import Foundation

/// One structured event delivered by a Claude Code hook.
/// Claude writes a JSON object to the hook's stdin; the uncoil-hook helper
/// forwards it verbatim as one line over the Unix socket.
struct HookEvent {
    enum Kind: String {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case notification = "Notification"
        case stop = "Stop"
        case sessionEnd = "SessionEnd"
    }

    let kind: Kind
    let sessionID: String?
    let cwd: String?
    let toolName: String?
    let message: String?

    init?(jsonLine: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
            let name = object["hook_event_name"] as? String,
            let kind = Kind(rawValue: name)
        else { return nil }
        self.kind = kind
        sessionID = object["session_id"] as? String
        cwd = object["cwd"] as? String
        toolName = object["tool_name"] as? String
        message = object["message"] as? String
    }
}
