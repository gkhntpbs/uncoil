import Foundation

/// One container as Docker reports it.
struct DockerContainer: Equatable, Identifiable {
    var name: String
    /// Compose service name; empty for a plain `docker run`.
    var service: String
    /// Docker's own state word: running, exited, restarting, created, paused…
    var state: String
    /// Health-check result, when the image declares one. Empty means the image
    /// has no health check — which is not the same as being unhealthy.
    var health: String

    var id: String { name }

    var isRunning: Bool { state == "running" }
    var isUnhealthy: Bool { health == "unhealthy" }
    /// Restarting is the loop a crashing container sits in: the process keeps
    /// coming back, so `docker compose up` never exits and the run looks fine.
    var isRestarting: Bool { state == "restarting" }
}

/// What the containers behind a run add up to.
enum DockerRunHealth: Equatable {
    /// Docker has not been asked yet, or the run owns no containers.
    case unknown
    case allRunning
    /// Running, but something is wrong: a container is restarting, unhealthy,
    /// or has exited while its siblings carry on.
    case degraded(String)
    case allStopped

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unknown: String(localized: "No containers")
        case .allRunning: String(localized: "Containers running")
        case .degraded(let reason): reason
        case .allStopped: String(localized: "Containers stopped")
        }
    }
}

/// Reads Docker's view of a run's containers.
///
/// This exists because a Docker run's process state says almost nothing. `docker
/// compose up` stays alive and keeps printing while a container crash-loops, so
/// the run reads as healthy for as long as the failure lasts. The containers
/// have to be asked directly.
///
/// Parsing is pure and separate from the process call: Docker's `--format json`
/// has shipped as both a JSON array and one object per line depending on the
/// version, and that difference is the part worth pinning down in tests.
enum DockerStatus {
    /// True when this configuration's containers are worth asking about.
    static func isDockerCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("docker compose")
            || normalized.contains("docker-compose")
            || normalized.contains("docker run")
    }

    static func isCompose(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("docker compose") || normalized.contains("docker-compose")
    }

    /// Parses `docker compose ps --format json` or `docker ps --format json`.
    ///
    /// Both shapes are accepted because both are real: Compose v2 emits a JSON
    /// array, older builds and `docker ps` emit one object per line. Anything
    /// unparseable is skipped rather than failing the batch — a single odd line
    /// must not hide every other container.
    static func parse(_ output: String) -> [DockerContainer] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONDecoder().decode([JSONValue].self, from: data) {
            return array.compactMap(container(from:))
        }
        return trimmed.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return container(from: value)
        }
    }

    /// Field names differ between `docker ps` and `docker compose ps` (`Names`
    /// vs `Name`), and older Compose reports no separate `Health` — it is folded
    /// into `Status` as "Up 2 minutes (unhealthy)".
    private static func container(from value: JSONValue) -> DockerContainer? {
        guard let object = value.objectValue else { return nil }
        let name = object["Name"]?.stringValue
            ?? object["Names"]?.stringValue
            ?? ""
        guard !name.isEmpty else { return nil }
        let status = object["Status"]?.stringValue ?? ""
        let state = (object["State"]?.stringValue ?? "").lowercased()
        return DockerContainer(
            name: name,
            service: object["Service"]?.stringValue ?? "",
            state: state.isEmpty ? stateFromStatus(status) : state,
            health: object["Health"]?.stringValue.map { $0.lowercased() }
                ?? healthFromStatus(status)
        )
    }

    /// "Up 2 minutes", "Exited (1) 5 seconds ago", "Restarting (1) 2 seconds ago".
    private static func stateFromStatus(_ status: String) -> String {
        let normalized = status.lowercased()
        if normalized.hasPrefix("up") { return "running" }
        if normalized.hasPrefix("restarting") { return "restarting" }
        if normalized.hasPrefix("exited") { return "exited" }
        if normalized.hasPrefix("created") { return "created" }
        if normalized.hasPrefix("paused") { return "paused" }
        return normalized.isEmpty ? "" : normalized
    }

    private static func healthFromStatus(_ status: String) -> String {
        let normalized = status.lowercased()
        if normalized.contains("(unhealthy)") { return "unhealthy" }
        if normalized.contains("(healthy)") { return "healthy" }
        if normalized.contains("(health: starting)") { return "starting" }
        return ""
    }

    /// The one-line verdict for a run.
    ///
    /// A degraded state is called out rather than averaged away: the whole point
    /// is that "the command is still running" was hiding it.
    static func health(of containers: [DockerContainer]) -> DockerRunHealth {
        guard !containers.isEmpty else { return .unknown }
        if let restarting = containers.first(where: \.isRestarting) {
            return .degraded(String(localized: "\(restarting.name) is restarting"))
        }
        if let unhealthy = containers.first(where: \.isUnhealthy) {
            return .degraded(String(localized: "\(unhealthy.name) is unhealthy"))
        }
        let running = containers.filter(\.isRunning)
        if running.isEmpty { return .allStopped }
        if running.count < containers.count {
            let stopped = containers.count - running.count
            return .degraded(String(localized: "\(stopped) of \(containers.count) containers stopped"))
        }
        return .allRunning
    }

    /// The command that asks Docker about a run's containers.
    ///
    /// Compose is asked about the project in `cwd`; a plain `docker run` is
    /// asked about the one container the detected command names. Returns nil
    /// when the configuration is not a Docker one.
    static func statusArguments(for command: String) -> [String]? {
        guard isDockerCommand(command) else { return nil }
        if isCompose(command) {
            return ["compose", "ps", "--format", "json", "--all"]
        }
        guard let name = runContainerName(in: command) else { return nil }
        return ["ps", "--all", "--filter", "name=^\(name)$", "--format", "json"]
    }

    /// The `--name` a `docker run` was given. Without one the container gets a
    /// random name and there is nothing to look it up by, so nil is the honest
    /// answer rather than a guess at the newest container.
    static func runContainerName(in command: String) -> String? {
        let fields = command.split(separator: " ").map(String.init)
        guard let index = fields.firstIndex(of: "--name"),
              fields.indices.contains(index + 1) else { return nil }
        let name = fields[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return name.isEmpty ? nil : name
    }
}

/// Runs the `docker` CLI and returns its stdout.
protocol DockerProbing: Sendable {
    /// nil when Docker could not be asked at all — not installed, daemon down,
    /// or the command failed. Distinct from an empty answer, which means Docker
    /// replied and there are no containers.
    func run(arguments: [String], cwd: URL) async -> String?
}

struct ShellDockerProbe: DockerProbing {
    /// Looked up rather than assumed: Docker Desktop, Homebrew and Colima each
    /// put the binary somewhere different, and `Process` does not search PATH.
    static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/usr/bin/docker",
    ]

    func run(arguments: [String], cwd: URL) async -> String? {
        guard let binary = Self.candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
