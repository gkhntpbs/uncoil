import Foundation

// MARK: - Process launching seam

/// Handle to a launched run process. `terminate()` is SIGTERM to the process
/// group; `forceKill()` is SIGKILL.
protocol RunProcessHandle: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func forceKill()
    /// Writes to the process's stdin (dev-server REPL commands, hot-reload
    /// keys like Flutter's `r`). Best-effort; no-op after exit.
    func sendInput(_ data: Data)
}

/// Seam so the registry's lifecycle logic is testable with a fake. The real
/// implementation runs the command through the user's login shell so the same
/// PATH/tooling as an interactive terminal applies.
protocol RunProcessLaunching {
    @MainActor func launch(
        command: String,
        cwd: URL,
        env: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> RunProcessHandle
}

final class ShellRunProcessHandle: RunProcessHandle {
    let process: Process
    let stdin: Pipe
    init(process: Process, stdin: Pipe) {
        self.process = process
        self.stdin = stdin
    }
    func sendInput(_ data: Data) {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    // Signal the whole group (negative pid) so `sh -c` children die with the
    // shell; fall back to the single pid if no group exists.
    func terminate() {
        if kill(-process.processIdentifier, SIGTERM) != 0 { process.terminate() }
    }
    func forceKill() {
        if kill(-process.processIdentifier, SIGKILL) != 0 {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

struct ShellRunProcessLauncher: RunProcessLaunching {
    @MainActor func launch(
        command: String,
        cwd: URL,
        env: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> RunProcessHandle {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login shell (PATH, nvm, etc.); no `exec` so the shell survives as the
        // group leader we can signal, and multi-command lines keep working.
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        // Dev servers detect TTYs for color; without one, ask nicely for plain
        // deterministic output agents can parse.
        environment["NO_COLOR"] = environment["NO_COLOR"] ?? "1"
        process.environment = environment

        let pipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = stdinPipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in onOutput(text) }
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = finished.terminationStatus
            Task { @MainActor in onExit(code) }
        }
        try process.run()
        // Put the shell in its own group so stop() can signal every child.
        setpgid(process.processIdentifier, process.processIdentifier)
        return ShellRunProcessHandle(process: process, stdin: stdinPipe)
    }
}

// MARK: - Run state

enum RunStatus: Equatable {
    case idle
    case starting
    case running
    case exited(Int32)
    case failed

    var label: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .exited: "exited"
        case .failed: "failed"
        }
    }
}

/// Live state of one configuration in one project. Everything here is also
/// reachable over MCP (`uncoil_run status`) — nothing is UI-only.
struct RunProcessState {
    var status: RunStatus = .idle
    var pid: Int32?
    var startedAt: Date?
    var lastExitCode: Int32?
    var issue: RunIssue?
    /// Capped in-memory tail; the full log is on disk at `logFileURL`.
    var logTail: String = ""
    var logFileURL: URL?
}

// MARK: - Run history

/// One past (or current) run of a configuration; persisted per project in
/// `run/history.json` beside the log files, so previous runs stay inspectable
/// by the user and by agents after the process is gone.
struct RunHistoryEntry: Codable, Equatable, Identifiable {
    var id: String
    var configID: String
    var startedAt: Date
    var endedAt: Date? = nil
    var exitCode: Int32? = nil
    var logFile: String

    func asJSON() -> JSONValue {
        let iso = ISO8601DateFormatter()
        var object: [String: JSONValue] = [
            "config_id": .string(configID),
            "started_at": .string(iso.string(from: startedAt)),
            "log_file": .string(logFile),
        ]
        if let endedAt { object["ended_at"] = .string(iso.string(from: endedAt)) }
        if let exitCode { object["exit_code"] = .int(Int(exitCode)) }
        return .object(object)
    }
}

enum RunHistoryStore {
    static let keptRunsPerConfiguration = 10

    static func url(runDirectory: URL) -> URL {
        runDirectory.appendingPathComponent("history.json")
    }

    static func load(runDirectory: URL) -> [RunHistoryEntry] {
        guard let data = try? Data(contentsOf: url(runDirectory: runDirectory)),
              let entries = try? JSONDecoder().decode([RunHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [RunHistoryEntry], runDirectory: URL) {
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url(runDirectory: runDirectory), options: .atomic)
        }
    }

