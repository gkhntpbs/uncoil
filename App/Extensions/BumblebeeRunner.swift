import Foundation

/// Finds the Bumblebee binary, in Uncoil's order of preference.
///
/// Installing one is never done here: fetching and running a third-party binary
/// is the user's decision, and this only reports what is already present.
struct BumblebeeLocator {
    /// Inside the app bundle, when a build pinned one.
    var pinnedPath: String?
    /// Uncoil's own tools directory.
    var managedDirectory: URL
    /// Overridable so tests need no real binary anywhere.
    var exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var pathLookup: () -> String? = { AgentAdapterSupport.locateBinary("bumblebee") }

    static func `default`(bundle: Bundle = .main) -> BumblebeeLocator {
        BumblebeeLocator(
            pinnedPath: bundle.url(forAuxiliaryExecutable: "bumblebee")?.path,
            managedDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".uncoil/tools", isDirectory: true)
        )
    }

    var managedPath: String {
        managedDirectory.appendingPathComponent("bumblebee").path
    }

    /// The first source that actually has a binary, in preference order.
    func resolve() -> BumblebeeBinary? {
        if let pinnedPath, exists(pinnedPath) {
            return BumblebeeBinary(source: .pinned, path: pinnedPath)
        }
        if exists(managedPath) {
            return BumblebeeBinary(source: .managed, path: managedPath)
        }
        if let found = pathLookup(), exists(found) {
            return BumblebeeBinary(source: .path, path: found)
        }
        return nil
    }

    /// The exposure catalog that ships with the release, which lives next to the
    /// binary as `threat_intel/`. Without it a scan reports inventory and never a
    /// finding, so this is not optional detail — it is what makes a scan a scan.
    func catalogDirectory(for binary: BumblebeeBinary) -> String? {
        let candidate = URL(fileURLWithPath: binary.path)
            .deletingLastPathComponent()
            .appendingPathComponent("threat_intel", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return candidate.path
    }

    /// Every source that has one, for the UI to explain which was chosen.
    func available() -> [BumblebeeBinary] {
        var result: [BumblebeeBinary] = []
        if let pinnedPath, exists(pinnedPath) {
            result.append(BumblebeeBinary(source: .pinned, path: pinnedPath))
        }
        if exists(managedPath) {
            result.append(BumblebeeBinary(source: .managed, path: managedPath))
        }
        if let found = pathLookup(), exists(found) {
            result.append(BumblebeeBinary(source: .path, path: found))
        }
        return result
    }
}

/// Runs Bumblebee and turns its output into results Uncoil can act on.
///
/// Every process call is injected. That keeps the decisions — what counts as a
/// finished scan, when a result may be trusted, what happens when two scans are
/// asked for at once — testable without the binary being installed, and it means
/// nothing here can start a real process by accident.
struct BumblebeeRunner {
    struct Invocation: Equatable {
        var arguments: [String]
        var timeout: TimeInterval
    }

