import Foundation

/// `BrowserEngine` backed by the `agent-browser` CLI (Vercel Labs).
///
/// Verified CLI surface (`agent-browser --help`, v as-installed 2026-07):
///   open <url> · click <sel|@ref> · dblclick · type <sel> <text> ·
///   fill <sel> <text> · press <key> · hover <sel> · select <sel> <val> ·
///   scroll <dir> [px] · wait <sel|ms> · screenshot [path] · snapshot [-i] ·
///   back · forward · reload · close · get <what> [sel] ·
///   tab [new|list|close|<n>] · cookies [get|set|clear] · storage <local|session> ·
///   session [list]
/// Global options: `--session <name>` (isolation), `--json` (machine output),
/// `--full` (full-page screenshot).
///
/// Output contract (observed): every `--json` invocation prints a single JSON
/// object `{"success":bool,"data":<any>,"error":<string|null>}` and — notably —
/// exits 0 even on failure. Success/failure MUST be read from the `success`
/// field, not the exit code.
///
/// All argv is whitelisted here: the subcommand verbs are fixed literals and
/// only value arguments (urls, refs, text) come from the caller. Nothing is
/// ever passed through a shell.
final class AgentBrowserAdapter: BrowserEngine, @unchecked Sendable {
    static let binaryName = "agent-browser"
    static let installRemedy = "npm install -g agent-browser (then `agent-browser install` to fetch browser binaries)"

    private let resolveBinary: () -> String?
    private let navigationTimeout: TimeInterval
    private let defaultTimeout: TimeInterval

    /// `resolver` is injected so tests/other callers can stub binary lookup;
    /// production uses `SettingsStore.which`.
    init(resolver: @escaping () -> String? = { SettingsStore.which(AgentBrowserAdapter.binaryName) },
         defaultTimeout: TimeInterval = 30,
         navigationTimeout: TimeInterval = 60) {
        self.resolveBinary = resolver
        self.defaultTimeout = defaultTimeout
        self.navigationTimeout = navigationTimeout
    }

    func probe() -> DependencyInfo {
        guard let path = resolveBinary() else {
            return DependencyInfo(name: Self.binaryName, installed: false, path: nil,
                                  version: nil, detail: "binary not found on PATH",
                                  remedy: Self.installRemedy)
        }
        // agent-browser has no `--version`; report installed + path. Attempt a
        // cheap `session` call to confirm it executes.
        let result = ProcessRunner.run(executable: path, arguments: ["--json", "session"],
                                       timeout: 8)
        let ok = result.launched
        return DependencyInfo(name: Self.binaryName, installed: true, path: path,
                              version: nil,
                              detail: ok ? "responds to `session`" : (result.launchError ?? "did not execute"),
                              remedy: ok ? nil : Self.installRemedy)
    }

    func perform(_ command: BrowserCommand, session: String, profileDir: String?)
        -> Swift.Result<EngineResult, EngineError> {
        guard let binary = resolveBinary() else {
            return .failure(EngineError(.browserUnavailable,
                "agent-browser is not installed", remedy: Self.installRemedy))
        }

        let (verb, timeout, produced): ([String], TimeInterval, String?) = argv(for: command)
        // A nil verb signals a command we satisfy without spawning.
        guard !verb.isEmpty else {
            return .success(EngineResult(data: .object(["ok": .bool(true)])))
        }

        var args = ["--json", "--session", session]
        // Persistent profile support: agent-browser has no dedicated profile
        // flag exposed here; session isolation already namespaces state. The
        // profileDir is reserved for a future `--user-data-dir` mapping and is
        // intentionally NOT the user's personal Chrome profile.
        args.append(contentsOf: verb)

        let result = ProcessRunner.run(executable: binary, arguments: args,
                                       extraEnv: profileEnv(profileDir),
                                       timeout: timeout)
        if result.timedOut {
            return .failure(EngineError(.timeout,
                "agent-browser timed out after \(Int(timeout))s", remedy: nil))
        }
        if !result.launched {
            return .failure(EngineError(.browserUnavailable,
                result.launchError ?? "agent-browser failed to launch", remedy: Self.installRemedy))
        }
        return parse(result, produced: produced)
    }

    // MARK: - Command → argv mapping (the documented command table)

