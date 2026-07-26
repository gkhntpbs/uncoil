import Foundation

/// Filesystem view the detector reads through, injectable so detection stays a
/// pure, unit-testable function over a snapshot.
protocol RunDetectionFileSystem {
    /// Names (not paths) of entries directly inside `relativePath` ("." = root).
    func list(_ relativePath: String) -> [String]
    func isDirectory(_ relativePath: String) -> Bool
    /// UTF-8 contents, nil when missing/unreadable. Only small files are read.
    func read(_ relativePath: String) -> String?
}

struct DiskRunDetectionFileSystem: RunDetectionFileSystem {
    let root: URL
    private func url(_ rel: String) -> URL {
        rel == "." ? root : root.appendingPathComponent(rel)
    }
    func list(_ relativePath: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url(relativePath).path)) ?? []
    }
    func isDirectory(_ relativePath: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(relativePath).path, isDirectory: &isDir)
            && isDir.boolValue
    }
    func read(_ relativePath: String) -> String? {
        let fileURL = url(relativePath)
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 1_000_000 { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}

/// Inspects a repository and proposes run configurations. Suggestions only:
/// everything returned has `source == .detected`, and merging into an existing
/// config file never touches user/agent-authored entries.
enum RunDetection {
    /// Directories never worth descending into during the depth-1 sweep.
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".build", ".build-cache", "backups", "dist",
        "build", "out", "Pods", "vendor", ".uncoil-worktrees", "DerivedData",
        ".next", ".venv", "venv", "__pycache__", "exports", "cache", "logs",
    ]

    static func detect(fileSystem: RunDetectionFileSystem) -> [RunConfiguration] {
        var results = detect(in: ".", prefix: "", fileSystem: fileSystem)
        // Multi-app repos: when the root itself yielded nothing (or even when it
        // did), sweep one level down so `backend/` + `mobile/` layouts surface.
        for name in fileSystem.list(".").sorted() {
            guard !name.hasPrefix("."), !ignoredDirectories.contains(name),
                  // A directory with an extension is a bundle (.xcodeproj,
                  // .xcworkspace, .app…), not a sub-project to sweep into.
                  !name.contains("."),
                  fileSystem.isDirectory(name) else { continue }
            results += detect(in: name, prefix: slug(name) + "-", fileSystem: fileSystem)
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    /// Merge suggestions into existing configurations: append ids that don't
    /// exist yet; never modify existing entries. With `replacingDetected`,
    /// previously *detected* entries are dropped first (user/agent stay).
    static func merge(
        existing: [RunConfiguration],
        suggestions: [RunConfiguration],
        replacingDetected: Bool
    ) -> [RunConfiguration] {
        var kept = replacingDetected ? existing.filter { $0.source != .detected } : existing
        let taken = Set(kept.map(\.id))
        kept += suggestions.filter { !taken.contains($0.id) }
        return kept
    }

    // MARK: - Per-directory detection

    private static func detect(
        in dir: String, prefix: String, fileSystem: RunDetectionFileSystem
    ) -> [RunConfiguration] {
        let entries = Set(fileSystem.list(dir))
        var configs: [RunConfiguration] = []
        configs += nodeConfigs(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        configs += xcodeConfigs(dir: dir, prefix: prefix, entries: entries)
        configs += composeConfigs(dir: dir, prefix: prefix, entries: entries)
        configs += procfileConfigs(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        configs += makefileConfigs(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        configs += pythonConfigs(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        if configs.isEmpty {
            configs += staticSiteConfigs(dir: dir, prefix: prefix, entries: entries)
        }
        return configs
    }

    private static func path(_ dir: String, _ name: String) -> String {
        dir == "." ? name : "\(dir)/\(name)"
    }

    private static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    private static func nodeConfigs(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [RunConfiguration] {
        guard entries.contains("package.json"),
              let text = fs.read(path(dir, "package.json")),
              let data = text.data(using: .utf8),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = raw.objectValue
        else { return [] }
        let scripts = object["scripts"]?.objectValue ?? [:]
        let packageManager = entries.contains("pnpm-lock.yaml") ? "pnpm"
            : entries.contains("yarn.lock") ? "yarn"
            : entries.contains("bun.lockb") || entries.contains("bun.lock") ? "bun"
            : "npm"
        guard let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil })
        else { return [] }
        let body = scripts[script]?.stringValue ?? ""
        let command = script == "start" && packageManager == "npm"
            ? "npm start" : "\(packageManager) run \(script)"
        var port: Int?
        var readyPattern: String?
        if body.contains("next") { port = 3000; readyPattern = "Ready in|ready - started|Local:" }
        else if body.contains("vite") { port = 5173; readyPattern = "Local:" }
        else if body.contains("remotion") { port = 3000; readyPattern = "Server ready|Local:" }
        return [RunConfiguration(
            id: prefix + "dev",
            name: dir == "." ? "Dev server" : "\(dir) dev server",
            command: command,
            cwd: dir,
            ports: port.map { [$0] } ?? [],
            previewURL: port.map { "http://localhost:\($0)" },
            readyPattern: readyPattern,
            notes: "Detected from package.json script '\(script)': \(body)"
        )]
    }

    private static func xcodeConfigs(
        dir: String, prefix: String, entries: Set<String>
    ) -> [RunConfiguration] {
        // A standalone .xcworkspace wins; project.xcworkspace lives inside the
        // .xcodeproj bundle and never appears at this level.
        let workspace = entries.first { $0.hasSuffix(".xcworkspace") }
        let project = entries.first { $0.hasSuffix(".xcodeproj") }
        guard workspace != nil || project != nil else { return [] }
        // The command runs with cwd already set to `dir`, so containers are
        // referenced by bare name.
        let container = workspace.map { "-workspace \"\($0)\"" }
            ?? "-project \"\(project!)\""
        let scheme = ((workspace ?? project)! as NSString).deletingPathExtension
        return [RunConfiguration(
            id: prefix + "xcode-run",
            name: "Build & run \(scheme)",
            command: "xcodebuild \(container) -scheme \"\(scheme)\" -configuration Debug "
                + "-derivedDataPath .build-cache/DerivedData build && "
                + "open \".build-cache/DerivedData/Build/Products/Debug/\(scheme).app\"",
            cwd: dir == "." ? "." : dir,
            readyPattern: "BUILD SUCCEEDED",
            notes: "Scheme guessed from the container name — run `xcodebuild -list` to "
                + "verify, and add a -destination for iOS/simulator targets."
        )]
    }

    private static func composeConfigs(
        dir: String, prefix: String, entries: Set<String>
    ) -> [RunConfiguration] {
        let names = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
        guard names.contains(where: entries.contains) else { return [] }
        return [RunConfiguration(
            id: prefix + "compose",
            name: dir == "." ? "Docker Compose" : "\(dir) compose",
            command: "docker compose up",
            cwd: dir,
            notes: "Detected from a compose file"
        )]
    }

    private static func procfileConfigs(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [RunConfiguration] {
        guard entries.contains("Procfile"), let text = fs.read(path(dir, "Procfile"))
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let command = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !command.isEmpty, !name.hasPrefix("#") else { return nil }
            return RunConfiguration(
                id: prefix + "proc-" + slug(name),
                name: "\(name) (Procfile)",
                command: command,
                cwd: dir,
                notes: "Detected from Procfile entry '\(name)'"
            )
        }
    }

    private static func makefileConfigs(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [RunConfiguration] {
        guard entries.contains("Makefile"), let text = fs.read(path(dir, "Makefile"))
        else { return [] }
        let targets = text.split(separator: "\n").compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"),
                  !line.hasPrefix(".") else { return nil }
            let target = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            return ["dev", "run", "start", "serve"].contains(target) ? target : nil
        }
        guard let target = targets.first else { return [] }
        return [RunConfiguration(
            id: prefix + "make-" + target,
            name: "make \(target)",
            command: "make \(target)",
            cwd: dir,
            notes: "Detected from Makefile target '\(target)'"
        )]
    }

    private static func pythonConfigs(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [RunConfiguration] {
        if entries.contains("manage.py") {
            return [RunConfiguration(
                id: prefix + "django",
                name: "Django dev server",
                command: "python3 manage.py runserver",
                cwd: dir,
                ports: [8000],
                previewURL: "http://localhost:8000",
                readyPattern: "Starting development server",
                notes: "Detected from manage.py"
            )]
        }
        guard entries.contains("pyproject.toml"),
              let text = fs.read(path(dir, "pyproject.toml")) else { return [] }
        guard let script = firstTomlScript(in: text) else { return [] }
        let hasUv = entries.contains("uv.lock")
        return [RunConfiguration(
            id: prefix + "py-" + slug(script),
            name: "Run \(script)",
            command: hasUv ? "uv run \(script)" : "python3 -m \(script)",
            cwd: dir,
            notes: "Detected from [project.scripts] in pyproject.toml"
                + (hasUv ? "" : " — no uv.lock found, verify the module invocation")
        )]
    }

    /// First key of `[project.scripts]` in a pyproject.toml, via a line scan —
    /// enough for suggestions without a TOML dependency.
    private static func firstTomlScript(in text: String) -> String? {
        var inScripts = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inScripts = trimmed == "[project.scripts]"
                continue
            }
            if inScripts, let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { return key }
            }
        }
        return nil
    }

    private static func staticSiteConfigs(
        dir: String, prefix: String, entries: Set<String>
    ) -> [RunConfiguration] {
        guard entries.contains("index.html") else { return [] }
        return [RunConfiguration(
            id: prefix + "static",
            name: dir == "." ? "Static site" : "\(dir) static site",
            command: "python3 -m http.server 8080",
            cwd: dir,
            ports: [8080],
            previewURL: "http://localhost:8080",
            readyPattern: "Serving HTTP",
            notes: "Detected from index.html with no package.json"
        )]
    }
}
