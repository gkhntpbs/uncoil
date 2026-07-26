import Foundation

/// Uncoil's own static scanner for extension packages.
///
/// Deliberately complementary to Bumblebee rather than a replacement: this reads
/// the files of one package and reports what it can see — file kinds, risky
/// commands, prompt-level instructions and, for an update, what changed. It
/// never claims a package is safe, only what it did and did not find.
enum ExtensionSecurityScanner {
    /// File kinds the scanner distinguishes, which drives what it looks for.
    enum FileKind: String, Equatable, CaseIterable {
        case shell
        case python
        case node
        case markdown
        case binary
        case other

        var label: String {
            switch self {
            case .shell: String(localized: "Shell script")
            case .python: String(localized: "Python script")
            case .node: String(localized: "Node script")
            case .markdown: String(localized: "Instruction file")
            case .binary: String(localized: "Binary")
            case .other: String(localized: "Other")
            }
        }
    }

    struct ScannedFile: Equatable {
        var path: String
        var kind: FileKind
        var isExecutable: Bool
        var byteCount: Int
        /// Very long lines with almost no whitespace: minified or obfuscated.
        var looksObfuscated: Bool
        /// Content hash, so a file whose commands changed is visible even when
        /// the rules it matches did not.
        var contentHash: String = ""
    }

    struct Report: Equatable {
        var extensionID: String?
        var files: [ScannedFile]
        var findings: [SecurityFinding]
        var scannedAt: Date

        var severity: SecurityFinding.Severity {
            findings.filter { !$0.isAccepted }.map(\.severity).max() ?? .info
        }

        /// Risk level shown in the UI. `.verified` is reserved for packages
        /// Uncoil itself ships — a clean scan is never called "safe".
        var riskLevel: RiskLevel {
            switch severity {
            case .blocked: .blocked
            case .high: .highRisk
            case .needsReview: .needsReview
            case .low, .info: .lowRisk
            }
        }

        var executables: [String] {
            files.filter(\.isExecutable).map(\.path)
        }
    }

    /// The levels the Extensions Center shows, in escalating order.
    enum RiskLevel: String, Equatable, CaseIterable, Comparable {
        case verified
        case lowRisk
        case needsReview
        case highRisk
        case blocked
        case modifiedLocally

        var label: String {
            switch self {
            case .verified: String(localized: "Verified")
            case .lowRisk: String(localized: "Low Risk")
            case .needsReview: String(localized: "Needs Review")
            case .highRisk: String(localized: "High Risk")
            case .blocked: String(localized: "Blocked")
            case .modifiedLocally: String(localized: "Modified Locally")
            }
        }

        private var rank: Int {
            switch self {
            case .verified: 0
            case .lowRisk: 1
            case .modifiedLocally: 2
            case .needsReview: 3
            case .highRisk: 4
            case .blocked: 5
            }
        }

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
    }

    // MARK: - Rules

    /// Risky shell constructs, as (rule, severity, matcher). Kept as data so the
    /// catalogue is reviewable and testable on its own.
    struct CommandRule: Equatable {
        let rule: String
        let severity: SecurityFinding.Severity
        let message: String
        let needles: [String]
    }

