import Foundation

// MARK: - Persisted browser session config

/// Persisted at <session artifact root>/browser/session.json. Records the
/// derived isolation id, profile mode, and per-session domain policy.
struct BrowserSessionConfig: Codable, Equatable {
    enum ProfileMode: String, Codable {
        case ephemeralSession = "ephemeral_session"
        case persistentSession = "persistent_session"
        case persistentProject = "persistent_project"
    }
    var browser_session_id: String
    var profile_mode: ProfileMode
    var allowed_domains: [String]
    var blocked_domains: [String]

    var isPersistent: Bool { profile_mode != .ephemeralSession }
}

extension CapabilityRouter {

    // MARK: - Entry

    func handleBrowser(_ request: ControlRequest) async -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let grants = PolicyEngine.grants(for: caller)

        // Capability gate: browser.use is off by default.
        guard grants.contains("browser.use") else {
            return .failure(request, code: .capabilityDisabled,
                message: "the browser capability is disabled for this session",
                details: .object(["remedy": .string("enable browser capability (browser.use) for this session in Uncoil")]))
        }

        let identity = ControlIdentity.derive(projectID: caller.projectID, sessionID: caller.id)

        // Availability probe (off-main).
        let engine = browserEngine
        let info = await Task.detached { engine.probe() }.value
        if !info.installed {
            return .failure(request, code: .browserUnavailable,
                message: "agent-browser runtime is not ready",
                details: .object([
                    "remedy": .string(info.remedy ?? AgentBrowserAdapter.installRemedy),
                    "diagnostics": info.asJSON(),
                ]))
        }

        var config = loadBrowserConfig(caller: caller, identity: identity)