    /// Appends a new entry and prunes the oldest beyond the per-config cap,
    /// deleting their log files with them.
    static func append(_ entry: RunHistoryEntry, runDirectory: URL) {
        var entries = load(runDirectory: runDirectory)
        entries.append(entry)
        let forConfig = entries.filter { $0.configID == entry.configID }
        if forConfig.count > keptRunsPerConfiguration {
            let doomed = forConfig.sorted { $0.startedAt < $1.startedAt }
                .prefix(forConfig.count - keptRunsPerConfiguration)
            for dead in doomed {
                try? FileManager.default.removeItem(atPath: dead.logFile)
            }
            let doomedIDs = Set(doomed.map(\.id))
            entries.removeAll { doomedIDs.contains($0.id) }
        }
        save(entries, runDirectory: runDirectory)
    }

    static func close(id: String, exitCode: Int32?, runDirectory: URL) {
        var entries = load(runDirectory: runDirectory)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].endedAt = .now
        entries[index].exitCode = exitCode
        save(entries, runDirectory: runDirectory)
    }
}

// MARK: - Registry

/// Owns every running dev-preview process. Peer of `TerminalRegistry`: one
/// state per (project, configuration id), reads `.uncoil/run.json` fresh on
/// every operation so external edits (by agents) are always honoured.
@MainActor
final class RunRegistry: ObservableObject {
    static let shared = RunRegistry()

    struct Key: Hashable {
        let projectID: UUID
        let configID: String
    }

    @Published private(set) var states: [Key: RunProcessState] = [:]

    var launcher: RunProcessLaunching = ShellRunProcessLauncher()
    var dataDirectory: URL = ProjectStore.defaultDirectory()
    /// Attention reporting hook; nil in tests.
    var reportFailure: ((_ project: Project, _ config: RunConfiguration, _ issue: RunIssue) -> Void)? = { project, config, issue in
        AttentionStore.shared.report(
            kind: .runtime,
            title: "Run '\(config.name)' failed",
            detail: issue.hint,
            projectID: project.id,
            sessionID: nil,
            id: "run:\(project.id):\(config.id)"
        )
    }
    /// Readiness tuning, relaxed in production and near-instant in tests.
    var readinessTimeout: TimeInterval = 60
    var survivalGrace: TimeInterval = 2
    private static let logTailLimit = 32_768

    private var handles: [Key: RunProcessHandle] = [:]
    private var logHandles: [Key: FileHandle] = [:]
    private var generation: [Key: Int] = [:]
    private var historyIDs: [Key: String] = [:]

    func state(project: Project, configID: String) -> RunProcessState {
        states[Key(projectID: project.id, configID: configID)] ?? RunProcessState()
    }

    func runDirectory(projectID: UUID) -> URL {
        dataDirectory.appendingPathComponent("projects/\(projectID.uuidString)/run")
    }

    func history(project: Project, configID: String?) -> [RunHistoryEntry] {
        let entries = RunHistoryStore.load(runDirectory: runDirectory(projectID: project.id))
        let filtered = configID.map { id in entries.filter { $0.configID == id } } ?? entries
        return filtered.sorted { $0.startedAt > $1.startedAt }
    }

    /// Writes text (plus newline unless `raw`) to the run's stdin. Returns
    /// false when nothing is running.
    @discardableResult
    func sendInput(project: Project, configID: String, text: String, raw: Bool = false) -> Bool {
        let key = Key(projectID: project.id, configID: configID)
        guard let handle = handles[key],
              let data = (raw ? text : text + "\n").data(using: .utf8) else { return false }
        handle.sendInput(data)
        return true
    }

    func runningCount(projectID: UUID) -> Int {
        states.filter { $0.key.projectID == projectID && $0.value.status == .running }.count
    }

    // MARK: Start

    struct StartOutcome {
        let configID: String
        let ok: Bool
        let status: RunStatus
        let issue: RunIssue?
    }

    /// Starts `configID` after starting (and waiting on) its `depends_on`
    /// chain. Returns one outcome per configuration touched, target last.
    func start(project: Project, configID: String) async -> [StartOutcome] {
        let contents = RunConfigFile.load(projectRoot: project.rootURL)
        guard let order = dependencyOrder(target: configID, in: contents.configurations) else {
            let issue = RunIssue(
                code: contents.configurations.contains(where: { $0.id == configID })
                    ? "dependency_cycle" : "unknown_configuration",
                hint: contents.configurations.contains(where: { $0.id == configID })
                    ? "The depends_on chain of '\(configID)' contains a cycle or an unknown id; fix .uncoil/run.json."
                    : "No configuration '\(configID)' in .uncoil/run.json. Use detect/list first."
            )
            return [StartOutcome(configID: configID, ok: false, status: .failed, issue: issue)]
        }
        var outcomes: [StartOutcome] = []
        for config in order {
            let key = Key(projectID: project.id, configID: config.id)
            if states[key]?.status == .running {
                outcomes.append(StartOutcome(configID: config.id, ok: true, status: .running, issue: nil))
                continue
            }
            let outcome = await startSingle(project: project, config: config, key: key)
            outcomes.append(outcome)
            if !outcome.ok {
                // Prerequisite failed: the target can't start.
                if config.id != configID {
                    let issue = RunIssue(
                        code: "dependency_failed",
                        hint: "Prerequisite '\(config.id)' failed (\(outcome.issue?.code ?? "unknown")): "
                            + (outcome.issue?.hint ?? "see its log")
                    )
                    outcomes.append(StartOutcome(configID: configID, ok: false, status: .failed, issue: issue))
                }
                break
            }
        }
        return outcomes
    }

