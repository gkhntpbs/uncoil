import Foundation

/// Where a run configuration came from. Detection may only ever add or replace
/// `.detected` entries; anything a user or agent wrote is stable until they
/// change it themselves.
enum RunConfigSource: String, Codable {
    case detected
    case user
    case agent
}

/// One runnable dev workflow of a project: a shell command with a working
/// directory, environment, optional ports/preview URL, readiness signal, and
/// prerequisites. Lives in the project-owned `.uncoil/run.json` so both the
/// user and coding agents can review and repair it; the app holds no hidden
/// copy of these fields.
struct RunConfiguration: Codable, Equatable, Identifiable {
    /// Stable slug (e.g. "web-dev"). Referenced by `depends_on` and MCP calls.
    let id: String
    var name: String
    /// Executed via the user's login shell (`$SHELL -l -c "exec …"`).
    var command: String
    /// Relative to the project root; "." for the root itself.
    var cwd: String
    var env: [String: String]
    var ports: [Int]
    var previewURL: String?
    /// Regex matched against output to declare the process "running". When nil,
    /// an open `ports` entry or a short survival grace period is used instead.
    var readyPattern: String?
    /// Configuration ids that must be running before this one starts.
    var dependsOn: [String]
    /// The project's default configuration: the one the session header's run
    /// button and id-less MCP calls (`{"action":"start"}`) resolve to. At most
    /// one entry should carry it; writers clear the flag elsewhere on set.
    var isDefault: Bool
    var source: RunConfigSource
    var notes: String?
    /// Unknown JSON keys found in the file, preserved verbatim on rewrite so
    /// agents can annotate configurations without the app erasing them.
    var extra: [String: JSONValue]

    init(
        id: String,
        name: String = "",
        command: String,
        cwd: String = ".",
        env: [String: String] = [:],
        ports: [Int] = [],
        previewURL: String? = nil,
        readyPattern: String? = nil,
        dependsOn: [String] = [],
        isDefault: Bool = false,
        source: RunConfigSource = .detected,
        notes: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.ports = ports
        self.previewURL = previewURL
        self.readyPattern = readyPattern
        self.dependsOn = dependsOn
        self.isDefault = isDefault
        self.source = source
        self.notes = notes
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "name", "command", "cwd", "env", "ports", "preview_url",
        "ready_pattern", "depends_on", "default", "source", "notes",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(JSONValue.self)
        guard let object = raw.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let command = object["command"]?.stringValue
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "run configuration requires string 'id' and 'command'"
            ))
        }
        var env: [String: String] = [:]
        for (key, value) in object["env"]?.objectValue ?? [:] {
            if let string = value.stringValue { env[key] = string }
        }
        self.init(
            id: id,
            name: object["name"]?.stringValue ?? id,
            command: command,
            cwd: object["cwd"]?.stringValue ?? ".",
            env: env,
            ports: (object["ports"]?.arrayValue ?? []).compactMap(\.intValue),
            previewURL: object["preview_url"]?.stringValue,
            readyPattern: object["ready_pattern"]?.stringValue,
            dependsOn: (object["depends_on"]?.arrayValue ?? []).compactMap(\.stringValue),
            isDefault: object["default"]?.boolValue ?? false,
            source: object["source"]?.stringValue.flatMap(RunConfigSource.init(rawValue:)) ?? .user,
            notes: object["notes"]?.stringValue,
            extra: object.filter { !Self.knownKeys.contains($0.key) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(asJSON())
    }

    /// The wire/file shape; identical for `.uncoil/run.json` and MCP responses.
    func asJSON() -> JSONValue {
        var object: [String: JSONValue] = extra
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["command"] = .string(command)
        object["cwd"] = .string(cwd)
        if !env.isEmpty { object["env"] = .object(env.mapValues(JSONValue.string)) }
        if !ports.isEmpty { object["ports"] = .array(ports.map(JSONValue.int)) }
        if let previewURL { object["preview_url"] = .string(previewURL) }
        if let readyPattern { object["ready_pattern"] = .string(readyPattern) }
        if !dependsOn.isEmpty { object["depends_on"] = .array(dependsOn.map(JSONValue.string)) }
        if isDefault { object["default"] = .bool(true) }
        object["source"] = .string(source.rawValue)
        if let notes { object["notes"] = .string(notes) }
        return .object(object)
    }
}

/// Loads and saves `.uncoil/run.json` at a project (or worktree) root. Reads
/// are tolerant: individual malformed entries are skipped and reported instead
/// of failing the whole file, so one bad agent edit never bricks the feature.
enum RunConfigFile {
    static let relativePath = ".uncoil/run.json"

    struct Contents: Equatable {
        var configurations: [RunConfiguration] = []
        /// Human-readable notes about entries that could not be decoded.
        var problems: [String] = []
    }

    static func url(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    static func load(projectRoot: URL) -> Contents {
        guard let data = try? Data(contentsOf: url(projectRoot: projectRoot)) else {
            return Contents()
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Contents {
        var contents = Contents()
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = raw.objectValue
        else {
            contents.problems.append("\(relativePath) is not a JSON object; ignoring it")
            return contents
        }
        var seen = Set<String>()
        for (index, entry) in (object["configurations"]?.arrayValue ?? []).enumerated() {
            guard let entryData = try? JSONEncoder().encode(entry),
                  let config = try? JSONDecoder().decode(RunConfiguration.self, from: entryData)
            else {
                contents.problems.append("configurations[\(index)] is missing 'id' or 'command'; skipped")
                continue
            }
            guard seen.insert(config.id).inserted else {
                contents.problems.append("duplicate configuration id '\(config.id)'; kept the first")
                continue
            }
            contents.configurations.append(config)
        }
        return contents
    }

    /// The configuration id-less operations resolve to: the one flagged
    /// `default`, or — when the project has exactly one — that one.
    static func defaultConfiguration(_ configurations: [RunConfiguration]) -> RunConfiguration? {
        configurations.first(where: \.isDefault)
            ?? (configurations.count == 1 ? configurations[0] : nil)
    }

    /// Marks `id` as the sole default and persists.
    static func setDefault(_ id: String, projectRoot: URL) throws {
        var configs = load(projectRoot: projectRoot).configurations
        configs = configs.map { config in
            var config = config
            config.isDefault = config.id == id
            return config
        }
        try save(configs, projectRoot: projectRoot)
    }

    static func save(_ configurations: [RunConfiguration], projectRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = JSONValue.object([
            "version": .int(1),
            "configurations": .array(configurations.map { $0.asJSON() }),
        ])
        let data = try encoder.encode(document)
        let fileURL = url(projectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