        switch request.action {
        case "status":
            return .success(request, data: .object([
                "browser_session_id": .string(identity),
                "installed": .bool(info.installed),
                "profile_mode": .string(config.profile_mode.rawValue),
                "allowed_domains": .array(config.allowed_domains.map(JSONValue.string)),
                "blocked_domains": .array(config.blocked_domains.map(JSONValue.string)),
                "engine": info.asJSON(),
            ]), project_id: caller.projectID.uuidString, target_session_id: caller.id.uuidString)

        case "start":
            // Optional profile mode + domain policy on start.
            if let mode = request.args["profile_mode"]?.stringValue,
               let parsed = BrowserSessionConfig.ProfileMode(rawValue: mode) {
                if parsed != .ephemeralSession && !grants.contains("browser.persistent_state") {
                    return .failure(request, code: .capabilityDisabled,
                        message: "persistent browser profiles require the browser.persistent_state grant",
                        target_session_id: caller.id.uuidString)
                }
                config.profile_mode = parsed
            }
            if let domains = request.args["allowed_domains"]?.arrayValue {
                config.allowed_domains = domains.compactMap { $0.stringValue }
            }
            if let domains = request.args["blocked_domains"]?.arrayValue {
                config.blocked_domains = domains.compactMap { $0.stringValue }
            }
            saveBrowserConfig(config, caller: caller)
            return await runBrowser(.start, request: request, caller: caller, config: config,
                                    extraData: ["browser_session_id": .string(identity),
                                                "profile_mode": .string(config.profile_mode.rawValue)])

        case "stop":
            // Isolation: stop only ever targets the caller's own derived id.
            return await runBrowser(.stop, request: request, caller: caller, config: config)

        case "open", "navigate":
            guard let url = request.args["url"]?.stringValue, !url.isEmpty else {
                return .failure(request, code: .invalidArgument, message: "'url' is required",
                                target_session_id: caller.id.uuidString)
            }
            if let denial = domainViolation(url: url, config: config) {
                return .failure(request, code: .permissionDenied,
                    message: denial, details: .object(["url": .string(url)]),
                    target_session_id: caller.id.uuidString)
            }
            let command: BrowserCommand = request.action == "open" ? .open(url: url) : .navigate(url: url)
            return await runBrowser(command, request: request, caller: caller, config: config)

        case "back":
            return await runBrowser(.back, request: request, caller: caller, config: config)
        case "reload":
            return await runBrowser(.reload, request: request, caller: caller, config: config)

        case "snapshot":
            let interactive = request.args["interactive_only"]?.boolValue ?? false
            return await runBrowser(.snapshot(interactiveOnly: interactive),
                                    request: request, caller: caller, config: config)

        case "click":
            guard let ref = request.args["ref"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'ref' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.click(ref: ref), request: request, caller: caller, config: config)

        case "fill":
            guard let ref = request.args["ref"]?.stringValue,
                  let text = request.args["text"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'ref' and 'text' are required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.fill(ref: ref, text: text), request: request, caller: caller, config: config)

        case "type":
            guard let ref = request.args["ref"]?.stringValue,
                  let text = request.args["text"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'ref' and 'text' are required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.type(ref: ref, text: text), request: request, caller: caller, config: config)

        case "press":
            guard let keys = request.args["keys"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'keys' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.press(keys: keys), request: request, caller: caller, config: config)

        case "hover":
            guard let ref = request.args["ref"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'ref' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.hover(ref: ref), request: request, caller: caller, config: config)

        case "select":
            guard let ref = request.args["ref"]?.stringValue,
                  let value = request.args["value"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'ref' and 'value' are required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.select(ref: ref, value: value), request: request, caller: caller, config: config)

        case "scroll":
            let direction = request.args["direction"]?.stringValue ?? "down"
            return await runBrowser(.scroll(direction: direction, amount: request.args["amount"]?.intValue),
                                    request: request, caller: caller, config: config)

        case "wait":
            let selectorOrMs = request.args["selector"]?.stringValue
                ?? request.args["ms"]?.intValue.map(String.init)
                ?? "1000"
            return await runBrowser(.wait(selectorOrMs: selectorOrMs), request: request, caller: caller, config: config)

        case "get":
            let what = request.args["what"]?.stringValue ?? "url"
            return await runBrowser(.get(what: what, ref: request.args["ref"]?.stringValue),
                                    request: request, caller: caller, config: config)

        case "screenshot":
            let full = request.args["full_page"]?.boolValue ?? false
            let path = artifactFilePath(caller: caller, subdir: "browser/screenshots",
                                        prefix: "shot", ext: "png")
            return await runBrowser(.screenshot(path: path, fullPage: full),
                                    request: request, caller: caller, config: config)

        case "list_tabs":
            return await runBrowser(.listTabs, request: request, caller: caller, config: config)
        case "new_tab":
            return await runBrowser(.newTab(url: request.args["url"]?.stringValue),
                                    request: request, caller: caller, config: config)
        case "switch_tab":
            guard let index = request.args["index"]?.intValue else {
                return .failure(request, code: .invalidArgument, message: "'index' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runBrowser(.switchTab(index: index), request: request, caller: caller, config: config)
        case "close_tab":
            return await runBrowser(.closeTab(index: request.args["index"]?.intValue),
                                    request: request, caller: caller, config: config)

        case "save_state":
            guard grants.contains("browser.persistent_state") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "save_state requires the browser.persistent_state grant",
                    target_session_id: caller.id.uuidString)
            }
            let path = artifactFilePath(caller: caller, subdir: "browser/states",
                                        prefix: "state", ext: "json")
            return await runBrowser(.saveState(path: path), request: request, caller: caller, config: config)

        case "clear_state":
            // Isolation: clear_state only ever touches the caller's OWN derived
            // session — its local state artifacts and the engine's cookies for
            // the caller's session id. A sibling session's files are never read
            // or removed here.
            let statesDir = caller.artifactRoot(dataDirectory: dataDirectory)
                .appendingPathComponent("browser/states", isDirectory: true)
            try? FileManager.default.removeItem(at: statesDir)
            return await runBrowser(.clearState, request: request, caller: caller, config: config)

        default:
            return .failure(request, code: .invalidAction, message: "unsupported browser action")
        }
    }

    // MARK: - Engine execution + envelope shaping

    private func runBrowser(
        _ command: BrowserCommand,
        request: ControlRequest,
        caller: SessionRecord,
        config: BrowserSessionConfig,
        extraData: [String: JSONValue] = [:]
    ) async -> ControlEnvelope {
        let engine = browserEngine
        let session = config.browser_session_id
        let profileDir = config.isPersistent ? persistentProfileDir(caller: caller, config: config) : nil
        let outcome = await Task.detached {
            engine.perform(command, session: session, profileDir: profileDir)
        }.value

        switch outcome {
        case .success(let result):
            var data: [String: JSONValue] = extraData
            for (key, value) in objectPairs(result.data) { data[key] = value }
            if let external = result.externalContent {
                data["external_content"] = TrustBoundary.wrap(external)
            }
            let artifacts = registerBrowserArtifacts(result.artifactFiles, caller: caller)
            return .success(request, data: .object(data),
                            project_id: caller.projectID.uuidString,
                            target_session_id: caller.id.uuidString,
                            artifacts: artifacts, warnings: result.warnings)
        case .failure(let error):
            var details = error.details
            if let remedy = error.remedy {
                var obj = objectPairs(details ?? .object([:]))
                obj["remedy"] = .string(remedy)
                details = .object(obj)
            }
            return .failure(request, code: error.code, message: error.message,
                            retryable: error.code == .timeout,
                            details: details, target_session_id: caller.id.uuidString)
        }
    }

    // MARK: - Config persistence

    private func browserDir(caller: SessionRecord) -> URL {
        caller.artifactRoot(dataDirectory: dataDirectory)
            .appendingPathComponent("browser", isDirectory: true)
    }

    func loadBrowserConfig(caller: SessionRecord, identity: String) -> BrowserSessionConfig {
        let url = browserDir(caller: caller).appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: url),
           var config = try? JSONDecoder().decode(BrowserSessionConfig.self, from: data) {
            config.browser_session_id = identity  // always canonical
            return config
        }
        return BrowserSessionConfig(browser_session_id: identity,
                                    profile_mode: .ephemeralSession,
                                    allowed_domains: [], blocked_domains: [])
    }

    func saveBrowserConfig(_ config: BrowserSessionConfig, caller: SessionRecord) {
        let dir = browserDir(caller: caller)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.json")
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Persistent profile dir — NEVER inside the git repo, never the personal
    /// Chrome profile. Lives under Application Support.
    private func persistentProfileDir(caller: SessionRecord, config: BrowserSessionConfig) -> String {
        let base = dataDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(caller.projectID.uuidString, isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        let leaf = config.profile_mode == .persistentProject
            ? "project"
            : config.browser_session_id
        let dir = base.appendingPathComponent(leaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - Domain policy

    /// Returns a denial reason if `url`'s host violates the session policy.
    func domainViolation(url: String, config: BrowserSessionConfig) -> String? {
        guard let host = Self.hostComponent(url) else {
            return config.allowed_domains.isEmpty ? nil : "URL has no resolvable host"
        }
        if config.blocked_domains.contains(where: { Self.hostMatches(host, $0) }) {
            return "host \(host) is blocked for this session"
        }
        if !config.allowed_domains.isEmpty
            && !config.allowed_domains.contains(where: { Self.hostMatches(host, $0) }) {
            return "host \(host) is not in the session's allowed domains"
        }
        return nil
    }

    nonisolated static func hostComponent(_ url: String) -> String? {
        if let parsed = URLComponents(string: url), let host = parsed.host, !host.isEmpty {
            return host.lowercased()
        }
        // Bare host / scheme-less input: try prefixing https://.
        if let parsed = URLComponents(string: "https://" + url), let host = parsed.host, !host.isEmpty {
            return host.lowercased()
        }
        return nil
    }

    /// Exact or suffix (subdomain) match: host == domain or host endsWith ".domain".
    nonisolated static func hostMatches(_ host: String, _ domain: String) -> Bool {
        let d = domain.lowercased()
        return host == d || host.hasSuffix("." + d)
    }

    // MARK: - Artifacts

    /// Timestamped absolute path under <artifact root>/<subdir>/.
    func artifactFilePath(caller: SessionRecord, subdir: String, prefix: String, ext: String) -> String {
        let dir = caller.artifactRoot(dataDirectory: dataDirectory)
            .appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.artifactStamp.string(from: Date())
        return dir.appendingPathComponent("\(prefix)-\(stamp).\(ext)").path
    }

    private func registerBrowserArtifacts(_ files: [String], caller: SessionRecord) -> [JSONValue] {
        files.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            recordArtifact(name: name, kind: "browser", description: "browser output", caller: caller)
            return .object(["name": .string(name), "path": .string(path), "kind": .string("browser")])
        }
    }

    private static let artifactStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    // MARK: - JSON helpers

    func objectPairs(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let obj) = value { return obj }
        return [:]
    }
}