    private func startSingle(
        project: Project, config: RunConfiguration, key: Key
    ) async -> StartOutcome {
        // Preflight: a declared port already serving means either a leftover
        // process or another app — fail fast with the real story.
        for port in config.ports where Self.isPortOpen(port) {
            let issue = RunIssue(
                code: "port_in_use",
                hint: "Port \(port) is already serving before start. Stop whatever owns "
                    + "it (`lsof -ti :\(port)`), or change the configured port."
            )
            finishFailure(key: key, project: project, config: config, issue: issue, exitCode: nil)
            return StartOutcome(configID: config.id, ok: false, status: .failed, issue: issue)
        }

        let cwd = config.cwd == "." ? project.rootURL
            : project.rootURL.appendingPathComponent(config.cwd)
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            let issue = RunIssue(
                code: "invalid_cwd",
                hint: "Working directory '\(config.cwd)' doesn't exist under the project "
                    + "root; fix 'cwd' in .uncoil/run.json."
            )
            finishFailure(key: key, project: project, config: config, issue: issue, exitCode: nil)
            return StartOutcome(configID: config.id, ok: false, status: .failed, issue: issue)
        }

        let logURL = prepareLogFile(project: project, configID: config.id)
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        states[key] = RunProcessState(status: .starting, startedAt: .now, logFileURL: logURL)

        let handle: RunProcessHandle
        do {
            handle = try launcher.launch(
                command: config.command,
                cwd: cwd,
                env: config.env,
                onOutput: { [weak self] text in
                    self?.appendOutput(text, key: key, generation: gen)
                },
                onExit: { [weak self] code in
                    self?.processExited(code, key: key, generation: gen, project: project, config: config)
                }
            )
        } catch {
            let issue = RunIssue(
                code: "launch_failed",
                hint: "Could not launch the shell: \(error.localizedDescription)"
            )
            finishFailure(key: key, project: project, config: config, issue: issue, exitCode: nil)
            return StartOutcome(configID: config.id, ok: false, status: .failed, issue: issue)
        }
        handles[key] = handle
        states[key]?.pid = handle.pid

        let ready = await waitForReadiness(key: key, config: config, generation: gen)
        if ready {
            if generation[key] == gen, states[key]?.status == .starting {
                states[key]?.status = .running
            }
            return StartOutcome(configID: config.id, ok: true, status: .running, issue: nil)
        }
        let state = states[key] ?? RunProcessState()
        if state.status == .starting {
            // Alive but never signalled readiness within the timeout.
            let issue = RunDiagnostics.diagnose(exitCode: nil, logTail: state.logTail, config: config)
            states[key]?.issue = issue
            return StartOutcome(configID: config.id, ok: false, status: .starting, issue: issue)
        }
        return StartOutcome(configID: config.id, ok: false, status: state.status, issue: state.issue)
    }