    /// Returns the verb argv (after `--json --session <id>`), the per-call
    /// timeout, and — if the command writes a file — that absolute path.
    private func argv(for command: BrowserCommand) -> ([String], TimeInterval, String?) {
        switch command {
        case .start:
            // No explicit start verb; `session` confirms/creates the namespace.
            return (["session"], defaultTimeout, nil)
        case .stop:
            return (["close"], defaultTimeout, nil)
        case .open(let url):
            return (["open", url], navigationTimeout, nil)
        case .navigate(let url):
            return (["open", url], navigationTimeout, nil)
        case .back:
            return (["back"], navigationTimeout, nil)
        case .reload:
            return (["reload"], navigationTimeout, nil)
        case .snapshot(let interactiveOnly):
            return (interactiveOnly ? ["snapshot", "-i"] : ["snapshot"], defaultTimeout, nil)
        case .click(let ref):
            return (["click", ref], defaultTimeout, nil)
        case .fill(let ref, let text):
            return (["fill", ref, text], defaultTimeout, nil)
        case .type(let ref, let text):
            return (["type", ref, text], defaultTimeout, nil)
        case .press(let keys):
            return (["press", keys], defaultTimeout, nil)
        case .hover(let ref):
            return (["hover", ref], defaultTimeout, nil)
        case .select(let ref, let value):
            return (["select", ref, value], defaultTimeout, nil)
        case .scroll(let direction, let amount):
            var v = ["scroll", direction]
            if let amount { v.append(String(amount)) }
            return (v, defaultTimeout, nil)
        case .wait(let selectorOrMs):
            return (["wait", selectorOrMs], navigationTimeout, nil)
        case .get(let what, let ref):
            var v = ["get", what]
            if let ref { v.append(ref) }
            return (v, defaultTimeout, nil)
        case .screenshot(let path, let fullPage):
            var v = ["screenshot", path]
            if fullPage { v.append("--full") }
            return (v, defaultTimeout, path)
        case .listTabs:
            return (["tab", "list"], defaultTimeout, nil)
        case .newTab(let url):
            return (url == nil ? ["tab", "new"] : ["tab", "new", url!], navigationTimeout, nil)
        case .switchTab(let index):
            return (["tab", String(index)], defaultTimeout, nil)
        case .closeTab(let index):
            return (index == nil ? ["tab", "close"] : ["tab", "close", String(index!)], defaultTimeout, nil)
        case .saveState(let path):
            // No single `state save`; export cookies as the state artifact.
            return (["cookies", "get"], defaultTimeout, path)
        case .clearState:
            // Best-effort: clear cookies (storage clearing is per-page).
            return (["cookies", "clear"], defaultTimeout, nil)
        case .status:
            return (["session"], defaultTimeout, nil)
        }
    }

    private func profileEnv(_ profileDir: String?) -> [String: String] {
        // Reserved hook for persistent profiles; kept explicit so no personal
        // Chrome profile can ever be selected implicitly.
        [:]
    }

    // MARK: - Output parsing

    private func parse(_ result: ProcessRunner.Result, produced: String?)
        -> Swift.Result<EngineResult, EngineError> {
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = jsonObject(text) else {
            // Non-JSON output: treat non-zero exit as failure.
            if result.exitCode != 0 {
                let err = result.stderrString.isEmpty ? text : result.stderrString
                return .failure(classify(err))
            }
            return .success(EngineResult(data: .object(["raw": .string(text)])))
        }

        let success = obj["success"]?.boolValue ?? (result.exitCode == 0)
        if !success {
            let message = obj["error"]?.stringValue ?? "agent-browser reported failure"
            return .failure(classify(message))
        }

        let dataValue = obj["data"] ?? .null
        var artifactFiles: [String] = []
        if let produced, FileManager.default.fileExists(atPath: produced) {
            artifactFiles.append(produced)
        } else if let produced, case .string(let raw) = (obj["data"] ?? .null) {
            // saveState via cookies: persist the returned JSON to the artifact.
            try? Data(raw.utf8).write(to: URL(fileURLWithPath: produced))
            if FileManager.default.fileExists(atPath: produced) { artifactFiles.append(produced) }
        }
        return .success(EngineResult(
            data: .object(["success": .bool(true)]),
            externalContent: dataValue.isNull ? nil : dataValue,
            artifactFiles: artifactFiles))
    }

    /// Maps a driver error message to a typed EngineError. Stale/unknown ref
    /// language (element refs like `@e3`) → STALE_ELEMENT_REFERENCE.
    private func classify(_ message: String) -> EngineError {
        let lower = message.lowercased()
        let staleSignals = ["no element", "not found", "stale", "detached",
                            "unknown ref", "invalid ref", "no such element",
                            "failed to find", "resolve ref"]
        if staleSignals.contains(where: lower.contains) {
            return EngineError(.staleElementReference,
                "element reference is stale or unknown: \(message)",
                remedy: "take a fresh snapshot and use the new ref")
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return EngineError(.timeout, message)
        }
        if lower.contains("executable doesn't exist") || lower.contains("playwright install") {
            return EngineError(.browserUnavailable,
                "browser binaries are not installed for agent-browser",
                remedy: "run `agent-browser install` (or `npx playwright install`)")
        }
        return EngineError(.invalidStateTransition, message)
    }

    private func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = value else { return nil }
        return obj
    }
}

private extension JSONValue {
    var isNull: Bool { if case .null = self { return true }; return false }
}
