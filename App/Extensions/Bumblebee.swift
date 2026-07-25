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

/// The kinds of finding Bumblebee reports, and what each one means for Uncoil.
///
/// Classification lives here rather than in the UI because the kind decides more
/// than a label: an inventory line is not a problem, a parser diagnostic says
/// Bumblebee could not read something (so a clean result nearby means less), and
/// an unsupported configuration is a coverage gap wearing a finding's clothes.
/// A rule Uncoil does not recognise stays visible as `.other` — a finding nobody
/// classified is still a finding.
enum BumblebeeFindingKind: String, Equatable, CaseIterable, Identifiable {
    case knownPackageExposure
    case knownMaliciousVersion
    case suspiciousEditorExtension
    case mcpInventory
    case agentSkillInventory
    case parserDiagnostic
    case unsupportedConfiguration
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .knownPackageExposure: "Bilinen paket açığı"
        case .knownMaliciousVersion: "Bilinen zararlı sürüm"
        case .suspiciousEditorExtension: "Şüpheli editör eklentisi"
        case .mcpInventory: "MCP envanteri"
        case .agentSkillInventory: "Agent skill envanteri"
        case .parserDiagnostic: "Parser uyarısı"
        case .unsupportedConfiguration: "Desteklenmeyen yapılandırma"
        case .other: "Sınıflandırılmamış bulgu"
        }
    }

    /// Inventory is a list of what exists, not a claim that something is wrong.
    var isInventory: Bool {
        self == .mcpInventory || self == .agentSkillInventory
    }

    /// A diagnostic is about the scanner, not about the extension.
    var isAboutTheScanner: Bool {
        self == .parserDiagnostic || self == .unsupportedConfiguration
    }

    /// Whether this kind should count towards "open findings" — the number the
    /// user is meant to act on.
    var isActionable: Bool {
        switch self {
        case .knownPackageExposure, .knownMaliciousVersion, .suspiciousEditorExtension,
             .other:
            true
        case .mcpInventory, .agentSkillInventory, .parserDiagnostic,
             .unsupportedConfiguration:
            false
        }
    }

    /// The severity Uncoil uses when Bumblebee does not give one. A malicious
    /// version blocks; an exposure needs review; inventory and diagnostics are
    /// information.
    var defaultSeverity: SecurityFinding.Severity {
        switch self {
        case .knownMaliciousVersion: .blocked
        case .knownPackageExposure: .high
        case .suspiciousEditorExtension: .needsReview
        case .other: .needsReview
        case .mcpInventory, .agentSkillInventory, .parserDiagnostic,
             .unsupportedConfiguration:
            .info
        }
    }

    /// What the user is told to do about it.
    var remedy: String {
        switch self {
        case .knownPackageExposure:
            "Paketi güncelle; güncel sürüm yoksa extension'ı karantinaya al."
        case .knownMaliciousVersion:
            "Bu sürümü çalıştırma: karantinaya al ve kaynağı doğrula."
        case .suspiciousEditorExtension:
            "Editör eklentisini gözden geçir; Uncoil onu yönetmiyor."
        case .mcpInventory, .agentSkillInventory:
            "Bilgi amaçlı: listede beklemediğin bir şey varsa ona bak."
        case .parserDiagnostic:
            "Bumblebee bu dosyayı okuyamadı; o dosya için temiz sonuç kanıt değildir."
        case .unsupportedConfiguration:
            "Bu yapılandırma tarama kapsamı dışında; Uncoil'in kendi taramasına güven."
        case .other:
            "Bumblebee bu kuralı bildirdi ama Uncoil sınıflandırmadı; kuralın adına bak."
        }
    }

    /// Reads the kind from Bumblebee's rule identifier. Several spellings are
    /// accepted because the exact strings come from a binary Uncoil does not own.
    static func from(rule: String) -> BumblebeeFindingKind {
        let normalized = rule.lowercased().replacingOccurrences(of: "_", with: "-")
        switch true {
        case normalized.contains("malicious"), normalized.contains("known-bad"):
            return .knownMaliciousVersion
        case normalized.contains("exposure"), normalized.contains("vulnerab"),
             normalized.contains("advisory"), normalized.contains("cve"):
            return .knownPackageExposure
        case normalized.contains("editor-extension"), normalized.contains("vscode"),
             normalized.contains("editor"):
            return .suspiciousEditorExtension
        case normalized.contains("mcp-inventory"), normalized.contains("inventory.mcp"):
            return .mcpInventory
        case normalized.contains("skill-inventory"), normalized.contains("inventory.skill"),
             normalized.contains("agent-inventory"):
            return .agentSkillInventory
        case normalized.contains("parser"), normalized.contains("parse-error"):
            return .parserDiagnostic
        case normalized.contains("unsupported"), normalized.contains("not-supported"),
             normalized.contains("coverage"):
            return .unsupportedConfiguration
        default:
            return .other
        }
    }
}

extension SecurityFinding {
    /// Bumblebee's own classification of this finding. Uncoil's own findings are
    /// not classified this way — they have their own rule names.
    var bumblebeeKind: BumblebeeFindingKind? {
        origin == .bumblebee ? BumblebeeFindingKind.from(rule: rule) : nil
    }

    /// Whether this finding is one the user is meant to act on.
    var isActionable: Bool {
        guard let kind = bumblebeeKind else { return severity >= .needsReview }
        return kind.isActionable && severity >= .needsReview
    }
}

/// How a scan's findings break down, for the screen that shows them.
struct BumblebeeFindingSummary: Equatable {
    var byKind: [BumblebeeFindingKind: [SecurityFinding]]
    /// Parser diagnostics mean a clean result elsewhere proves less.
    var hasParserDiagnostics: Bool
    var actionableCount: Int
    var inventoryCount: Int

    init(findings: [SecurityFinding]) {
        var grouped: [BumblebeeFindingKind: [SecurityFinding]] = [:]
        for finding in findings where finding.origin == .bumblebee {
            let kind = BumblebeeFindingKind.from(rule: finding.rule)
            grouped[kind, default: []].append(finding)
        }
        byKind = grouped
        hasParserDiagnostics = grouped[.parserDiagnostic]?.isEmpty == false
        actionableCount = grouped
            .filter { $0.key.isActionable }
            .values
            .flatMap { $0 }
            .filter { $0.severity >= .needsReview && !$0.isAccepted }
            .count
        inventoryCount = grouped
            .filter { $0.key.isInventory }
            .values
            .reduce(0) { $0 + $1.count }
    }

    var kinds: [BumblebeeFindingKind] {
        BumblebeeFindingKind.allCases.filter { byKind[$0]?.isEmpty == false }
    }

    /// The caption above a clean-looking result. A scan with parser diagnostics is
    /// never described as clean.
    func caption(scanned: Int) -> String {
        if hasParserDiagnostics {
            return "\(scanned) öğe tarandı ama bazı dosyalar okunamadı; "
                + "bulgu olmaması onların temiz olduğunu göstermez."
        }
        if actionableCount == 0 {
            return BumblebeeCoverage.cleanResultCaption(scanned: scanned)
        }
        return "\(scanned) öğe tarandı, \(actionableCount) bulgu ilgilenilmeyi bekliyor."
    }
}
