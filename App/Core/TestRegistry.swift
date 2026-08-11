import Foundation

/// One completed run of a suite, kept so the last result survives the app.
struct TestRunRecord: Codable, Equatable, Identifiable {
    var id: String
    var suiteID: String
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int32?
    var summary: TestRunSummary
    var cases: [TestCaseResult]
    /// Tail of the output, for a failure worth reading.
    var logTail: String
    /// Files the run left behind that no single test claimed. Per-test ones
    /// live on the case itself, so a step shows its own screenshot.
    var artifacts: [TestArtifact] = []

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var failedCases: [TestCaseResult] {
        cases.filter { $0.outcome == .failed }
    }

    /// Everything the run produced, per-test files included.
    var allArtifacts: [TestArtifact] {
        cases.flatMap(\.artifacts) + artifacts
    }
}

/// Decoded by hand, in an extension so the memberwise initialiser survives.
///
/// The point is `artifacts`: records written before it existed have no such
/// key, and synthesised decoding would fail the whole file — losing the last
/// result of every suite the moment the app updated.
extension TestRunRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        suiteID = try container.decode(String.self, forKey: .suiteID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        summary = try container.decode(TestRunSummary.self, forKey: .summary)
        cases = try container.decode([TestCaseResult].self, forKey: .cases)
        logTail = try container.decode(String.self, forKey: .logTail)
        artifacts = try container.decodeIfPresent([TestArtifact].self, forKey: .artifacts) ?? []
    }
}

/// Live state of one suite.
struct TestSuiteState: Equatable {
    var isRunning = false
    var startedAt: Date?
    /// The last completed run, whether it passed or not.
    var latest: TestRunRecord?
    /// Streaming output of the run in flight.
    var logTail = ""
    /// The tests the run in flight has reported so far, in the order they
    /// arrived. Empty for a framework whose output is not parsed, and cleared
    /// when the run ends and the record takes over.
    var liveCases: [TestCaseResult] = []

    var liveSummary: TestRunSummary {
        var summary = TestRunSummary(isDetailed: !liveCases.isEmpty)
        for result in liveCases {
            switch result.outcome {
            case .passed: summary.passed += 1
            case .failed: summary.failed += 1
            case .skipped: summary.skipped += 1
            }
        }
        return summary
    }
}

/// Feeds a runner's output to the parser as it arrives, one whole line at a
/// time.
///
/// Output lands in chunks that cut wherever the pipe happened to flush, so a
/// chunk routinely ends mid-line. Parsing a chunk as it comes would drop that
/// line — and the parsers are all line-based, so holding the fragment back
/// until its newline arrives is all it takes to read the same result live that
/// the whole output yields at the end.
struct TestLiveParser {
    let framework: TestFramework
    private var pending = ""

    init(framework: TestFramework) {
        self.framework = framework
    }

    /// The tests this chunk completed. Their messages are not filled in: a
    /// failure's reason is printed somewhere other than the line announcing it,
    /// and often after it, so it is read once at the end from the whole output.
    mutating func consume(_ text: String) -> [TestCaseResult] {
        pending += text
        guard let lastNewline = pending.lastIndex(of: "\n") else { return [] }
        let whole = String(pending[pending.startIndex...lastNewline])
        pending = String(pending[pending.index(after: lastNewline)...])
        return TestOutputParser.cases(in: whole, framework: framework)
    }
}

/// Runs test suites and remembers how they went.
///
/// Peer of `RunRegistry`, and deliberately not the same object: a run is a
/// long-lived process someone watches, a test suite is a short one whose
/// *result* is the point. That difference is why this keeps records and
/// `RunRegistry` keeps handles.
@MainActor
final class TestRegistry: ObservableObject {
    static let shared = TestRegistry()

    struct Key: Hashable {
        let projectID: UUID
        let suiteID: String
    }

    @Published private(set) var states: [Key: TestSuiteState] = [:]

