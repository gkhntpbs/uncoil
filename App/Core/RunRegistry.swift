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
        case .idle: String(localized: "idle")
        case .starting: String(localized: "starting")
        case .running: String(localized: "running")
        case .exited: String(localized: "exited")
        case .failed: String(localized: "failed")
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
    /// What Docker says about this run's containers, for a run that owns any.
    ///
    /// Separate from `status` because they answer different questions: `status`
    /// is about the command Uncoil launched, and for `docker compose up` that
    /// command stays alive and keeps printing while a container crash-loops.
    var containers: [DockerContainer] = []
    var containerHealth: DockerRunHealth = .unknown
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
            title: String(localized: "Run '\(config.name)' failed"),
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

    /// Asks Docker about a run's containers. Injectable so the polling logic is
    /// testable without a Docker daemon.
    var dockerProbe: DockerProbing = ShellDockerProbe()
    /// How often a running Docker configuration is asked about its containers.
    var containerPollInterval: TimeInterval = 5

    private var containerPolls: [Key: Task<Void, Never>] = [:]
    private var handles: [Key: RunProcessHandle] = [:]
    private var logHandles: [Key: FileHandle] = [:]
    private var generation: [Key: Int] = [:]
    private var historyIDs: [Key: String] = [:]
    private var managedRuns: [Key: ManagedRunRecord] = [:]
    private var supervisorConnected = false
    private var isQuitting = false
    private var stopping = Set<Key>()

    var activeRuns: [ManagedRunRecord] {
        managedRuns.values.filter { record in
            let status = states[Key(projectID: record.project.id, configID: record.configID)]?.status
            return status == .starting || status == .running
        }.sorted {
            ($0.project.name.localizedLowercase, $0.name.localizedLowercase)
                < ($1.project.name.localizedLowercase, $1.name.localizedLowercase)
        }
    }

    private var supervisorRecordsURL: URL {
        dataDirectory.appendingPathComponent("run-supervisor/runs.json")
    }

    func connectSupervisor() {
        guard !supervisorConnected, !LaunchConfig.shared.isUITesting,
              !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else { return }
        supervisorConnected = true
        if let data = try? Data(contentsOf: supervisorRecordsURL),
           let records = try? JSONDecoder().decode([ManagedRunRecord].self, from: data) {
            for record in records {
                managedRuns[Key(projectID: record.project.id, configID: record.configID)] = record
            }
        }
        RunSupervisor.client.onAliveSessions = { [weak self] alive in
            Task { @MainActor in self?.restoreManagedRuns(alive: alive) }
        }
        RunSupervisor.client.start()
        RunSupervisor.client.requestSessionList()
    }

    private func saveManagedRuns() throws {
        try FileManager.default.createDirectory(
            at: supervisorRecordsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard AtomicFile.write(try JSONEncoder().encode(Array(managedRuns.values)), to: supervisorRecordsURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: supervisorRecordsURL.path)
    }

    private func restoreManagedRuns(alive: Set<UUID>) {
        for (key, record) in managedRuns {
            guard handles[key] == nil else { continue }
            guard alive.contains(record.sessionID) else {
                managedRuns[key] = nil
                states[key]?.status = .exited(-1)
                RunHistoryStore.close(id: record.historyID ?? "", exitCode: nil,
                    runDirectory: runDirectory(projectID: key.projectID))
                continue
            }
            let gen = (generation[key] ?? 0) + 1
            generation[key] = gen
            historyIDs[key] = record.historyID
            states[key] = RunProcessState(status: .starting, startedAt: record.startedAt, logFileURL: record.logURL)
            let config = RunConfigFile.load(projectRoot: record.project.rootURL).configurations
                .first { $0.id == key.configID }
                ?? RunConfiguration(id: record.configID, name: record.name, command: "", ports: record.ports,
                                    previewURL: record.previewURL, quitBehavior: record.quitBehavior)
            let handle = SupervisedRunHandle(sessionID: record.sessionID, client: RunSupervisor.client)
            handles[key] = handle
            RunSupervisor.client.attachExisting(sid: record.sessionID, onData: { [weak self] data in
                Task { @MainActor in self?.appendOutput(String(decoding: data, as: UTF8.self), key: key, generation: gen) }
            }, onExit: { [weak self, weak handle] code in
                Task { @MainActor in
                    handle?.didExit()
                    self?.processExited(code ?? -1, key: key, generation: gen, project: record.project, config: config)
                }
            })
            startContainerPoll(key: key, project: record.project, config: config, generation: gen)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ready = await self.waitForReadiness(key: key, config: config, generation: gen)
                guard self.generation[key] == gen, self.states[key]?.status == .starting else { return }
                if ready { self.states[key]?.status = .running }
                else {
                    self.states[key]?.issue = RunDiagnostics.diagnose(exitCode: nil,
                        logTail: self.states[key]?.logTail ?? "", config: config)
                }
            }
        }
        try? saveManagedRuns()
    }

    func state(project: Project, configID: String) -> RunProcessState {
        let key = Key(projectID: project.id, configID: configID)
        var state = states[key] ?? RunProcessState()
        if let pid = handles[key]?.pid, pid > 0 { state.pid = pid }
        return state
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
        guard !isQuitting else {
            return [StartOutcome(configID: configID, ok: false, status: .failed,
                issue: RunIssue(code: "application_quitting", hint: String(localized: "Uncoil is shutting down. No new project processes can start.")))]
        }
        connectSupervisor()
        if supervisorConnected {
            guard await RunSupervisor.waitUntilReady() else {
                return [StartOutcome(configID: configID, ok: false, status: .failed,
                    issue: RunIssue(code: "supervisor_unavailable", hint: String(localized: "The run supervisor is unavailable. Try again after reconnecting.")))]
            }
            restoreManagedRuns(alive: RunSupervisor.client.aliveSessionIDs())
        }
        guard !isQuitting else { return [] }
        let contents = RunConfigFile.load(projectRoot: project.rootURL)
        guard let order = dependencyOrder(target: configID, in: contents.configurations) else {
            let issue = RunIssue(
                code: contents.configurations.contains(where: { $0.id == configID })
                    ? "dependency_cycle" : "unknown_configuration",
                hint: contents.configurations.contains(where: { $0.id == configID })
                    ? String(localized: "The depends_on chain of '\(configID)' contains a cycle or an unknown id; fix .uncoil/run.json.")
                    : String(localized: "No configuration '\(configID)' in .uncoil/run.json. Use detect/list first.")
            )
            return [StartOutcome(configID: configID, ok: false, status: .failed, issue: issue)]
        }
        var outcomes: [StartOutcome] = []
        for config in order {
            let key = Key(projectID: project.id, configID: config.id)
            if stopping.contains(key) || states[key]?.status == .starting {
                outcomes.append(StartOutcome(configID: config.id, ok: false, status: .starting, issue: nil))
                break
            }
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
                        hint: String(localized: "Prerequisite '\(config.id)' failed (\(outcome.issue?.code ?? "unknown")): ")
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
                hint: String(localized: "Port \(port) is already serving before start. Stop whatever owns it (`lsof -ti :\(port)`), or change the configured port.")
            )
            finishFailure(key: key, project: project, config: config, issue: issue, exitCode: nil)
            return StartOutcome(configID: config.id, ok: false, status: .failed, issue: issue)
        }

        let cwd = config.cwd == "." ? project.rootURL
            : project.rootURL.appendingPathComponent(config.cwd)
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            let issue = RunIssue(
                code: "invalid_cwd",
                hint: String(localized: "Working directory '\(config.cwd)' doesn't exist under the project root; fix 'cwd' in .uncoil/run.json.")
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
            if supervisorConnected, launcher is ShellRunProcessLauncher {
                let sid = UUID()
                let record = ManagedRunRecord(sessionID: sid, project: project, configID: config.id,
                    name: config.name, ports: config.ports, previewURL: config.previewURL,
                    quitBehavior: config.quitBehavior, startedAt: states[key]?.startedAt ?? .now,
                    logURL: logURL, historyID: historyIDs[key])
                managedRuns[key] = record
                do { try saveManagedRuns() } catch {
                    managedRuns[key] = nil
                    throw error
                }
                let supervised = SupervisedRunHandle(sessionID: sid, client: RunSupervisor.client)
                var environment = ProcessInfo.processInfo.environment
                environment.merge(config.env) { _, value in value }
                environment["NO_COLOR"] = environment["NO_COLOR"] ?? "1"
                let shell = environment["SHELL"] ?? "/bin/zsh"
                RunSupervisor.client.open(sid: sid, spec: .init(shell: shell,
                    args: ["-l", "-c", config.command],
                    env: environment.map { "\($0.key)=\($0.value)" }, cwd: cwd.path, runLogPath: logURL.path), cols: 160, rows: 40,
                    onData: { [weak self] data in
                        Task { @MainActor in self?.appendOutput(String(decoding: data, as: UTF8.self), key: key, generation: gen) }
                    }, onExit: { [weak self, weak supervised] code in
                        Task { @MainActor in
                            supervised?.didExit()
                            self?.processExited(code ?? -1, key: key, generation: gen, project: project, config: config)
                        }
                    })
                handle = supervised
            } else {
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
            }
        } catch {
            let issue = RunIssue(
                code: "launch_failed",
                hint: String(localized: "Could not launch the shell: \(error.localizedDescription)")
            )
            finishFailure(key: key, project: project, config: config, issue: issue, exitCode: nil)
            return StartOutcome(configID: config.id, ok: false, status: .failed, issue: issue)
        }
        handles[key] = handle
        states[key]?.pid = handle.pid > 0 ? handle.pid : nil

        startContainerPoll(key: key, project: project, config: config, generation: gen)

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

    /// Polls Docker while a container-backed run is up.
    ///
    /// Only for Docker configurations: every other run's process state already
    /// says everything there is to know, and shelling out for them would be a
    /// subprocess every few seconds for no answer.
    private func startContainerPoll(
        key: Key, project: Project, config: RunConfiguration, generation gen: Int
    ) {
        containerPolls[key]?.cancel()
        guard let arguments = DockerStatus.statusArguments(for: config.command) else { return }
        let cwd = config.cwd == "." ? project.rootURL
            : project.rootURL.appendingPathComponent(config.cwd)
        let interval = containerPollInterval
        let probe = dockerProbe
        containerPolls[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation[key] == gen else { return }
                let output = await probe.run(arguments: arguments, cwd: cwd)
                guard !Task.isCancelled, self.generation[key] == gen else { return }
                let containers = output.map(DockerStatus.parse) ?? []
                // Only publish real changes: this ticks every few seconds and
                // every assignment redraws the Run page.
                if self.states[key]?.containers != containers {
                    self.states[key]?.containers = containers
                    self.states[key]?.containerHealth = DockerStatus.health(of: containers)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopContainerPoll(key: Key) {
        containerPolls[key]?.cancel()
        containerPolls[key] = nil
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
        await stop(key: Key(projectID: project.id, configID: configID))
    }

    private func stop(key: Key) async {
        guard let handle = handles[key], stopping.insert(key).inserted else { return }
        defer { stopping.remove(key) }
        generation[key] = (generation[key] ?? 0) + 1
        stopContainerPoll(key: key)
        handle.terminate()
        let deadline = Date.now.addingTimeInterval(6)
        while handle.isRunning, Date.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if handle.isRunning {
            handle.forceKill()
            states[key]?.issue = RunIssue(code: "stop_pending",
                hint: String(localized: "Waiting for the run supervisor to confirm the process has stopped."))
            return
        }
        handles[key] = nil
        managedRuns[key] = nil
        try? saveManagedRuns()
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

    func stopAll() async {
        let keys = Array(handles.keys)
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { @MainActor in await self.stop(key: key) }
            }
        }
    }

    func prepareForQuit(stopEverything: Bool) async -> Bool {
        isQuitting = true
        connectSupervisor()
        if supervisorConnected {
            guard await RunSupervisor.waitUntilReady() else {
                isQuitting = false
                return managedRuns.isEmpty && handles.isEmpty
            }
            restoreManagedRuns(alive: RunSupervisor.client.aliveSessionIDs())
        }
        let keys = Array(handles.keys).filter { key in
            guard !stopEverything else { return true }
            guard let record = managedRuns[key] else { return true }
            let config = RunConfigFile.load(projectRoot: record.project.rootURL).configurations
                .first { $0.id == key.configID }
            return (config?.quitBehavior ?? record.quitBehavior) == .stopOnQuit
        }
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { @MainActor in await self.stop(key: key) }
            }
        }
        let stopped = keys.allSatisfy { handles[$0] == nil }
        if !stopped { isQuitting = false }
        return stopped
    }

    func disconnectSupervisor(shutdown: Bool) {
        RunSupervisor.client.prepareForApplicationTermination(terminateSessions: shutdown, managedRuns: true)
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
        if managedRuns[key] == nil, let data = text.data(using: .utf8) {
            logHandles[key]?.write(data)
        }
    }

    private func processExited(
        _ code: Int32, key: Key, generation gen: Int, project: Project, config: RunConfiguration
    ) {
        guard generation[key] == gen else { return }
        handles[key] = nil
        managedRuns[key] = nil
        try? saveManagedRuns()
        stopContainerPoll(key: key)
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
