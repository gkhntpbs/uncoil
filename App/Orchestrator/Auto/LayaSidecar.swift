import AppKit
import Foundation

/// Laya, the local System 1 decision model Uncoil Auto asks its small
/// control questions, served on this Mac by `laya-apple`.
///
/// Everything lives in one directory under Application Support — the Python
/// environment, uv's download cache and the Hugging Face weights — so nothing
/// lands in `~/.cache` and removing the directory removes all of it.
/// Installing needs the user's click: Uncoil never fetches a runtime or a
/// model on its own. Once installed, the server is started when an Auto run
/// has a decision to ask, kept resident, started again if it went away, and
/// stopped when Uncoil quits.
///
/// The runtime is behind `AutoDecisionEngine`: replacing this Python sidecar
/// with MLX or Core ML in-process changes this file and nothing that asks.
@MainActor
final class LayaSidecar: ObservableObject {
    static let shared = LayaSidecar()

    enum State: Equatable {
        case unknown
        case notInstalled
        case installing(step: String)
        case installed
        case starting
        case ready(port: Int)
        case failed(String)

        var port: Int? {
            if case .ready(let port) = self { return port }
            return nil
        }
    }

    /// Pinned: the HTTP shape the client reads was measured against it.
    nonisolated static let package = "laya-apple[serve]==1.5.0"
    nonisolated static let checkpoints = ["laya", "laya-multilingual"]

    @Published private(set) var state: State = .unknown
    /// The last install's output, for when it fails.
    @Published private(set) var lastLog: String?
    /// How the decisions asked since launch went.
    @Published private(set) var stats = Stats()
    /// What `/health` said last.
    @Published private(set) var health: [String: String] = [:]

    struct Stats: Equatable {
        var answered = 0
        var failed = 0
        var lastLatencyMilliseconds: Double?
        var lastError: String?
        var lastDecisionAt: Date?
        /// Times the server was found gone and started again.
        var restarts = 0
    }

