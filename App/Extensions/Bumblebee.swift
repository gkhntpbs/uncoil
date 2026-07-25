import Foundation

/// Where the Bumblebee binary came from. The order of the cases is the order
/// Uncoil prefers them in: a binary that ships with the app is the only one whose
/// version Uncoil can be sure of, and one found on `PATH` is whatever the user
/// happens to have.
enum BumblebeeBinarySource: String, Equatable, Codable, CaseIterable {
    /// Pinned inside `Uncoil.app`, so its version moves with the app.
    case pinned
    /// Installed by Uncoil under its own tools directory.
    case managed
    /// Whatever is on `PATH`.
    case path

    var label: String {
        switch self {
        case .pinned: "Uncoil ile gelen"
        case .managed: "Uncoil tarafından kurulan"
        case .path: "PATH üzerinde bulunan"
        }
    }

    /// Whether Uncoil knows exactly what this binary is.
    var isVersionKnownInAdvance: Bool { self == .pinned }
}

/// A resolved Bumblebee binary.
struct BumblebeeBinary: Equatable {
    var source: BumblebeeBinarySource
    var path: String
}

/// What `bumblebee version` reported.
struct BumblebeeVersion: Equatable, Codable {
    var version: String
    /// Build revision, when the binary reports one. Recorded so a finding can be
    /// traced back to the exact build that produced it.
    var buildRevision: String?
    var catalogVersion: String?