    private func waitForReadiness(key: Key, config: RunConfiguration, generation gen: Int) async -> Bool {
        let regex = config.readyPattern.flatMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        let hasSignal = regex != nil || !config.ports.isEmpty
        let deadline = Date.now.addingTimeInterval(hasSignal ? readinessTimeout : survivalGrace)
        while Date.now < deadline {
            guard generation[key] == gen, let state = states[key], state.status == .starting
            else { return false }
            if let regex {
                let tail = state.logTail
                let range = NSRange(tail.startIndex..., in: tail)
                if regex.firstMatch(in: tail, options: [], range: range) != nil { return true }
            }
            if config.ports.contains(where: Self.isPortOpen) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // No explicit signal: surviving the grace period counts as running.
        return !hasSignal && generation[key] == gen && states[key]?.status == .starting
    }

    // MARK: Stop / restart

    func stop(project: Project, configID: String) async {
        let key = Key(projectID: project.id, configID: configID)
        guard let handle = handles[key] else {
            if states[key]?.status == .starting || states[key]?.status == .running {
                states[key]?.status = .idle
            }
            return
        }
        generation[key] = (generation[key] ?? 0) + 1  // invalidate readiness waits
        handle.terminate()
        let deadline = Date.now.addingTimeInterval(5)
        while handle.isRunning, Date.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if handle.isRunning { handle.forceKill() }
        handles[key] = nil
        closeLog(key: key)
        closeHistory(key: key, exitCode: nil)
        states[key]?.status = .idle
        states[key]?.pid = nil
        states[key]?.issue = nil
    }

    func restart(project: Project, configID: String) async -> [StartOutcome] {
        await stop(project: project, configID: configID)
        return await start(project: project, configID: configID)
    }

    /// Synchronous best-effort kill for app termination: SIGTERM every group,
    /// no waiting (the processes are our children and get reparented+signalled).
    func terminateAllForApplicationQuit() {
        for handle in handles.values { handle.terminate() }
        handles.removeAll()
        for key in Array(logHandles.keys) { closeLog(key: key) }
    }

    func stopAll() async {
        // Snapshot keys first; stop mutates the dictionaries.
        for key in Array(handles.keys) {
            guard let handle = handles[key] else { continue }
            handle.terminate()
            handles[key] = nil
            closeLog(key: key)
            states[key]?.status = .idle
            states[key]?.pid = nil
        }
    }

    // MARK: Internals

    private func appendOutput(_ text: String, key: Key, generation gen: Int) {
        guard generation[key] == gen else { return }
        if var tail = states[key]?.logTail {
            tail += text
            if tail.count > Self.logTailLimit {
                tail = String(tail.suffix(Self.logTailLimit))
            }
            states[key]?.logTail = tail
        }
        if let data = text.data(using: .utf8) {
            logHandles[key]?.write(data)
        }
    }

    private func processExited(
        _ code: Int32, key: Key, generation gen: Int, project: Project, config: RunConfiguration
    ) {
        guard generation[key] == gen else { return }
        handles[key] = nil
        closeLog(key: key)
        closeHistory(key: key, exitCode: code)
        let previous = states[key]?.status
        states[key]?.pid = nil
        states[key]?.lastExitCode = code
        if previous == .starting || (previous == .running && code != 0) {
            let issue = RunDiagnostics.diagnose(
                exitCode: code, logTail: states[key]?.logTail ?? "", config: config
            )
            states[key]?.status = .failed
            states[key]?.issue = issue
            reportFailure?(project, config, issue)
        } else {
            states[key]?.status = .exited(code)
        }
    }

    private func finishFailure(
        key: Key, project: Project, config: RunConfiguration, issue: RunIssue, exitCode: Int32?
    ) {
        var state = states[key] ?? RunProcessState()
        state.status = .failed
        state.issue = issue
        state.lastExitCode = exitCode
        state.pid = nil
        states[key] = state
        reportFailure?(project, config, issue)
    }

    private func prepareLogFile(project: Project, configID: String) -> URL {
        let runDir = runDirectory(projectID: project.id)
        let dir = runDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One file per run (not per configuration), so previous runs stay
        // readable; RunHistoryStore prunes the oldest beyond its cap.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: .now)
        let url = dir.appendingPathComponent("\(configID)-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let key = Key(projectID: project.id, configID: configID)
        closeLog(key: key)
        logHandles[key] = try? FileHandle(forWritingTo: url)
        let entryID = UUID().uuidString
        historyIDs[key] = entryID
        RunHistoryStore.append(
            RunHistoryEntry(id: entryID, configID: configID, startedAt: .now, logFile: url.path),
            runDirectory: runDir
        )
        return url
    }

    private func closeHistory(key: Key, exitCode: Int32?) {
        guard let entryID = historyIDs[key] else { return }
        historyIDs[key] = nil
        RunHistoryStore.close(
            id: entryID, exitCode: exitCode,
            runDirectory: runDirectory(projectID: key.projectID)
        )
    }

    private func closeLog(key: Key) {
        try? logHandles[key]?.close()
        logHandles[key] = nil
    }

    /// Topological order ending at `target`; nil on unknown ids or cycles.
    func dependencyOrder(target: String, in configs: [RunConfiguration]) -> [RunConfiguration]? {
        let byID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        guard byID[target] != nil else { return nil }
        var order: [RunConfiguration] = []
        var visiting = Set<String>()
        var done = Set<String>()
        func visit(_ id: String) -> Bool {
            if done.contains(id) { return true }
            guard let config = byID[id], visiting.insert(id).inserted else { return false }
            for dep in config.dependsOn where !visit(dep) { return false }
            visiting.remove(id)
            done.insert(id)
            order.append(config)
            return true
        }
        return visit(target) ? order : nil
    }

    /// True when something is accepting connections on localhost:port.
    nonisolated static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