    struct Output: Equatable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
    }

    enum RunError: LocalizedError, Equatable {
        case notInstalled
        case alreadyRunning(BumblebeeScanKind)
        case selfTestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Bumblebee is not installed. Installing it needs your approval."
            case .alreadyRunning(let kind):
                "A scan is already running (\(kind.label)); a second one was not started."
            case .selfTestFailed(let detail):
                "Bumblebee self-test failed: \(detail)"
            }
        }
    }

    var binary: BumblebeeBinary?
    /// Injected process call.
    var run: (Invocation) async throws -> Output
    /// Shared across a process; what stops two scans running at once.
    var lock: BumblebeeScanLock
    /// The exposure catalog directory shipped with the binary. Without it the
    /// scanner emits inventory only and never a single finding, so a scan run
    /// without one is not a clean bill of health.
    var catalogPath: String?

    // MARK: - Command line

    /// The exact command line for a scan.
    ///
    /// Pure and separate because it is the one place Uncoil has to match a binary
    /// it does not own: `bumblebee scan --profile <p> [--exposure-catalog <c>]
    /// [--root <path>]…`.
    static func scanArguments(
        kind: BumblebeeScanKind,
        paths: [String],
        catalogPath: String?
    ) -> [String] {
        var arguments = ["scan", "--profile", profile(for: kind, paths: paths)]
        if let catalogPath { arguments += ["--exposure-catalog", catalogPath] }
        for path in paths { arguments += ["--root", path] }
        return arguments
    }

    /// Bumblebee's own profiles: `baseline` for the machine's known roots,
    /// `project` for the roots we hand it, `deep` for the incident sweep.
    static func profile(for kind: BumblebeeScanKind, paths: [String]) -> String {
        switch kind {
        case .deep: "deep"
        default: paths.isEmpty ? "baseline" : "project"
        }
    }

    // MARK: - Verification

    /// Reads the version, so a finding can be traced to the build that made it.
    func version(now: Date = .now) async throws -> BumblebeeVersion {
        guard binary != nil else { throw RunError.notInstalled }
        let output = try await run(Invocation(arguments: ["version"], timeout: 15))
        guard let version = BumblebeeVersion.parse(output.stdout)
            ?? BumblebeeVersion.parse(output.stderr) else {
            throw RunError.selfTestFailed("the version could not be read")
        }
        return version
    }

    func selfTest(now: Date = .now) async throws -> BumblebeeSelfTest {
        guard binary != nil else { throw RunError.notInstalled }
        // `-quiet` is the only flag this subcommand takes; the exit code is the
        // verdict.
        let output = try await run(Invocation(arguments: ["selftest", "-quiet"], timeout: 60))
        return BumblebeeSelfTest.parse(
            output.stdout.isEmpty ? output.stderr : output.stdout,
            exitCode: output.exitCode,
            now: now
        )
    }

    // MARK: - Scanning

    /// Runs one scan. Refuses when the binary is missing, when another scan holds
    /// the lock, or when the self-test did not pass — a scan from a binary that
    /// cannot verify itself is not evidence.
    func scan(
        kind: BumblebeeScanKind,
        paths: [String],
        now: Date = .now
    ) async throws -> BumblebeeScanResult {
        guard binary != nil else { throw RunError.notInstalled }
        if let running = lock.current { throw RunError.alreadyRunning(running) }

        let selfTest = try await selfTest(now: now)
        let version = try? await version(now: now)
        guard selfTest.resultsAreTrustworthy else {
            throw RunError.selfTestFailed(selfTest.detail)
        }

        lock.acquire(kind)
        defer { lock.release() }

        let arguments = Self.scanArguments(
            kind: kind, paths: paths, catalogPath: catalogPath
        )

        let started = now
        let output = try await run(Invocation(arguments: arguments, timeout: kind.timeout))
        let events = BumblebeeOutputParser.parseStdout(output.stdout, now: now)
        var findings: [SecurityFinding] = []
        var diagnostics = BumblebeeOutputParser.parseStderr(output.stderr)
        var summary: BumblebeeScanSummary?
        var unknown: [String] = []
        for event in events {
            switch event {
            case .finding(let finding): findings.append(finding)
            case .diagnostic(let message): diagnostics.append(message)
            case .summary(let value): summary = value
            case .package: break
            case .unknown(let line): unknown.append(line)
            }
        }
        return BumblebeeScanResult(
            kind: kind,
            findings: findings,
            diagnostics: diagnostics,
            summary: summary,
            unknownLines: unknown,
            exitCode: output.exitCode,
            timedOut: output.timedOut,
            selfTest: selfTest,
            version: version,
            startedAt: started,
            finishedAt: now
        )
    }

    /// The real process call, used by the app. Enforces the timeout by killing
    /// the child, so a hung scan cannot hold the lock forever.
    static func processRunner(binaryPath: String) -> (Invocation) async throws -> Output {
        { invocation in
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = invocation.arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + invocation.timeout, execute: deadline
                )
                // Same 4 MB cap `ProcessRunner` applies: the scanner's report
                // is bounded, only a misbehaving run would exceed it, and an
                // uncapped drain would buffer whatever it emits in full.
                let maxOutputBytes = 4 * 1_024 * 1_024
                func drain(_ handle: FileHandle) -> Data {
                    var collected = Data()
                    while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                        if collected.count < maxOutputBytes {
                            collected.append(chunk.prefix(maxOutputBytes - collected.count))
                        }
                    }
                    return collected
                }
                let stdout = drain(out.fileHandleForReading)
                let stderr = drain(err.fileHandleForReading)
                process.waitUntilExit()
                let timedOut = deadline.isCancelled == false && process.terminationReason == .uncaughtSignal
                deadline.cancel()
                continuation.resume(returning: Output(
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitCode: process.terminationStatus,
                    timedOut: timedOut
                ))
            }
        }
    }
}