    var launcher: RunProcessLaunching = ShellRunProcessLauncher()
    var dataDirectory: URL = ProjectStore.defaultDirectory()
    /// Reports a failing suite to the Attention Center; nil in tests.
    var reportFailure: ((Project, TestSuiteConfiguration, TestRunRecord) -> Void)? = {
        project, suite, record in
        AttentionStore.shared.report(
            kind: .testFailure,
            title: String(localized: "\(suite.name) failed"),
            detail: record.summary.isDetailed
                ? String(localized: "\(record.summary.failed) of \(record.summary.total) tests failed")
                : String(localized: "The suite exited with a non-zero status"),
            projectID: project.id,
            sessionID: nil,
            id: "test:\(project.id):\(suite.id)"
        )
    }
    /// Cleared when a suite goes green again, so a fixed failure stops nagging.
    var clearFailure: ((Project, TestSuiteConfiguration) -> Void)? = { project, suite in
        AttentionStore.shared.resolve("test:\(project.id):\(suite.id)")
    }

    private static let logTailLimit = 64_000
    /// How many live rows are kept while a suite runs.
    static let liveCaseLimit = 500
    private var handles: [Key: RunProcessHandle] = [:]

    func state(project: Project, suiteID: String) -> TestSuiteState {
        states[Key(projectID: project.id, suiteID: suiteID)] ?? TestSuiteState()
    }

    func resultsDirectory(projectID: UUID) -> URL {
        dataDirectory.appendingPathComponent("projects/\(projectID.uuidString)/tests")
    }

    /// The most recent result of every suite, for the at-a-glance summary.
    func loadPersistedResults(project: Project) {
        for suite in TestConfigFile.load(projectRoot: project.rootURL).suites {
            let key = Key(projectID: project.id, suiteID: suite.id)
            guard states[key]?.latest == nil,
                  let record = Self.loadRecord(
                      suiteID: suite.id, directory: resultsDirectory(projectID: project.id)
                  ) else { continue }
            states[key, default: TestSuiteState()].latest = record
        }
    }

    // MARK: - Running

    @discardableResult
    func run(project: Project, suiteID: String) async -> TestRunRecord? {
        let suites = TestConfigFile.load(projectRoot: project.rootURL).suites
        guard let suite = suites.first(where: { $0.id == suiteID }) else { return nil }
        return await run(project: project, suite: suite)
    }