    let root: URL
    private var process: Process?
    /// The server went away while serving: the next request starts it again.
    private var stoppedUnexpectedly = false
    private var terminationObserver: NSObjectProtocol?

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// `laya`, or the `effort-advisor` directory an earlier Edge build
    /// installed into: a Python environment cannot be moved (its scripts
    /// name their interpreter by absolute path), so it is used where it is.
    nonisolated static var defaultRoot: URL {
        let base = ProjectStore.defaultDirectory()
        let current = base.appendingPathComponent("laya", isDirectory: true)
        let earlier = base.appendingPathComponent("effort-advisor", isDirectory: true)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: earlier.path) {
            return earlier
        }
        return current
    }

    var executable: URL { root.appendingPathComponent("venv/bin/laya-apple") }
    var logURL: URL { root.appendingPathComponent("serve.log") }

    /// uv's cache and the weights stay inside `root`.
    nonisolated static func environment(root: URL) -> [String: String] {
        [
            "UV_CACHE_DIR": root.appendingPathComponent("uv-cache").path,
            "HF_HOME": root.appendingPathComponent("hf").path,
            "HF_HUB_DISABLE_TELEMETRY": "1",
        ]
    }

    struct Step: Equatable {
        var title: String
        var executable: String
        var arguments: [String]
    }

    /// What Install runs, in order.
    nonisolated static func installSteps(uv: String, root: URL) -> [Step] {
        let venv = root.appendingPathComponent("venv")
        return [
            Step(title: "Creating the Python environment",
                 executable: uv, arguments: ["venv", "--quiet", "--python", "3.12", venv.path]),
            Step(title: "Installing laya-apple",
                 executable: uv,
                 arguments: ["pip", "install", "--quiet", "--python", venv.appendingPathComponent("bin/python").path, package]),
            Step(title: "Downloading the models",
                 executable: venv.appendingPathComponent("bin/laya-apple").path,
                 arguments: ["download"] + checkpoints),
        ]
    }

    nonisolated static func serveArguments(port: Int) -> [String] {
        // Offline: the weights were fetched at install, so serving never
        // touches the network. GPU: the Neural Engine path needs coremltools
        // and converted artifacts this install does not build.
        ["--offline", "serve", "--host", "127.0.0.1", "--port", String(port),
         "--device", "gpu", "--log-level", "warning"]
    }

    /// Whether the environment and the weights are there.
    func refresh() {
        switch state {
        case .installing, .starting, .ready: return
        default: break
        }
        state = isInstalled ? .installed : .notInstalled
    }

    var isInstalled: Bool {
        let hub = root.appendingPathComponent("hf/hub")
        return FileManager.default.isExecutableFile(atPath: executable.path)
            && Self.checkpoints.allSatisfy { name in
                FileManager.default.fileExists(
                    atPath: hub.appendingPathComponent("models--convaiinnovations--\(name)").path)
            }
    }

    static func locateUV() -> String? {
        AgentAdapterSupport.locateBinary("uv", extraDirectories: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path,
        ])
    }

    // MARK: - Install

    func install() async {
        if case .installing = state { return }
        guard let uv = Self.locateUV() else {
            state = .failed(String(localized: "uv was not found. Install it from docs.astral.sh/uv, then try again."))
            return
        }
        stop()
        let root = self.root
        let environment = Self.environment(root: root)
        var log = ""
        for step in Self.installSteps(uv: uv, root: root) {
            state = .installing(step: step.title)
            let result = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return ProcessRunner.run(
                    executable: step.executable, arguments: step.arguments,
                    cwd: root.path, extraEnv: environment, timeout: 1_800)
            }.value
            log += "$ \(step.title)\n\(result.stdoutString)\(result.stderrString)\n"
            if !result.launched || result.exitCode != 0 || result.timedOut {
                lastLog = log
                state = .failed(String(localized: "\(step.title) failed. See the log for details."))
                return
            }
        }
        lastLog = log
        // The probe is the verdict, not the exit codes.
        state = isInstalled ? .installed : .failed(String(localized: "The install finished but the model is not there."))
    }

    /// Removes the environment and the weights.
    func uninstall() {
        stop()
        try? FileManager.default.removeItem(at: root)
        state = .notInstalled
    }

    // MARK: - Serving

    /// Starts the server if it is installed and not running; returns the
    /// port once it answers `/health`, nil when it cannot.
    @discardableResult
    func ensureRunning() async -> Int? {
        if let port = state.port, process?.isRunning == true { return port }
        if stoppedUnexpectedly {
            stoppedUnexpectedly = false
            stats.restarts += 1
        }
        if state == .starting {
            // Someone else is starting it; wait for their answer.
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                if state != .starting { break }
            }
            return state.port
        }
        guard isInstalled else {
            state = .notInstalled
            return nil
        }
        guard let port = Self.freePort() else {
            state = .failed(String(localized: "No free local port for the model server."))
            return nil
        }
        state = .starting
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.serveArguments(port: port)
        var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "LANG", "TMPDIR"].contains($0.key) }
        environment.merge(Self.environment(root: root)) { $1 }
        process.environment = environment
        process.currentDirectoryURL = root
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                if case .ready = self.state {
                    self.stoppedUnexpectedly = true
                    self.state = .failed(String(localized: "The model server stopped."))
                }
                if self.state == .starting { self.state = .failed(String(localized: "The model server did not start. See serve.log.")) }
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
        self.process = process
        // Loading two checkpoints takes a few seconds; allow a minute.
        for _ in 0..<240 {
            if await Self.isHealthy(port: port) {
                state = .ready(port: port)
                return port
            }
            guard process.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning { process.terminate() }
        if state == .starting { state = .failed(String(localized: "The model server did not answer. See serve.log.")) }
        return nil
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        if process.isRunning { process.terminate() }
        state = isInstalled ? .installed : .notInstalled
    }

    func restart() async {
        stop()
        await ensureRunning()
    }

    /// The engine an Auto run asks, nil when Laya is not installed or will
    /// not start; the run then decides deterministically.
    func decisionEngine(timeout: TimeInterval) async -> (any AutoDecisionEngine)? {
        guard isInstalled, let port = await ensureRunning(),
              let url = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        return MeteredDecisionEngine(base: LayaDecisionClient(baseURL: url, timeout: timeout)) { [weak self] latency, error in
            Task { @MainActor in self?.note(latency: latency, error: error) }
        }
    }

    private func note(latency: Double?, error: String?) {
        stats.lastDecisionAt = Date()
        if let error {
            stats.failed += 1
            stats.lastError = error
        } else {
            stats.answered += 1
            stats.lastLatencyMilliseconds = latency
        }
    }

    /// Asks the running server how it is.
    func checkHealth() async {
        guard let port = state.port, let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            health = [:]
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            health = ["status": "no answer"]
            return
        }
        health = body.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String { result[entry.key] = value }
            else if let value = entry.value as? NSNumber { result[entry.key] = value.stringValue }
            else if let value = entry.value as? [String: Any],
                    let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                result[entry.key] = String(decoding: data, as: UTF8.self)
            }
        }
    }

    private static func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["status"] as? String == "ok"
    }

    /// A port the kernel says is free right now.
    nonisolated static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Counts what an engine answered, for the runtime's status in Settings.
struct MeteredDecisionEngine: AutoDecisionEngine {
    let base: any AutoDecisionEngine
    let observe: @Sendable (_ latencyMilliseconds: Double?, _ error: String?) -> Void

    func decide(_ schema: AutoDecisionSchema, state: String, checkpoint: String) async throws -> AutoDecisionAnswer {
        do {
            let answer = try await base.decide(schema, state: state, checkpoint: checkpoint)
            observe(answer.latencyMilliseconds, nil)
            return answer
        } catch {
            observe(nil, (error as? AutoDecisionError)?.description ?? error.localizedDescription)
            throw error
        }
    }
}
