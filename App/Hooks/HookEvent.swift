import Foundation

/// One structured event delivered by an agent's hook.
///
/// Claude Code writes a JSON object to the hook's stdin and names the event
/// inside it; the uncoil-hook helper forwards it verbatim as one line over the
/// Unix socket. Hermes writes a differently-shaped object and names the event
/// only by which config key the command sits under, so the helper stamps the
/// name (and the working directory, which Hermes does not send) before
/// forwarding. Both arrive here as the same seven kinds — the mapping from
/// Hermes' own event names lives in `HermesHookInstaller.managedEvents`.
struct HookEvent {
    enum Kind: String {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case notification = "Notification"
        case stop = "Stop"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case sessionEnd = "SessionEnd"
    }

    let kind: Kind
    let sessionID: String?
    let cwd: String?
    let toolName: String?
    let message: String?
    let prompt: String?
    /// Reported by the agent when its payload carries it. Claude Code does not
    /// send these on every event and older builds send neither, so both stay
    /// optional and the UI falls back to what the session was launched with.
    let model: String?
    let permissionMode: String?
    /// Which sub-agent a `SubagentStart` / `SubagentStop` is about.
    let agentID: String?

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
        // `prompt` is Claude Code's name for it, `user_message` is Hermes'.
        // This is what names a session after the first thing asked of it, so a
        // provider whose key was not read here would keep "new session" forever.
        prompt = object["prompt"] as? String ?? object["user_message"] as? String
        model = object["model"] as? String
        permissionMode = object["permission_mode"] as? String
        agentID = object["agent_id"] as? String
    }
}