    static let commandRules: [CommandRule] = [
        .init(rule: "risky-command.sudo", severity: .high,
              message: "Asks for elevated privileges with sudo.",
              needles: ["sudo "]),
        .init(rule: "risky-command.rm-rf", severity: .high,
              message: "Irreversible deletion with rm -rf.",
              needles: ["rm -rf", "rm -fr"]),
        // `curl … | sh` is matched per line rather than by substring, because the
        // URL and flags in between make a literal needle useless.
        .init(rule: "risky-command.curl-pipe-shell", severity: .blocked,
              message: "Pipes something downloaded from the internet straight into the shell.",
              needles: []),
        .init(rule: "risky-command.eval", severity: .needsReview,
              message: "Runs dynamic code through eval.",
              needles: ["eval ", "eval(", "exec("]),
        // The subcommand names alone, because a script may pass them as separate
        // argv entries rather than in one command string.
        .init(rule: "credential.keychain", severity: .high,
              message: "Reaches into the Keychain.",
              needles: ["find-generic-password", "find-internet-password",
                        "/Library/Keychains", "SecItemCopyMatching"]),
        .init(rule: "credential.ssh", severity: .high,
              message: "Reaches for SSH keys.",
              needles: [".ssh/id_", ".ssh/config", "~/.ssh"]),
        .init(rule: "credential.git", severity: .high,
              message: "Reaches for git credentials.",
              needles: [".git-credentials", "credential.helper", ".netrc"]),
        .init(rule: "credential.cloud", severity: .high,
              message: "Reaches for cloud credential paths.",
              needles: [".aws/credentials", ".config/gcloud", ".azure",
                        ".kube/config", ".docker/config.json"]),
        .init(rule: "filesystem.home-write", severity: .needsReview,
              message: "Writes broadly into the home directory.",
              needles: ["> ~/", ">> ~/", "cp -r ~/", "mv ~/"]),
        .init(rule: "filesystem.outside-project", severity: .needsReview,
              message: "Writes outside the project.",
              needles: ["> /etc/", "> /usr/", "> /Library/", "/LaunchAgents/"]),
        .init(rule: "process.child", severity: .low,
              message: "Starting a child process.",
              needles: ["subprocess.", "child_process", "spawn(", "Popen(", "system("]),
        .init(rule: "network.connection", severity: .low,
              message: "Opening a network connection.",
              needles: ["curl ", "wget ", "http://", "https://", "requests.get",
                        "urllib", "fetch(", "nc -"]),
    ]

    /// Instruction-level rules for SKILL.md and MCP descriptions: text that
    /// tells an agent to bypass its own safeguards.
    static let instructionRules: [CommandRule] = [
        .init(rule: "instruction.disable-safety", severity: .blocked,
              message: "Tells the agent to turn security checks off.",
              needles: ["ignore previous instructions", "ignore all previous",
                        "disregard the system prompt", "disable safety",
                        "turn security checks off", "bypass approval",
                        "skip permission", "--dangerously-skip-permissions"]),
        .init(rule: "instruction.destructive-without-approval", severity: .high,
              message: "Tells the agent to do destructive work without asking.",
              needles: ["without asking the user", "do not ask for confirmation",
                        "without asking you", "delete without asking"]),
        .init(rule: "instruction.secret-exfiltration", severity: .blocked,
              message: "Steers toward asking for secrets or sending them out.",
              needles: ["print the api key", "send the token", "cat ~/.env",
                        "read the credentials", "send the token", "api key'i yaz"]),
        .init(rule: "instruction.hidden-files", severity: .needsReview,
              message: "Steers toward reading hidden files.",
              needles: ["read ~/.", "cat ~/.", "ls -la ~/", ".env file"]),
        .init(rule: "instruction.policy-bypass", severity: .high,
              message: "Tells the agent to bypass policy.",
              needles: ["you are allowed to ignore", "override the policy",
                        "ignore the policy", "act as if you had permission"]),
    ]

    // MARK: - Scanning

