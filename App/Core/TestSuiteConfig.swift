import Foundation

/// The framework a suite's output comes from.
///
/// This exists to decide how far the output can be trusted to be read. Each
/// case is a format whose plain-text shape is documented and stable enough to
/// parse per test; `unknown` is the honest answer for everything else, and a
/// suite marked that way reports a pass/fail total from the exit code rather
/// than inventing a per-test breakdown from output it does not understand.
enum TestFramework: String, Codable, CaseIterable {
    case swift
    case xcodebuild
    case go
    case cargo
    case pytest
    case jest
    case unknown

    /// Whether individual test names and outcomes can be recovered.
    var reportsIndividualTests: Bool { self != .unknown }

    var displayName: String {
        switch self {
        case .swift: "Swift Package Manager"
        case .xcodebuild: "xcodebuild"
        case .go: "go test"
        case .cargo: "cargo test"
        case .pytest: "pytest"
        case .jest: "Jest / Vitest"
        case .unknown: String(localized: "Unrecognised")
        }
    }
}

/// One test suite of a project: a command, where to run it, and which output
/// format to expect.
///
/// Deliberately the same shape and the same ownership model as
/// `RunConfiguration` — a project-owned JSON file both the user and an agent
/// can read and repair, with no hidden copy in the app.
struct TestSuiteConfiguration: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var command: String
    /// Relative to the project root; "." for the root itself.
    var cwd: String
    var env: [String: String]
    var framework: TestFramework
    /// The suite `{"action":"test_run"}` resolves to with no id.
    var isDefault: Bool
    var source: RunConfigSource
    var notes: String?
    /// Unknown JSON keys, preserved verbatim so an agent can annotate a suite
    /// without the app erasing it.
    var extra: [String: JSONValue]

    init(
        id: String,
        name: String = "",
        command: String,
        cwd: String = ".",
        env: [String: String] = [:],
        framework: TestFramework = .unknown,
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
        self.framework = framework
        self.isDefault = isDefault
        self.source = source
        self.notes = notes
        self.extra = extra
    }

    static let knownKeys: Set<String> = [
        "id", "name", "command", "cwd", "env", "framework", "default", "source", "notes",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let command = object["command"]?.stringValue, !command.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "a suite needs 'id' and 'command'"
            )
        }
        self.init(
            id: id,
            name: object["name"]?.stringValue ?? id,
            command: command,
            cwd: object["cwd"]?.stringValue ?? ".",
            env: (object["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
            framework: object["framework"]?.stringValue
                .flatMap(TestFramework.init(rawValue:)) ?? .unknown,
            isDefault: object["default"]?.boolValue ?? false,
            source: object["source"]?.stringValue
                .flatMap(RunConfigSource.init(rawValue:)) ?? .user,
            notes: object["notes"]?.stringValue,
            extra: object.filter { !Self.knownKeys.contains($0.key) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(asJSON())
    }

    func asJSON() -> JSONValue {
        var object: [String: JSONValue] = extra
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["command"] = .string(command)
        object["cwd"] = .string(cwd)
        if !env.isEmpty { object["env"] = .object(env.mapValues(JSONValue.string)) }
        object["framework"] = .string(framework.rawValue)
        if isDefault { object["default"] = .bool(true) }
        object["source"] = .string(source.rawValue)
        if let notes { object["notes"] = .string(notes) }
        return .object(object)
    }
}

/// Loads and saves `.uncoil/tests.json`. Tolerant in the same way `run.json` is:
/// one malformed entry is skipped and reported rather than failing the file, so
/// a bad agent edit never bricks the feature.
enum TestConfigFile {
    static let relativePath = ".uncoil/tests.json"

    struct Contents: Equatable {
        var suites: [TestSuiteConfiguration] = []
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
        for (index, entry) in (object["suites"]?.arrayValue ?? []).enumerated() {
            guard let entryData = try? JSONEncoder().encode(entry),
                  let suite = try? JSONDecoder().decode(
                      TestSuiteConfiguration.self, from: entryData
                  )
            else {
                contents.problems.append("suites[\(index)] is missing 'id' or 'command'; skipped")
                continue
            }
            guard seen.insert(suite.id).inserted else {
                contents.problems.append("duplicate suite id '\(suite.id)'; kept the first")
                continue
            }
            contents.suites.append(suite)
        }
        return contents
    }

    static func defaultSuite(_ suites: [TestSuiteConfiguration]) -> TestSuiteConfiguration? {
        suites.first(where: \.isDefault) ?? (suites.count == 1 ? suites[0] : nil)
    }

    static func save(_ suites: [TestSuiteConfiguration], projectRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = JSONValue.object([
            "version": .int(1),
            "suites": .array(suites.map { $0.asJSON() }),
        ])
        let data = try encoder.encode(document)
        let fileURL = url(projectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    /// Same rule as run configurations: detection may add, never overwrite what
    /// a user or an agent wrote.
    static func merge(
        existing: [TestSuiteConfiguration],
        suggestions: [TestSuiteConfiguration],
        replacingDetected: Bool
    ) -> [TestSuiteConfiguration] {
        var kept = replacingDetected ? existing.filter { $0.source != .detected } : existing
        let taken = Set(kept.map(\.id))
        kept += suggestions.filter { !taken.contains($0.id) }
        return kept
    }
}