    var label: String {
        [version, buildRevision.map { "build \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Reads either the JSON form or the one-line text form.
    static func parse(_ output: String) -> BumblebeeVersion? {
        if let data = output.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = root["version"] as? String {
            return BumblebeeVersion(
                version: version,
                buildRevision: root["build"] as? String ?? root["revision"] as? String,
                catalogVersion: root["catalog"] as? String
            )
        }
        // "bumblebee 1.4.2 (build a1b2c3d)"
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let version = parts.first(where: { $0.first?.isNumber == true }) else { return nil }
        let build = parts
            .first { $0.hasPrefix("(build") || $0.hasPrefix("build") }
            .flatMap { _ in
                parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        return BumblebeeVersion(version: version, buildRevision: build, catalogVersion: nil)
    }
}

/// The result of `bumblebee selftest`, and what it means for the scan results.
struct BumblebeeSelfTest: Equatable, Codable {
    var passed: Bool
    var detail: String
    var ranAt: Date

    /// Scan results are only trusted when the self-test passed. A binary that
    /// cannot verify itself is not evidence about anything else.
    var resultsAreTrustworthy: Bool { passed }

    static func parse(_ output: String, exitCode: Int32, now: Date) -> BumblebeeSelfTest {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = root["ok"] as? Bool ?? root["passed"] as? Bool {
            return BumblebeeSelfTest(
                passed: ok && exitCode == 0,
                detail: root["detail"] as? String ?? trimmed,
                ranAt: now
            )
        }
        return BumblebeeSelfTest(
            passed: exitCode == 0,
            detail: trimmed.isEmpty ? "çıkış kodu \(exitCode)" : trimmed,
            ranAt: now
        )
    }
}

/// Why a scan is running. The kind decides the timeout and whether the result
/// becomes the new baseline.
enum BumblebeeScanKind: String, Equatable, Codable, CaseIterable, Identifiable {
    case beforeInstall
    case beforeUpdate
    case afterUpdate
    case launchIfStale
    case dailyBaseline
    case manual
    case project
    /// Everything, slowly, for when something already went wrong.
    case deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beforeInstall: "Kurulum öncesi"
        case .beforeUpdate: "Update öncesi"
        case .afterUpdate: "Update sonrası"
        case .launchIfStale: "Açılışta (eski tarama)"
        case .dailyBaseline: "Günlük baseline"
        case .manual: "Manuel"
        case .project: "Proje taraması"
        case .deep: "Deep scan"
        }
    }

    /// Quick scans block a step the user is waiting on, so they are short.
    var isQuick: Bool {
        switch self {
        case .beforeInstall, .beforeUpdate, .afterUpdate: true
        case .launchIfStale, .dailyBaseline, .manual, .project, .deep: false
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .beforeInstall, .beforeUpdate, .afterUpdate: 30
        case .launchIfStale, .manual: 120
        case .dailyBaseline, .project: 300
        case .deep: 900
        }
    }

    /// Whether this scan's result replaces the stored baseline.
    var updatesBaseline: Bool {
        switch self {
        case .dailyBaseline, .deep, .afterUpdate: true
        case .beforeInstall, .beforeUpdate, .launchIfStale, .manual, .project: false
        }
    }

    /// The kind that runs in the background, which is what the daemon schedules.
    var runsInDaemon: Bool {
        switch self {
        case .dailyBaseline, .deep: true
        case .beforeInstall, .beforeUpdate, .afterUpdate, .launchIfStale, .manual, .project: false
        }
    }
}

/// When a regular scan is due. Pure, so the schedule is testable without waiting.
enum BumblebeeSchedule {
    static let staleAfter: TimeInterval = 24 * 60 * 60

    static func isStale(lastScanAt: Date?, now: Date, staleAfter: TimeInterval = staleAfter) -> Bool {
        guard let lastScanAt else { return true }
        return now.timeIntervalSince(lastScanAt) >= staleAfter
    }

    /// What to run at launch: nothing when a recent scan exists.
    static func atLaunch(lastScanAt: Date?, now: Date) -> BumblebeeScanKind? {
        isStale(lastScanAt: lastScanAt, now: now) ? .launchIfStale : nil
    }

    static func nextBaseline(after lastBaselineAt: Date?, now: Date) -> Date {
        guard let lastBaselineAt else { return now }
        return lastBaselineAt.addingTimeInterval(staleAfter)
    }
}

/// One line of Bumblebee's NDJSON output.
enum BumblebeeEvent: Equatable {
    case finding(SecurityFinding)
    case diagnostic(String)
    case summary(BumblebeeScanSummary)
    /// A line Uncoil did not understand. Kept rather than dropped: a scan whose
    /// output changed shape must be visible, not silently thinner.
    case unknown(String)
}

/// The `scan_summary` line Bumblebee ends with. Without it the scan did not
/// finish, whatever came before it.
struct BumblebeeScanSummary: Equatable, Codable {
    var scanned: Int
    var findings: Int
    var durationSeconds: Double?
    var catalogVersion: String?
    var truncated: Bool = false
}

/// A finished — or unfinished — scan.
struct BumblebeeScanResult: Equatable {
    var kind: BumblebeeScanKind
    var findings: [SecurityFinding]
    var diagnostics: [String]
    var summary: BumblebeeScanSummary?
    var unknownLines: [String]
    var exitCode: Int32
    var timedOut: Bool
    var selfTest: BumblebeeSelfTest?
    var version: BumblebeeVersion?
    var startedAt: Date
    var finishedAt: Date

    /// A scan counts as the current state only when it ran to completion, said so
    /// in its summary, and came from a binary that passed its self-test.
    var isUsableAsCurrentState: Bool {
        !timedOut
            && exitCode == 0
            && summary != nil
            && (selfTest?.resultsAreTrustworthy ?? false)
    }

    /// Why the result is not usable, for the UI to say out loud.
    var unusableReason: String? {
        if timedOut { return "Tarama zaman aşımına uğradı; yarım sonuç current state sayılmaz." }
        if exitCode != 0 { return "Bumblebee \(exitCode) koduyla çıktı." }
        if summary == nil { return "scan_summary satırı yok; tarama tamamlanmamış." }
        if selfTest?.resultsAreTrustworthy != true {
            return "Self-test geçmedi; sonuçlar güvenilir kabul edilmiyor."
        }
        return nil
    }

    /// Bumblebee's findings are never mixed with Uncoil's own.
    var bumblebeeFindings: [SecurityFinding] {
        findings.filter { $0.origin == .bumblebee }
    }
}

/// Parses Bumblebee's NDJSON streams.
enum BumblebeeOutputParser {
    /// stdout: findings and the summary.
    static func parseStdout(_ text: String, now: Date) -> [BumblebeeEvent] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization
                        .jsonObject(with: data) as? [String: Any] else {
                    return .unknown(line)
                }
                let type = root["type"] as? String ?? root["kind"] as? String
                switch type {
                case "scan_summary", "summary":
                    return .summary(BumblebeeScanSummary(
                        scanned: root["scanned"] as? Int ?? 0,
                        findings: root["findings"] as? Int ?? 0,
                        durationSeconds: root["duration_seconds"] as? Double,
                        catalogVersion: root["catalog_version"] as? String,
                        truncated: root["truncated"] as? Bool ?? false
                    ))
                case "finding":
                    guard let finding = finding(from: root, now: now) else {
                        return .unknown(line)
                    }
                    return .finding(finding)
                case "diagnostic", "parser_diagnostic":
                    return .diagnostic(root["message"] as? String ?? line)
                default:
                    // A line with a rule but no type is still a finding.
                    if let finding = finding(from: root, now: now) { return .finding(finding) }
                    return .unknown(line)
                }
            }
    }