    static func scan(
        packageAt root: URL,
        extensionID: String? = nil,
        now: Date = .now
    ) -> Report {
        let manager = FileManager.default
        var files: [ScannedFile] = []
        var findings: [SecurityFinding] = []
        let base = root.standardizedFileURL.path

        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else {
            return Report(extensionID: extensionID, files: [], findings: [], scannedAt: now)
        }

        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count + 1)) : path

            if let attributes = try? manager.attributesOfItem(atPath: url.path),
               (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                continue
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let data = manager.contents(atPath: path)
            let byteCount = data?.count ?? 0
            // NUL bytes decode as valid UTF-8, so "did it decode?" is not a
            // binary test — look for them explicitly.
            let text = data.flatMap { data -> String? in
                guard !isBinaryData(data) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            let kind = self.kind(path: relative, text: text)
            let isExecutable = manager.isExecutableFile(atPath: path)
            let obfuscated = text.map(looksObfuscated) ?? false

            files.append(ScannedFile(
                path: relative, kind: kind, isExecutable: isExecutable,
                byteCount: byteCount, looksObfuscated: obfuscated,
                contentHash: data.map { AgentAdapterSupport.hash(
                    String(decoding: $0, as: UTF8.self)
                ) } ?? ""
            ))

            if kind == .binary {
                findings.append(finding(
                    rule: "file.binary", severity: byteCount > 5 * 1_024 * 1_024 ? .high : .needsReview,
                    message: byteCount > 5 * 1_024 * 1_024
                        ? "Unexpectedly large binary (\(byteCount / 1_048_576) MB)."
                        : "The package contains binary files.",
                    extensionID: extensionID, path: relative, now: now
                ))
            }
            if isExecutable, kind != .binary {
                findings.append(finding(
                    rule: "file.executable", severity: .low,
                    message: "A script with execute permission.",
                    extensionID: extensionID, path: relative, now: now
                ))
            }
            if obfuscated {
                findings.append(finding(
                    rule: "file.obfuscated", severity: .needsReview,
                    message: "Minified or obfuscated content.",
                    extensionID: extensionID, path: relative, now: now
                ))
            }

            guard let text else { continue }
            if pipesDownloadIntoShell(text) {
                findings.append(finding(
                    rule: "risky-command.curl-pipe-shell", severity: .blocked,
                    message: "Pipes something downloaded from the internet straight into the shell.",
                    extensionID: extensionID, path: relative, now: now
                ))
            }
            let rules = kind == .markdown ? instructionRules : commandRules
            findings.append(contentsOf: matches(
                rules, in: text, extensionID: extensionID, path: relative, now: now
            ))
            // Instructions can also hide in a script's comments, and commands in
            // a markdown code block, so both catalogues run over both.
            let secondary = kind == .markdown ? commandRules : instructionRules
            findings.append(contentsOf: matches(
                secondary, in: text, extensionID: extensionID, path: relative, now: now
            ))
        }

        if let escapes = ExtensionUpdateEngine.symlinkEscapes(at: root), !escapes.isEmpty {
            for escape in escapes {
                findings.append(finding(
                    rule: "symlink.escape", severity: .blocked,
                    message: "The symlink points outside the package.",
                    extensionID: extensionID, path: escape, now: now
                ))
            }
        }

        return Report(
            extensionID: extensionID,
            files: files.sorted { $0.path < $1.path },
            findings: dedupe(findings),
            scannedAt: now
        )
    }

    /// Scan an MCP server's declared description/tool text, which the agent reads
    /// as instructions even though it is not a file in a package.
    static func scanDescription(
        _ text: String,
        extensionID: String? = nil,
        now: Date = .now
    ) -> [SecurityFinding] {
        dedupe(matches(
            instructionRules, in: text, extensionID: extensionID, path: nil, now: now
        ))
    }

    /// Script files whose content hash moved between two revisions. The rules may
    /// say nothing new while the command itself changed completely.
    static func shellCommandChanges(
        from previous: Report,
        to current: Report
    ) -> [(path: String, detail: String)] {
        let scriptKinds: Set<FileKind> = [.shell, .python, .node]
        let before = Dictionary(
            previous.files.filter { scriptKinds.contains($0.kind) }.map { ($0.path, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        return current.files
            .filter { scriptKinds.contains($0.kind) }
            .compactMap { file in
                guard let old = before[file.path], !old.isEmpty, old != file.contentHash else {
                    return nil
                }
                return (file.path, "\(file.path)'s content changed")
            }
            .sorted { $0.path < $1.path }
    }

    /// A shipped binary with no valid code signature.
    ///
    /// The `codesign` call is injected: a unit test must not depend on what is
    /// signed on the machine running it, and the app passes the real one.
    static func unsignedBinaries(
        in report: Report,
        isSigned: (String) -> Bool,
        now: Date = .now
    ) -> [SecurityFinding] {
        report.files
            .filter { $0.kind == .binary }
            .filter { !isSigned($0.path) }
            .map { file in
                finding(
                    rule: "binary.unsigned", severity: .high,
                    message: "Unsigned binary: \(file.path)",
                    extensionID: report.extensionID, path: file.path, now: now
                )
            }
    }

    /// Whether macOS considers this file signed. Blocking; call off the main
    /// thread.
    static func isCodeSigned(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-v", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Update diff

    /// What got riskier between two scans. This is the gate for "did this update
    /// quietly add an executable, a domain, or a new tool?".
    static func diff(
        from previous: Report,
        to current: Report,
        previousTools: [String] = [],
        currentTools: [String] = [],
        previousEntrypoint: String? = nil,
        currentEntrypoint: String? = nil,
        previousSource: ExtensionSource? = nil,
        currentSource: ExtensionSource? = nil,
        now: Date = .now
    ) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let extensionID = current.extensionID

        let newExecutables = Set(current.executables).subtracting(previous.executables)
        for path in newExecutables.sorted() {
            findings.append(finding(
                rule: "diff.new-executable", severity: .needsReview,
                message: "The update added a new executable file.",
                extensionID: extensionID, path: path, now: now
            ))
        }

        let scriptKinds: Set<FileKind> = [.shell, .python, .node]
        let previousScripts = Set(previous.files.filter { scriptKinds.contains($0.kind) }.map(\.path))
        for file in current.files
        where scriptKinds.contains(file.kind) && !previousScripts.contains(file.path) {
            findings.append(finding(
                rule: "diff.new-script", severity: .needsReview,
                message: "The update added a new script.",
                extensionID: extensionID, path: file.path, now: now
            ))
        }

        let newDomains = Set(current.findings.flatMap(domains))
            .subtracting(previous.findings.flatMap(domains))
        for domain in newDomains.sorted() {
            findings.append(finding(
                rule: "diff.new-domain", severity: .needsReview,
                message: "The update added a new network address: \(domain)",
                extensionID: extensionID, path: nil, now: now
            ))
        }

        let previousRules = Set(previous.findings.map(\.rule))
        for rule in Set(current.findings.map(\.rule)).subtracting(previousRules).sorted() {
            findings.append(finding(
                rule: "diff.permission-widened", severity: .needsReview,
                message: "The update added new risky behaviour: \(rule)",
                extensionID: extensionID, path: nil, now: now
            ))
        }

        let added = Set(currentTools).subtracting(previousTools)
        let removed = Set(previousTools).subtracting(currentTools)
        for tool in added.sorted() {
            let writes = ["write", "delete", "remove", "update", "create", "exec", "run"]
                .contains { tool.lowercased().contains($0) }
            findings.append(finding(
                rule: writes ? "diff.new-write-tool" : "diff.new-tool",
                severity: writes ? .high : .needsReview,
                message: writes
                    ? "Update yazma/silme yetkili tool ekledi: \(tool)"
                    : "The update added a new tool: \(tool)",
                extensionID: extensionID, path: nil, now: now
            ))
        }
        for tool in removed.sorted() {
            findings.append(finding(
                rule: "diff.removed-tool", severity: .info,
                message: "The update removed a tool: \(tool)",
                extensionID: extensionID, path: nil, now: now
            ))
        }

        if let previousEntrypoint, let currentEntrypoint, previousEntrypoint != currentEntrypoint {
            findings.append(finding(
                rule: "diff.entrypoint-changed", severity: .high,
                message: "Entrypoint changed: \(previousEntrypoint) → \(currentEntrypoint)",
                extensionID: extensionID, path: nil, now: now
            ))
        }

        // A shell command that changed is not the same as one that appeared: the
        // rule set is unchanged, so only a content comparison sees it.
        for change in shellCommandChanges(from: previous, to: current) {
            findings.append(finding(
                rule: "diff.shell-command-changed", severity: .needsReview,
                message: "The shell command changed: \(change.detail)",
                extensionID: extensionID, path: change.path, now: now
            ))
        }

        if let previousSource, let currentSource,
           sourceIdentity(previousSource) != sourceIdentity(currentSource) {
            findings.append(finding(
                rule: "diff.source-changed", severity: .blocked,
                message: "The source or repo owner changed: \(previousSource.label) → \(currentSource.label)",
                extensionID: extensionID, path: nil, now: now
            ))
        }

        return dedupe(findings)
    }

    // MARK: - Helpers

    static func kind(path: String, text: String?) -> FileKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "sh", "bash", "zsh": return .shell
        case "py": return .python
        case "js", "mjs", "cjs", "ts": return .node
        case "md", "markdown", "txt": return .markdown
        default: break
        }
        guard let text else { return .binary }
        let firstLine = text.prefix(200)
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("node") { return .node }
            return .shell
        }
        return .other
    }

    /// A NUL byte in the first chunk is the practical binary test: such a file
    /// still decodes as UTF-8, so decoding alone proves nothing.
    static func isBinaryData(_ data: Data) -> Bool {
        data.prefix(8 * 1_024).contains(0x00)
    }

    /// A single line that downloads something and pipes it into an interpreter —
    /// the shape matters, not the exact flags or URL in between.
    static func pipesDownloadIntoShell(_ text: String) -> Bool {
        let interpreters = ["sh", "bash", "zsh", "python", "python3", "node", "ruby", "perl"]
        return text.components(separatedBy: "\n").contains { line in
            let lower = line.lowercased()
            guard lower.contains("curl ") || lower.contains("wget ") else { return false }
            guard let pipe = lower.range(of: "|") else { return false }
            let tail = lower[pipe.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            // `| sudo sh` counts too.
            return tail.contains { interpreters.contains($0) || $0 == "sudo" }
        }
    }

    /// Long lines with hardly any whitespace read as minified or packed.
    static func looksObfuscated(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard let longest = lines.max(by: { $0.count < $1.count }), longest.count > 500 else {
            return false
        }
        let whitespace = longest.filter { $0 == " " || $0 == "\t" }.count
        return Double(whitespace) / Double(longest.count) < 0.05
    }

    private static func matches(
        _ rules: [CommandRule],
        in text: String,
        extensionID: String?,
        path: String?,
        now: Date
    ) -> [SecurityFinding] {
        let haystack = text.lowercased()
        return rules.compactMap { rule in
            guard rule.needles.contains(where: { haystack.contains($0.lowercased()) }) else {
                return nil
            }
            return finding(
                rule: rule.rule, severity: rule.severity, message: rule.message,
                extensionID: extensionID, path: path, now: now
            )
        }
    }

    private static func domains(_ finding: SecurityFinding) -> [String] {
        guard finding.rule == "network.connection" else { return [] }
        return [finding.path ?? "?"]
    }

    private static func sourceIdentity(_ source: ExtensionSource) -> String {
        switch source {
        case .managedGitHub(let repository, let subpath, _):
            "github:\(repository):\(subpath ?? "")"
        case .bundled(let identifier):
            "bundled:\(identifier)"
        case .local(let path):
            "local:\(path)"
        case .adopted(let path):
            "adopted:\(path)"
        case .detectedExternal(let path):
            "external:\(path)"
        case .remoteMCP(let url, _):
            "remote:\(url)"
        }
    }

    private static func finding(
        rule: String,
        severity: SecurityFinding.Severity,
        message: String,
        extensionID: String?,
        path: String?,
        now: Date
    ) -> SecurityFinding {
        SecurityFinding(
            id: [extensionID, rule, path].compactMap { $0 }.joined(separator: "|"),
            origin: .uncoil,
            severity: severity,
            rule: rule,
            message: message,
            extensionID: extensionID,
            path: path,
            foundAt: now
        )
    }

    /// One finding per (rule, path): a rule matching twice in one file is one
    /// thing to review, not two.
    private static func dedupe(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        var seen: Set<String> = []
        var result: [SecurityFinding] = []
        for finding in findings where seen.insert(finding.id).inserted {
            result.append(finding)
        }
        return result.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id
        }
    }
}
