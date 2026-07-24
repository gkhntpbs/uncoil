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
    static let installRemedy = "Open Uncoil Settings → Permissions → Agent Browser Setup"
    static let executablePreferenceKey = "agentBrowserExecutablePath"

    struct BrowserChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let executablePath: String?
    }

    private let resolveBinary: () -> String?
    private let navigationTimeout: TimeInterval
    private let defaultTimeout: TimeInterval
    private let browserDirectory: URL
    private let resolveSelectedExecutable: () -> String?

    init(resolver: @escaping () -> String? = { SettingsStore.which(AgentBrowserAdapter.binaryName) },
         browserDirectory: URL = AgentBrowserAdapter.defaultBrowserDirectory,
         defaultTimeout: TimeInterval = 30,
         navigationTimeout: TimeInterval = 60,
         selectedExecutable: @escaping () -> String? = {
             AgentBrowserAdapter.selectedExecutablePath
         }) {
        self.resolveBinary = resolver
        self.browserDirectory = browserDirectory
        self.defaultTimeout = defaultTimeout
        self.navigationTimeout = navigationTimeout
        self.resolveSelectedExecutable = selectedExecutable
    }

    static var defaultBrowserDirectory: URL {
        ProjectStore.defaultDirectory()
            .appendingPathComponent("Drivers", isDirectory: true)
            .appendingPathComponent("agent-browser", isDirectory: true)
    }

    static func runtimeEnvironment(
        browserDirectory: URL = defaultBrowserDirectory,
        nodePath: String? = SettingsStore.which("node"),
        temporaryDirectory: String? = ProcessInfo.processInfo.environment["TMPDIR"],
        executablePath: String? = selectedExecutablePath
    ) -> [String: String] {
        var environment = ["PLAYWRIGHT_BROWSERS_PATH": browserDirectory.path]
        if let nodePath {
            let basePath = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = URL(fileURLWithPath: nodePath)
                .deletingLastPathComponent().path + ":" + basePath
        }
        if let temporaryDirectory {
            environment["TMPDIR"] = temporaryDirectory
        }
        if let executablePath,
           FileManager.default.isExecutableFile(atPath: executablePath) {
            environment["AGENT_BROWSER_EXECUTABLE_PATH"] = executablePath
        }
        return environment
    }

    static var selectedExecutablePath: String? {
        let value = UserDefaults.standard.string(forKey: executablePreferenceKey)
        return value?.isEmpty == false ? value : nil
    }

    static func installedBrowserChoices() -> [BrowserChoice] {
        let candidates = [
            BrowserChoice(
                id: "chrome",
                name: "Google Chrome",
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ),
            BrowserChoice(
                id: "arc",
                name: "Arc",
                executablePath: "/Applications/Arc.app/Contents/MacOS/Arc"
            ),
            BrowserChoice(
                id: "edge",
                name: "Microsoft Edge",
                executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
            ),
            BrowserChoice(
                id: "brave",
                name: "Brave Browser",
                executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
            ),
            BrowserChoice(
                id: "vivaldi",
                name: "Vivaldi",
                executablePath: "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"
            ),
            BrowserChoice(
                id: "chromium",
                name: "Chromium",
                executablePath: "/Applications/Chromium.app/Contents/MacOS/Chromium"
            ),
        ]
        return [
            BrowserChoice(id: "managed", name: "Uncoil Chromium", executablePath: nil)
        ] + candidates.filter { candidate in
            guard let path = candidate.executablePath else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func nodePath(binary: String) -> String? {
        let sibling = URL(fileURLWithPath: binary)
            .deletingLastPathComponent()
            .appendingPathComponent("node").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        return SettingsStore.which("node")
    }

    static func packageRoot(binary: String) -> URL {
        URL(fileURLWithPath: binary)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func playwrightCLI(binary: String) -> String? {
        let path = packageRoot(binary: binary)
            .appendingPathComponent("node_modules/playwright-core/cli.js").path
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    static func runtimeRevision(binary: String) -> String? {
        struct Manifest: Decodable {
            struct Browser: Decodable {
                var name: String
                var revision: String
            }
            var browsers: [Browser]
        }

        let url = packageRoot(binary: binary)
            .appendingPathComponent("node_modules/playwright-core/browsers.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.browsers.first { $0.name == "chromium-headless-shell" }?.revision
    }

    static func runtimeInstalled(binary: String, browserDirectory: URL = defaultBrowserDirectory) -> Bool {
        guard let revision = runtimeRevision(binary: binary) else { return false }
        return FileManager.default.fileExists(
            atPath: browserDirectory
                .appendingPathComponent("chromium_headless_shell-\(revision)", isDirectory: true).path
        )
    }

    static func installInvocation(binary: String) -> (executable: String, arguments: [String])? {
        guard let node = SettingsStore.which("node"),
              let cli = playwrightCLI(binary: binary)
        else { return nil }
        return (node, [cli, "install", "chromium"])
    }

    func probe() -> DependencyInfo {
        guard let path = resolveBinary() else {
            return DependencyInfo(name: Self.binaryName, installed: false, path: nil,
                                  version: nil, detail: "binary not found on PATH",
                                  remedy: Self.installRemedy)
        }
        let revision = Self.runtimeRevision(binary: path)
        let selected = resolveSelectedExecutable()
        let selectedReady = selected.map {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? false
        let ready = selectedReady || Self.runtimeInstalled(binary: path, browserDirectory: browserDirectory)
        return DependencyInfo(
            name: Self.binaryName,
            installed: ready,
            path: path,
            version: revision.map { "Playwright Chromium \($0)" },
            detail: ready
                ? (selectedReady ? "CLI and selected Chromium browser are ready" : "CLI and Chromium runtime are ready")
                : "CLI found; compatible Chromium runtime is missing",
            remedy: ready ? nil : Self.installRemedy
        )
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
                                       extraEnv: profileEnv(profileDir, binary: binary),
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

    private func profileEnv(_ profileDir: String?, binary: String) -> [String: String] {
        Self.runtimeEnvironment(
            browserDirectory: browserDirectory,
            nodePath: Self.nodePath(binary: binary)
        )
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