    /// stderr: diagnostics, one JSON object per line, or plain text.
    static func parseStderr(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization
                        .jsonObject(with: data) as? [String: Any] else { return line }
                return root["message"] as? String
                    ?? root["detail"] as? String
                    ?? line
            }
    }

    static func finding(from root: [String: Any], now: Date) -> SecurityFinding? {
        guard let rule = root["rule"] as? String ?? root["id"] as? String else { return nil }
        let severity = severity(root["severity"] as? String)
        return SecurityFinding(
            id: "bumblebee:\(root["id"] as? String ?? rule):\(root["path"] as? String ?? "-")",
            // Always `.bumblebee`: whose finding this is decides how it is shown.
            origin: .bumblebee,
            severity: severity,
            rule: rule,
            message: root["message"] as? String ?? rule,
            extensionID: root["extension_id"] as? String,
            path: root["path"] as? String,
            foundAt: now
        )
    }

    static func severity(_ raw: String?) -> SecurityFinding.Severity {
        switch raw?.lowercased() {
        case "blocked", "critical": .blocked
        case "high": .high
        case "needs_review", "medium", "warning": .needsReview
        case "low": .low
        default: .info
        }
    }
}

/// What Bumblebee does not look at.
///
/// Kept as data so the UI can state it next to a clean result instead of letting
/// "no findings" imply "checked and safe".
enum BumblebeeCoverage {
    struct Gap: Equatable, Identifiable {
        var id: String
        var message: String
        var remedy: String
    }

    static let looseSkillFolders = Gap(
        id: "coverage.loose-skill-folders",
        message: "Doğrudan `SKILL.md` klasörleri Bumblebee taramasının kapsamı dışında.",
        remedy: "Bu klasörler için Uncoil'in kendi taramasına güven."
    )

    static let codexTOML = Gap(
        id: "coverage.codex-toml",
        message: "Codex TOML MCP config'i Bumblebee tarafından okunmuyor.",
        remedy: "Codex MCP sunucuları Uncoil taramasıyla değerlendirilir."
    )

    static let remoteMCP = Gap(
        id: "coverage.remote-mcp",
        message: "Remote MCP sunucularının yerel dosyası yok; taranacak bir şey bulunmuyor.",
        remedy: "Sunucu tarafı güvenliği sağlayıcının sorumluluğunda."
    )

    static let all: [Gap] = [looseSkillFolders, codexTOML, remoteMCP]

    /// Whether a package is inside Bumblebee's reach at all.
    static func isCovered(_ package: ExtensionPackage) -> Bool {
        switch package.source {
        case .remoteMCP: false
        case .managedGitHub, .bundled, .local, .detectedExternal: package.kind == .mcpServer
        }
    }

    /// The label a package carries when Bumblebee cannot speak for it.
    static func label(for package: ExtensionPackage) -> String? {
        isCovered(package) ? nil : "Not covered by Bumblebee"
    }

    /// What to say about a clean scan. Never "safe".
    static func cleanResultCaption(scanned: Int) -> String {
        "\(scanned) öğe tarandı, bulgu yok. Bu \"tamamen güvenli\" demek değildir: "
            + "tarama kapsamı sınırlıdır."
    }
}
