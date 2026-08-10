import Foundation

/// A short-lived JSON-RPC conversation with `codex app-server`, used to ask for
/// rate limits and nothing else.
///
/// Separate from `CodexAppServerSession`, which owns a long-running agent over
/// a unix socket. This one talks over the child's stdin/stdout, answers two
/// questions and exits. The difference that matters is lifetime: a monitor that
/// borrowed the session machinery would keep a Codex process alive for the life
/// of the app, and a monitor is not a reason to run an agent.
///
/// The process is launched read-only and untrusted — `-s read-only -a
/// untrusted` — because nothing here should be able to change a file. It is the
/// cheapest possible guarantee: a usage probe that could write is a usage probe
/// that has to be trusted.
///
/// Every wait is bounded and the child is killed on the way out through every
/// exit, including the throwing ones. An orphaned `codex app-server` would
/// otherwise accumulate one per failed refresh.
final class CodexAppServerProbe {
    struct Configuration {
        var executable: String
        var codexHome: URL?
        /// Startup gets its own budget: a first launch may compile, read a
        /// config, or check a version, and holding it to the same deadline as a
        /// subsequent call would fail every cold start.
        var startupTimeout: TimeInterval = 20
        var requestTimeout: TimeInterval = 8
    }

    struct Reply {
        var account: JSONValue?
        var rateLimits: JSONValue?
    }

    private let configuration: Configuration
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private let condition = NSCondition()
    private var buffer = Data()
    private var pending: [Int: JSONValue] = [:]
    private var failures: [Int: String] = [:]
    private var streamClosed = false
    private var nextID = 1

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Runs the whole exchange. Blocking; call it off the main thread.
    func run() throws -> Reply {
        try launch()
        defer { shutdown() }

        _ = try request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("uncoil"),
                    "title": .string("Uncoil"),
                    "version": .string(Bundle.main.shortVersion ?? "0"),
                ]),
            ]),
            timeout: configuration.startupTimeout
        )

        // Codex's protocol expects the notification that initialisation is
        // finished before it will answer anything else.
        try send(try CodexAppServerJSON.notification(method: "initialized"))

        // Identity is a nicety and rate limits are the point, so a failure to
        // read the account does not fail the probe. Reporting "usage
        // unavailable" because an email could not be read would be the tail
        // wagging the dog.
        let account = try? request(
            method: "account/read", params: .object([:]), timeout: configuration.requestTimeout
        )
        let rateLimits = try request(
            method: "account/rateLimits/read", params: .object([:]), timeout: configuration.requestTimeout
        )

        return Reply(account: account, rateLimits: rateLimits)
    }

    // MARK: - Process

    private func launch() throws {
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Scrubbed environment, as everywhere else that spawns a child here: a
        // probe has no business handing the parent's whole environment to a
        // subprocess. CODEX_HOME is the one addition, and it is what makes the
        // answer belong to the account being asked about rather than to
        // whichever one happens to be the default.
        var environment: [String: String] = [:]
        let parent = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "LANG", "TMPDIR"] {
            if let value = parent[key] { environment[key] = value }
        }
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        if let home = configuration.codexHome {
            environment["CODEX_HOME"] = home.path
        }
        process.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.condition.lock()
                self.streamClosed = true
                self.condition.broadcast()
                self.condition.unlock()
                return
            }
            self.ingest(chunk)
        }
        // Drained and discarded: Codex writes progress and warnings here, and a
        // full stderr pipe would block the child mid-answer.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            throw UsageFetchError(.processFailed, detail: "codex app-server did not start")
        }
    }

    private func shutdown() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()

        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Reaps the zombie; the process is already dying, so this cannot hang.
        process.waitUntilExit()
    }

    // MARK: - RPC

    private func request(method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        let id = nextID
        nextID += 1
        try send(try CodexAppServerJSON.data(id: id, method: method, params: params))

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result = pending.removeValue(forKey: id) { return result }
            if let message = failures.removeValue(forKey: id) {
                throw UsageFetchError(.processFailed, detail: message)
            }
            if streamClosed {
                throw UsageFetchError(.processFailed, detail: "codex app-server closed the connection")
            }
            if Date() >= deadline {
                throw UsageFetchError(.timedOut, detail: method)
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    private func send(_ data: Data) throws {
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw UsageFetchError(.processFailed, detail: "codex app-server stopped reading")
        }
    }

    /// Splits the stream on newlines and files each complete message by id.
    ///
    /// Anything that is not a reply to an outstanding request is dropped
    /// without comment: the server emits notifications of its own, and a probe
    /// that treated an unexpected line as an error would fail on a Codex that
    /// merely became chattier.
    private func ingest(_ chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty,
                  let message = try? CodexAppServerMessage(data: Data(line)),
                  let id = message.id?.intValue else { continue }
            if let error = message.error {
                let text = error.objectValue?["message"]?.stringValue ?? "app-server error"
                failures[id] = text
            } else if let result = message.result {
                pending[id] = result
            }
        }
        condition.broadcast()
    }
}

private extension Bundle {
    var shortVersion: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
