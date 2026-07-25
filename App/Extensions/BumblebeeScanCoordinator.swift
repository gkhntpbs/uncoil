import Foundation

/// Decides when a Bumblebee scan runs and what it covers.
///
/// Split from the runner so the "when" is testable on its own: every trigger is a
/// pure decision about kind and paths, and the coordinator is what the app and
/// the UI call. A missing binary is not an error here — it is the ordinary case
/// until the user installs one, and the answer is a plain "not run".
@MainActor
final class BumblebeeScanCoordinator: ObservableObject {
    enum Outcome: Equatable {
        case notInstalled
        case skipped(reason: String)
        case ran(findings: Int, usable: Bool)
        case failed(String)

        var message: String {
            switch self {
            case .notInstalled:
                "Bumblebee kurulu değil; tarama yapılmadı. Kurulum senin onayınla olur."
            case .skipped(let reason): "Tarama atlandı: \(reason)"
            case .ran(let findings, true): "Tarama bitti: \(findings) bulgu."
            case .ran(let findings, false):
                "Tarama tamamlanmadı; \(findings) bulgu current state sayılmadı."
            case .failed(let detail): "Tarama başarısız: \(detail)"
            }
        }

        var didRun: Bool {
            if case .ran = self { return true }
            return false
        }
    }

    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var isScanning = false

    private let registry: ExtensionRegistry
    private let locator: BumblebeeLocator
    private let lock: BumblebeeScanLock
    /// Injected so tests never touch a real process.
    private let makeRunner: (BumblebeeBinary, BumblebeeScanLock) -> BumblebeeRunner

    init(
        registry: ExtensionRegistry,
        locator: BumblebeeLocator = .default(),
        lock: BumblebeeScanLock = BumblebeeScanLock(),
        makeRunner: ((BumblebeeBinary, BumblebeeScanLock) -> BumblebeeRunner)? = nil
    ) {
        self.registry = registry
        self.locator = locator
        self.lock = lock
        let resolvedLocator = locator
        self.makeRunner = makeRunner ?? { binary, lock in
            BumblebeeRunner(
                binary: binary,
                run: BumblebeeRunner.processRunner(binaryPath: binary.path),
                lock: lock,
                catalogPath: resolvedLocator.catalogDirectory(for: binary)
            )
        }
    }

    var isInstalled: Bool { locator.resolve() != nil }

    /// Asks the binary what it is and makes it prove it works, recording both so
    /// the Security screen can show a version instead of "bilinmiyor". Runs no
    /// scan: this is the check the user makes right after installing.
    func verifyBinary(now: Date = .now) async -> String {
        guard let binary = locator.resolve() else {
            _ = finish(.notInstalled)
            return Outcome.notInstalled.message
        }
        let runner = makeRunner(binary, lock)
        let version = try? await runner.version(now: now)
        do {
            let selfTest = try await runner.selfTest(now: now)
            registry.record(verification: version, selfTest: selfTest)
            return selfTest.passed
                ? "Doğrulandı: \(version?.label ?? "sürüm okunamadı") · self-test geçti."
                : "Self-test başarısız: \(selfTest.detail)"
        } catch {
            registry.record(verification: version, selfTest: nil)
            return "Doğrulama yapılamadı: \(error.localizedDescription)"
        }
    }

    // MARK: - Triggers

    /// At launch: only when the last scan is old enough to be worth redoing.
    @discardableResult
    func scanAtLaunchIfStale(now: Date = .now) async -> Outcome {
        guard let kind = BumblebeeSchedule.atLaunch(
            lastScanAt: registry.lastBumblebeeScanAt, now: now
        ) else {
            return finish(.skipped(reason: "son tarama yeterince yeni"))
        }
        return await run(kind: kind, paths: managedPaths(), now: now)
    }

    /// Before an extension is installed or adopted.
    @discardableResult
    func scanBeforeInstall(path: String, now: Date = .now) async -> Outcome {
        await run(kind: .beforeInstall, paths: [path], now: now)
    }

    /// Around an update: the revision about to be activated, then the one that is.
    @discardableResult
    func scanBeforeUpdate(stagedPath: String, now: Date = .now) async -> Outcome {
        await run(kind: .beforeUpdate, paths: [stagedPath], now: now)
    }

    @discardableResult
    func scanAfterUpdate(activePath: String, now: Date = .now) async -> Outcome {
        await run(kind: .afterUpdate, paths: [activePath], now: now)
    }

    /// The daily baseline, while the app is running. The same scan is what the
    /// daemon is meant to run when the app is closed.
    @discardableResult
    func scanDailyBaselineIfDue(now: Date = .now) async -> Outcome {
        let due = BumblebeeSchedule.nextBaseline(
            after: registry.lastBumblebeeScanAt, now: now
        )
        guard now >= due else {
            return finish(.skipped(reason: "günlük baseline zamanı gelmedi"))
        }
        return await run(kind: .dailyBaseline, paths: managedPaths(), now: now)
    }

