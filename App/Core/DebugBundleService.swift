import Foundation

enum DebugBundleError: LocalizedError {
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let message): message
        }
    }
}

struct DebugBundleService {
    struct Result {
        let bundleURL: URL
        let includedFiles: [String]
    }

    private let fileManager: FileManager
    private let dataDirectory: URL
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let now: () -> Date
    private let command: (_ executable: String, _ arguments: [String]) -> String?

    init(
        fileManager: FileManager = .default,
        dataDirectory: URL = ProjectStore.defaultDirectory(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping () -> Date = Date.init,
        command: @escaping (_ executable: String, _ arguments: [String]) -> String? = Self.run
    ) {
        self.fileManager = fileManager
        self.dataDirectory = dataDirectory
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.command = command
    }

    func create() throws -> Result {
        let outputDirectory = dataDirectory.appendingPathComponent("debug-bundles", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let identifier = Self.timestamp(now())
        let staging = outputDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let projectPaths = loadProjectPaths()
        var included: [String] = []

        try addText(
            systemInformation(),
            named: "system-information.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
        try addText(
            agentVersions(),
            named: "agent-versions.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
        try addText(
            unifiedLog(process: "Uncoil"),
            named: "app-logs.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
        try addText(
            unifiedLog(process: "uncoil-runtimed"),
            named: "runtime-daemon-logs.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
        try collectAgentConfigs(into: staging, projectPaths: projectPaths, included: &included)
        try collectMCPHandshake(into: staging, projectPaths: projectPaths, included: &included)
        try collectPermissionDecisions(into: staging, projectPaths: projectPaths, included: &included)
        try collectCrashReports(into: staging, projectPaths: projectPaths, included: &included)
        try collectAcceptanceResults(into: staging, projectPaths: projectPaths, included: &included)

        let manifest = [
            "created_at=\(ISO8601DateFormatter().string(from: now()))",
            "prompt_content_included=false",
            "terminal_replay_included=false",
            "secret_redaction=true",
            "path_redaction=true",
            "files=\(included.sorted().joined(separator: ","))",
        ].joined(separator: "\n") + "\n"
        try addText(
            manifest,
            named: "manifest.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )

        let destination = outputDirectory.appendingPathComponent("Uncoil-Debug-\(identifier).zip")
        guard command(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        ) != nil, fileManager.fileExists(atPath: destination.path) else {
            throw DebugBundleError.archiveFailed("Debug bundle arşivi oluşturulamadı.")
        }
        return Result(bundleURL: destination, includedFiles: included.sorted())
    }

    func redact(_ text: String, projectPaths: [String] = []) -> String {
        var result = text
        var replacements: [(String, String)] = [
            (homeDirectory.path, "~"),
            (temporaryDirectory.path, "$TMPDIR"),
        ]
        for projectPath in projectPaths {
            replacements.append((projectPath, "<PROJECT_ROOT>"))
            replacements.append((
                projectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? projectPath,
                "<PROJECT_ROOT>"
            ))
        }
        if let externalVolumeRoot {
            replacements.append((externalVolumeRoot, "<EXTERNAL_VOLUME>"))
            replacements.append((
                externalVolumeRoot.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? externalVolumeRoot,
                "<EXTERNAL_VOLUME>"
            ))
        }
        for (source, replacement) in replacements where !source.isEmpty {
            result = result.replacingOccurrences(of: source, with: replacement)
        }

        let patterns = [
            #"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s"',}]+"#,
            #"(?i)((?:access_?token|refresh_?token|api_?key|secret|password|client_?secret|github_?token|token)\s*["']?\s*[:=]\s*["']?)[^"',\s}]+"#,
            #"(?is)(["']?--(?:api-key|token|secret|password)["']?\s*,?\s*["']?)[^"',\s}\]]+"#,
            #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#,
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"(?im)(["']?(?:prompt|initial_prompt|system_prompt|instructions)["']?\s*[:=]\s*["']?)[^"',}\r\n]+"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            if pattern.contains("(?:prompt|initial_prompt") {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "$1<redacted-prompt>"
                )
            } else {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "$1<redacted>"
                )
            }
        }
        return result
    }

    private func collectAgentConfigs(
        into staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        let candidates = [
            homeDirectory.appendingPathComponent(".claude/settings.json"),
            homeDirectory.appendingPathComponent(".claude.json"),
            homeDirectory.appendingPathComponent(".codex/config.toml"),
        ]
        var sections: [String] = []
        for url in candidates {
            guard let text = sanitizedConfigText(url) else { continue }
            sections.append("[\(redact(url.path, projectPaths: projectPaths))]\n\(text)")
        }
        try addText(
            sections.isEmpty ? "No readable agent configuration found.\n" : sections.joined(separator: "\n\n"),
            named: "sanitized-agent-configs.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
    }

    private func collectMCPHandshake(
        into staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        let directory = dataDirectory.appendingPathComponent("mcp", isDirectory: true)
        let configs = readableFiles(in: directory, extensions: ["json"])
            .compactMap { url in readText(url).map { "[\(url.lastPathComponent)]\n\($0)" } }
        let socket = dataDirectory.appendingPathComponent("control.sock")
        let content = [
            "protocol_version=\(ControlProtocol.version)",
            "control_socket_present=\(fileManager.fileExists(atPath: socket.path))",
            configs.joined(separator: "\n\n"),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        try addText(
            content + "\n",
            named: "mcp-handshake.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
    }

    private func collectPermissionDecisions(
        into staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        var sections: [String] = []
        let permissions = dataDirectory.appendingPathComponent("permissions.json")
        if let text = readText(permissions) {
            sections.append("[permissions.json]\n\(text)")
        }
        let auditDirectory = dataDirectory.appendingPathComponent("audit", isDirectory: true)
        for url in readableFiles(in: auditDirectory, extensions: ["jsonl"]).suffix(7) {
            guard let text = readText(url) else { continue }
            let permissionLines = text.split(separator: "\n").filter {
                $0.localizedCaseInsensitiveContains("permission")
            }
            if !permissionLines.isEmpty {
                sections.append("[audit/\(url.lastPathComponent)]\n\(permissionLines.joined(separator: "\n"))")
            }
        }
        try addText(
            sections.isEmpty ? "No permission decisions recorded.\n" : sections.joined(separator: "\n\n"),
            named: "permission-decisions.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
    }

    private func collectCrashReports(
        into staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        let directory = homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let names = ["Uncoil", "uncoil-runtimed", "uncoil-mcp", "uncoil-hook"]
        let reports = readableFiles(in: directory, extensions: ["crash", "ips", "diag"])
            .filter { url in names.contains { url.lastPathComponent.hasPrefix($0) } }
            .suffix(10)
        let content = reports.compactMap { url in
            readText(url).map { "[\(url.lastPathComponent)]\n\($0)" }
        }.joined(separator: "\n\n")
        try addText(
            content.isEmpty ? "No matching crash reports found.\n" : content,
            named: "crash-reports.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
    }

    private func collectAcceptanceResults(
        into staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        let root = dataDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            try addText(
                "No acceptance results found.\n",
                named: "acceptance-results.txt",
                to: staging,
                projectPaths: projectPaths,
                included: &included
            )
            return
        }
        var sections: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard name.contains("acceptance"),
                  ["md", "json", "txt"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 1_048_576,
                  let text = readText(url)
            else { continue }
            sections.append("[\(url.lastPathComponent)]\n\(text)")
        }
        try addText(
            sections.isEmpty ? "No acceptance results found.\n" : sections.joined(separator: "\n\n"),
            named: "acceptance-results.txt",
            to: staging,
            projectPaths: projectPaths,
            included: &included
        )
    }

    private func systemInformation() -> String {
        let info = ProcessInfo.processInfo
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return [
            "app_version=\(version)",
            "app_build=\(build)",
            "os=\(info.operatingSystemVersionString)",
            "architecture=\(Self.architecture)",
            "processor_count=\(info.processorCount)",
            "memory_bytes=\(info.physicalMemory)",
            "runtime_ready=\(RuntimeClient.shared.isReady)",
        ].joined(separator: "\n") + "\n"
    }

    private func agentVersions() -> String {
        ["claude", "codex"].map { name in
            guard let path = SettingsStore.which(name) else { return "\(name)=not_found" }
            let version = command(path, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name)=\(version?.isEmpty == false ? version! : "unknown")"
        }.joined(separator: "\n") + "\n"
    }

    private func unifiedLog(process: String) -> String {
        let predicate = process == "Uncoil"
            ? #"process == "Uncoil" AND eventMessage CONTAINS[c] "[uncoil""#
            : #"process == "\#(process)""#
        return command(
            "/usr/bin/log",
            ["show", "--last", "15m", "--style", "compact", "--predicate", predicate]
        ) ?? "No readable \(process) unified log entries.\n"
    }

    private func addText(
        _ text: String,
        named name: String,
        to staging: URL,
        projectPaths: [String],
        included: inout [String]
    ) throws {
        let sanitized = redact(text, projectPaths: projectPaths)
        try Data(sanitized.utf8).write(to: staging.appendingPathComponent(name), options: .atomic)
        included.append(name)
    }

    private func loadProjectPaths() -> [String] {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("projects.json")),
              let projects = try? JSONDecoder().decode([Project].self, from: data)
        else { return [] }
        return projects.map(\.rootPath).sorted { $0.count > $1.count }
    }

    private func readableFiles(in directory: URL, extensions: Set<String>) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            extensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
    }

    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_194_304 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizedConfigText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_194_304 else { return nil }
        guard url.pathExtension.lowercased() == "json",
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let sanitized = try? JSONSerialization.data(
                withJSONObject: sanitizeJSON(object),
                options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return String(data: data, encoding: .utf8)
        }
        return String(data: sanitized, encoding: .utf8)
    }

    private func sanitizeJSON(_ value: Any, key: String? = nil) -> Any {
        let normalized = key?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""
        let secretKeys = [
            "token", "secret", "password", "apikey", "authorization", "oauth",
            "credential", "privatekey",
        ]
        let promptKeys = [
            "prompt", "instruction", "message", "history", "conversation",
            "transcript", "input", "output",
        ]
        if secretKeys.contains(where: normalized.contains) {
            return "<redacted>"
        }
        if promptKeys.contains(where: normalized.contains) {
            return "<redacted-prompt>"
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (childKey, child) in dictionary {
                result[childKey] = sanitizeJSON(child, key: childKey)
            }
            return result
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for case let childKey as String in dictionary.allKeys {
                result[childKey] = sanitizeJSON(dictionary[childKey] as Any, key: childKey)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSON($0) }
        }
        return value
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private var externalVolumeRoot: String? {
        let components = Bundle.main.bundleURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return "/Volumes/\(components[2])"
    }
}