    @discardableResult
    func run(project: Project, suite: TestSuiteConfiguration) async -> TestRunRecord? {
        let key = Key(projectID: project.id, suiteID: suite.id)
        guard states[key]?.isRunning != true else { return nil }

        let cwd = suite.cwd == "." ? project.rootURL
            : project.rootURL.appendingPathComponent(suite.cwd)
        guard FileManager.default.fileExists(atPath: cwd.path) else { return nil }

        let startedAt = Date()
        states[key] = TestSuiteState(
            isRunning: true, startedAt: startedAt, latest: states[key]?.latest,
            logTail: "", liveCases: []
        )

        // The whole output is kept for parsing, separately from the capped tail
        // shown live: a suite of a thousand tests would otherwise have its
        // early results trimmed away before anything read them.
        let collector = OutputCollector()
        // Parsed as it arrives, so the steps of a long suite appear while it
        // runs instead of all at once when it is over. The same parser reads
        // the whole output again at the end — this is the view, not the record.
        let live = LiveBox(framework: suite.framework)
        // The exit code arrives through the callback rather than being read off
        // the handle afterwards: `RunProcessHandle` reports only whether the
        // process is still running, and by the time it is not, the code is gone.
        let exit = ExitBox()
        let handle: RunProcessHandle
        do {
            handle = try launcher.launch(
                command: suite.command,
                cwd: cwd,
                env: suite.env,
                onOutput: { [weak self] text in
                    collector.append(text)
                    let fresh = live.consume(text)
                    self?.appendTail(text, key: key, cases: fresh)
                },
                onExit: { code in exit.set(code) }
            )
        } catch {
            states[key]?.isRunning = false
            return nil
        }
        handles[key] = handle

        // Both conditions: the process can be gone before the exit callback has
        // landed, and reading the code then would report nil for a suite that
        // actually failed.
        while handle.isRunning || !exit.hasValue {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        handles[key] = nil

        let exitCode = exit.value
        let output = collector.text
        let parsed = TestOutputParser.parse(
            output, framework: suite.framework, exitCode: exitCode
        )
        let finishedAt = Date()
        let root = project.rootURL
        let collected = await Task.detached(priority: .userInitiated) {
            Self.artifacts(
                suite: suite, projectRoot: root,
                startedAt: startedAt, finishedAt: finishedAt
            )
        }.value
        let attached = TestArtifactCollector.attach(collected, to: parsed.cases)
        let record = TestRunRecord(
            id: UUID().uuidString,
            suiteID: suite.id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: exitCode,
            summary: parsed.summary,
            cases: attached.cases,
            logTail: String(output.suffix(Self.logTailLimit)),
            artifacts: attached.unattached
        )
        states[key] = TestSuiteState(
            isRunning: false, startedAt: nil, latest: record, logTail: record.logTail
        )
        Self.saveRecord(record, directory: resultsDirectory(projectID: project.id))
        if record.summary.didPass {
            clearFailure?(project, suite)
        } else {
            reportFailure?(project, suite, record)
        }
        return record
    }

    func stop(project: Project, suiteID: String) {
        let key = Key(projectID: project.id, suiteID: suiteID)
        handles[key]?.terminate()
    }

    /// The files the suite wrote while it ran, if it says where it writes them.
    ///
    /// The listing happens off the main actor: an artifact directory of a few
    /// thousand screenshots is a real directory walk, and doing it here would
    /// stall the window at the exact moment the result lands.
    nonisolated static func artifacts(
        suite: TestSuiteConfiguration, projectRoot: URL,
        startedAt: Date, finishedAt: Date
    ) -> [TestArtifact] {
        guard let directory = TestArtifactCollector.directory(
            for: suite, projectRoot: projectRoot
        ) else { return [] }
        return TestArtifactCollector.collect(
            entries: TestArtifactCollector.scan(directory: directory),
            startedAt: startedAt, finishedAt: finishedAt
        )
    }

    private func appendTail(_ text: String, key: Key, cases: [TestCaseResult] = []) {
        var tail = (states[key]?.logTail ?? "") + text
        if tail.count > Self.logTailLimit {
            tail = String(tail.suffix(Self.logTailLimit))
        }
        states[key, default: TestSuiteState()].logTail = tail
        guard !cases.isEmpty else { return }
        // Capped for the same reason the tail is: a suite of ten thousand tests
        // should cost the window a bounded amount of memory while it runs. The
        // record built at the end keeps every one of them.
        var live = states[key, default: TestSuiteState()].liveCases + cases
        if live.count > Self.liveCaseLimit {
            live = Array(live.suffix(Self.liveCaseLimit))
        }
        states[key]?.liveCases = live
    }

    /// Carries the incremental parser into the launcher's callback, which is
    /// not on the main actor and cannot hold a mutable struct of its own.
    private final class LiveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var parser: TestLiveParser

        init(framework: TestFramework) {
            parser = TestLiveParser(framework: framework)
        }

        func consume(_ text: String) -> [TestCaseResult] {
            lock.lock()
            defer { lock.unlock() }
            return parser.consume(text)
        }
    }

    /// Carries the exit code from the launcher's callback back to the caller.
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32?
        private var landed = false

        func set(_ value: Int32) {
            lock.lock()
            code = value
            landed = true
            lock.unlock()
        }

        var hasValue: Bool {
            lock.lock(); defer { lock.unlock() }
            return landed
        }

        var value: Int32? {
            lock.lock(); defer { lock.unlock() }
            return code
        }
    }

    /// Accumulates output off the main actor's published state.
    ///
    /// A class rather than a captured `var`: the launcher's callback is not on
    /// the main actor, and appending to actor-isolated state from it is exactly
    /// the race that loses the end of a suite's output.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ text: String) {
            lock.lock()
            buffer += text
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    // MARK: - Persistence

    static func recordURL(suiteID: String, directory: URL) -> URL {
        // The id is a slug from detection or an agent, but it reaches the
        // filesystem, so anything that could climb out of the directory is
        // replaced rather than trusted.
        let safe = String(suiteID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return directory.appendingPathComponent("\(safe).json")
    }

    static func loadRecord(suiteID: String, directory: URL) -> TestRunRecord? {
        guard let data = try? Data(contentsOf: recordURL(suiteID: suiteID, directory: directory))
        else { return nil }
        return try? JSONDecoder().decode(TestRunRecord.self, from: data)
    }

    static func saveRecord(_ record: TestRunRecord, directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(
            to: recordURL(suiteID: record.suiteID, directory: directory), options: .atomic
        )
    }
}