    @discardableResult
    func scanManually(now: Date = .now) async -> Outcome {
        await run(kind: .manual, paths: managedPaths(), now: now)
    }

    /// A project's own roots, for the scan that looks at what the user is working
    /// on rather than at what Uncoil installed.
    @discardableResult
    func scanProjects(roots: [String], now: Date = .now) async -> Outcome {
        guard !roots.isEmpty else {
            return finish(.skipped(reason: "taranacak proje yok"))
        }
        return await run(kind: .project, paths: roots, now: now)
    }

    /// Everything, slowly, for when something already went wrong.
    @discardableResult
    func deepScan(extraPaths: [String] = [], now: Date = .now) async -> Outcome {
        await run(kind: .deep, paths: managedPaths() + extraPaths, now: now)
    }

    /// Hands the daily baseline to the daemon so it keeps happening while the app
    /// is closed. Returns what was asked for, or why nothing was.
    @discardableResult
    func scheduleInDaemon(
        client: RuntimeClient = .shared,
        now: Date = .now
    ) -> Outcome {
        guard let binary = locator.resolve() else { return finish(.notInstalled) }
        let paths = managedPaths()
        guard !paths.isEmpty else {
            return finish(.skipped(reason: "Bumblebee kapsamında dosya yok"))
        }
        client.scheduleScan(
            binaryPath: binary.path,
            arguments: ["scan", "--ndjson"] + paths,
            intervalSeconds: BumblebeeSchedule.staleAfter,
            timeoutSeconds: BumblebeeScanKind.dailyBaseline.timeout,
            outputPath: registry.layout.scans
                .appendingPathComponent("daemon-baseline.ndjson").path
        )
        return finish(.skipped(reason: "günlük baseline daemon'a bırakıldı"))
    }

    /// Reads what the daemon's scan left behind, so a scan that ran while the app
    /// was closed still reaches the registry.
    @discardableResult
    func importDaemonResult(now: Date = .now) -> Outcome {
        let url = registry.layout.scans.appendingPathComponent("daemon-baseline.ndjson")
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return finish(.skipped(reason: "daemon taramasından sonuç yok"))
        }
        var findings: [SecurityFinding] = []
        var diagnostics: [String] = []
        var summary: BumblebeeScanSummary?
        var unknown: [String] = []
        for event in BumblebeeOutputParser.parseStdout(text, now: now) {
            switch event {
            case .finding(let finding): findings.append(finding)
            case .diagnostic(let message): diagnostics.append(message)
            case .summary(let value): summary = value
            case .package: break
            case .unknown(let line): unknown.append(line)
            }
        }
        // The daemon does not run the self-test, so the one the app recorded last
        // is what this result is judged against — and without one it is not taken
        // as the current state.
        let result = BumblebeeScanResult(
            kind: .dailyBaseline,
            findings: findings,
            diagnostics: diagnostics,
            summary: summary,
            unknownLines: unknown,
            exitCode: 0,
            timedOut: false,
            selfTest: registry.bumblebeeSelfTest,
            version: registry.bumblebeeVersion,
            startedAt: now,
            finishedAt: now
        )
        let usable = registry.record(scan: result)
        try? FileManager.default.removeItem(at: url)
        return finish(.ran(findings: result.bumblebeeFindings.count, usable: usable))
    }

    // MARK: - Running

    /// What a store-wide scan covers: the revisions Uncoil installed. Anything
    /// outside its reach is reported as a coverage gap instead of pretended over.
    func managedPaths() -> [String] {
        // The store as a whole, plus the shared skills location: one root each
        // rather than a path per package, which is both what the scanner wants
        // and what keeps a scan from missing an extension the registry forgot.
        let storeRoots = [
            registry.layout.revisions.path,
            registry.layout.activeSkills.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agents/skills", isDirectory: true).path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
        let packageRoots = registry.packages
            .filter { BumblebeeCoverage.isCovered($0) }
            .compactMap { $0.activeRevision?.path }
        return Array(Set(storeRoots + packageRoots)).sorted()
    }

    private func run(
        kind: BumblebeeScanKind,
        paths: [String],
        now: Date
    ) async -> Outcome {
        guard let binary = locator.resolve() else { return finish(.notInstalled) }
        guard !paths.isEmpty else {
            return finish(.skipped(reason: "Bumblebee kapsamında dosya yok"))
        }
        if let running = lock.current {
            return finish(.skipped(reason: "\(running.label) taraması sürüyor"))
        }
        isScanning = true
        defer { isScanning = false }
        do {
            // The skill lock file is read from its own known location
            // (`~/.agents/.skill-lock.json`); the binary takes no flag for it.
            let result = try await makeRunner(binary, lock).scan(
                kind: kind, paths: paths, now: now
            )
            let usable = registry.record(scan: result)
            return finish(.ran(findings: result.bumblebeeFindings.count, usable: usable))
        } catch {
            return finish(.failed(error.localizedDescription))
        }
    }

    @discardableResult
    private func finish(_ outcome: Outcome) -> Outcome {
        lastOutcome = outcome
        return outcome
    }
}