/// Single-scan lock. One scan at a time, whoever asks.
final class BumblebeeScanLock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.bumblebee.lock")
    private var running: BumblebeeScanKind?

    var current: BumblebeeScanKind? {
        queue.sync { running }
    }

    func acquire(_ kind: BumblebeeScanKind) {
        queue.sync { running = kind }
    }

    func release() {
        queue.sync { running = nil }
    }

    /// Takes the lock only when it is free, for callers that must not block.
    func tryAcquire(_ kind: BumblebeeScanKind) -> Bool {
        queue.sync {
            guard running == nil else { return false }
            running = kind
            return true
        }
    }
}

/// The lock files Bumblebee reads, and Uncoil's own fuller one.
///
/// Two files on purpose: `.skill-lock.json` is the shape Bumblebee expects, and
/// `extensions.lock.json` is what Uncoil needs to reproduce an install — the
/// second must not be squeezed into the first's schema.
enum ExtensionLockFiles {
    struct SkillLockEntry: Equatable, Codable {
        var name: String
        var path: String
        var source: String
        var repository: String?
        var commit: String?
        var ref: String?
        /// True for a folder the user added by hand, so a scanner does not treat
        /// it as something Uncoil vouches for.
        var isManual: Bool
    }

    struct SkillLock: Equatable, Codable {
        var version = 1
        var generatedBy = "uncoil"
        var generatedAt: Date
        var skills: [SkillLockEntry]
    }

    struct ExtensionsLock: Equatable, Codable {
        struct Entry: Equatable, Codable {
            var id: String
            var name: String
            var kind: ExtensionKind
            var sourceLabel: String
            var repository: String?
            var commit: String?
            var tracking: String?
            var revisionID: String?
            var contentHash: String?
            var state: ExtensionState
            var agents: [String]
            var isManual: Bool
        }

        var version = 1
        var generatedAt: Date
        var appVersion: String
        var entries: [Entry]
    }

    /// The Bumblebee-facing lock: active managed skills, plus manual ones marked
    /// as such.
    static func skillLock(
        packages: [ExtensionPackage],
        generatedAt: Date
    ) -> SkillLock {
        let entries = packages
            .filter { $0.kind == .skill && $0.state == .active }
            .sorted { $0.name < $1.name }
            .map { package -> SkillLockEntry in
                var repository: String?
                var ref: String?
                if case .managedGitHub(let value, _, let tracking) = package.source {
                    repository = value
                    ref = tracking.label
                }
                return SkillLockEntry(
                    name: package.name,
                    path: package.activeRevision?.path ?? "",
                    source: package.source.label,
                    repository: repository,
                    commit: package.activeRevision?.commitSHA,
                    ref: ref,
                    isManual: !package.source.isOwnedByUncoil
                )
            }
        return SkillLock(generatedAt: generatedAt, skills: entries)
    }

    /// Uncoil's own record: everything needed to put the same set back.
    static func extensionsLock(
        packages: [ExtensionPackage],
        agents: (String) -> [ExtensionAgentID],
        appVersion: String,
        generatedAt: Date
    ) -> ExtensionsLock {
        ExtensionsLock(
            generatedAt: generatedAt,
            appVersion: appVersion,
            entries: packages.sorted { $0.id < $1.id }.map { package in
                var repository: String?
                var tracking: String?
                if case .managedGitHub(let value, _, let mode) = package.source {
                    repository = value
                    tracking = mode.label
                }
                return ExtensionsLock.Entry(
                    id: package.id,
                    name: package.name,
                    kind: package.kind,
                    sourceLabel: package.source.label,
                    repository: repository,
                    commit: package.activeRevision?.commitSHA,
                    tracking: tracking,
                    revisionID: package.activeRevision?.id,
                    contentHash: package.activeRevision?.contentHash,
                    state: package.state,
                    agents: agents(package.id).map(\.rawValue),
                    isManual: !package.source.isOwnedByUncoil
                )
            }
        )
    }

    static func write(
        _ lock: SkillLock,
        to url: URL
    ) throws {
        try write(value: lock, to: url)
    }

    static func write(
        _ lock: ExtensionsLock,
        to url: URL
    ) throws {
        try write(value: lock, to: url)
    }

    private static func write<T: Encodable>(value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// `~/.agents/.skill-lock.json` by default.
    static func defaultSkillLockURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".agents/.skill-lock.json")
    }
}
