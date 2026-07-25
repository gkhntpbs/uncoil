import Foundation

/// Finds the `TODO.md` files under a project.
///
/// Scanning is bounded on purpose: build outputs and dependency trees hold
/// thousands of files and none of their TODOs belong to the user's project, so
/// they are skipped by name, and anything the project's own ignore rules exclude
/// is skipped too. The user can widen or narrow that with their own rules.
enum TodoDiscovery {
    /// Directory names never scanned. Matched by name at any depth.
    static let defaultExcludedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods",
        "vendor", ".swiftpm", ".venv", "venv", "dist", ".next", ".gradle",
        "Carthage", ".yarn", "target", "__pycache__", ".uncoil-worktrees",
        ".build-cache",
    ]

    /// File names treated as task sources.
    static let defaultFileNames: Set<String> = ["TODO.md", "todo.md", "TODOS.md"]

    /// User-tunable scan rules, stored per project.
    struct Rules: Equatable, Codable {
        /// Extra directory names to skip, on top of the defaults.
        var excludedDirectories: [String] = []
        /// Directory names to scan even though a default rule excludes them.
        var includedDirectories: [String] = []
        /// Extra file names to treat as task sources.
        var additionalFileNames: [String] = []
        /// Relative paths (from the project root) to ignore outright.
        var excludedPaths: [String] = []
        /// Honour `.gitignore`, so generated trees stay out without extra rules.
        var respectsGitIgnore = true
        /// Depth guard; a deeper tree is almost certainly not hand-written tasks.
        var maximumDepth = 8

        static let `default` = Rules()

        func excludes(directoryNamed name: String) -> Bool {
            if includedDirectories.contains(name) { return false }
            return defaultExcludedDirectories.contains(name)
                || excludedDirectories.contains(name)
        }

        func isTaskFile(named name: String) -> Bool {
            defaultFileNames.contains(name) || additionalFileNames.contains(name)
        }
    }

    struct Found: Equatable, Identifiable {
        var path: String
        /// Path relative to the project root, for display.
        var displayPath: String
        var isRoot: Bool

        var id: String { path }
    }

    /// Cheap on-disk fingerprint of a file: enough to decide "nothing happened
    /// here" without opening and reparsing it.
    struct FileStamp: Equatable, Sendable {
        var modified: TimeInterval
        var size: Int64
    }

    /// One source served by a scan, plus how it was obtained.
    struct LoadedSource: Equatable {
        var source: ProjectTaskSource
        var document: TaskDocument
    }

    /// What a previous scan already knows about a path, so an unchanged file is
    /// never read again.
    struct CachedSource {
        var stamp: FileStamp
        var source: ProjectTaskSource
        var document: TaskDocument

        init(stamp: FileStamp, source: ProjectTaskSource, document: TaskDocument) {
            self.stamp = stamp
            self.source = source
            self.document = document
        }
    }

    struct ScanResult {
        var entries: [LoadedSource]
        var stamps: [String: FileStamp]
        /// Paths answered from the cache — not read or parsed this time.
        var reusedPaths: Set<String>

        var loaded: [(source: ProjectTaskSource, document: TaskDocument)] {
            entries.map { ($0.source, $0.document) }
        }
    }

    /// Walks the project for task files. Blocking; call from a background task.
    static func find(
        projectRoot: String,
        rules: Rules = .default,
        ignoredPaths: Set<String>? = nil,
        firstMatchOnly: Bool = false
    ) -> [Found] {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: projectRoot)
        guard manager.fileExists(atPath: root.path) else { return [] }

        let ignored = ignoredPaths ?? (
            rules.respectsGitIgnore ? gitIgnoredPaths(projectRoot: root.path) : []
        )
        var found: [Found] = []
        // The relative path is carried through the walk rather than derived by
        // string-prefixing the root: on macOS an enumerated child comes back as
        // /private/var/... while every URL normalisation turns the root back into
        // /var/..., so prefix matching silently fails and display paths collapse
        // to bare file names.
        var queue: [(url: URL, relative: String, depth: Int)] = [(root, "", 0)]

        while let entry = queue.first {
            queue.removeFirst()
            guard entry.depth <= rules.maximumDepth else { continue }
            guard let contents = try? manager.contentsOfDirectory(
                at: entry.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }

            for url in contents.sorted(by: { $0.path < $1.path }) {
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                // Symlinked directories can loop; a task file is expected to be
                // a real file in the project.
                if values?.isSymbolicLink == true { continue }
                let name = url.lastPathComponent
                let relative = entry.relative.isEmpty ? name : "\(entry.relative)/\(name)"
                if ignored.contains(relative) { continue }
                if rules.excludedPaths.contains(relative) { continue }

                if values?.isDirectory == true {
                    guard !rules.excludes(directoryNamed: name) else { continue }
                    queue.append((url, relative, entry.depth + 1))
                    continue
                }
                guard rules.isTaskFile(named: url.lastPathComponent) else { continue }
                found.append(Found(
                    path: url.path,
                    displayPath: relative,
                    isRoot: !relative.contains("/")
                ))
                // An existence check has its answer; walking the rest of the
                // tree would cost the same as a full scan.
                if firstMatchOnly { return found }
            }
        }
        // The project's own TODO first, then the rest alphabetically.
        return found.sorted {
            $0.isRoot != $1.isRoot ? $0.isRoot : $0.displayPath < $1.displayPath
        }
    }

    /// True when the project has at least one task source. Stops at the first
    /// hit and never opens a file, so the UI can decide whether a Tasks tab is
    /// worth showing without paying for a parse.
    static func hasSources(projectRoot: String, rules: Rules = .default) -> Bool {
        !find(projectRoot: projectRoot, rules: rules, firstMatchOnly: true).isEmpty
    }

    /// mtime and size of a path, or nil when it is gone.
    static func stamp(atPath path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(modified: modified, size: Int64(info.st_size))
    }

    /// Stamps every task source without reading any of them — the poll's "did
    /// anything actually change?" question.
    static func stamps(projectRoot: String, rules: Rules = .default) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for entry in find(projectRoot: projectRoot, rules: rules) {
            result[entry.path] = stamp(atPath: entry.path)
        }
        return result
    }

    /// Reads each found file into a parsed document plus its source record,
    /// reusing anything in `cache` whose mtime and size are untouched.
    ///
    /// Blocking: walks the tree and parses Markdown, so it belongs off the main
    /// actor.
    static func scan(
        projectID: UUID,
        projectRoot: String,
        rules: Rules = .default,
        now: Date = .now,
        cache: [String: CachedSource] = [:]
    ) -> ScanResult {
        var entries: [LoadedSource] = []
        var stamps: [String: FileStamp] = [:]
        var reused: Set<String> = []

        for entry in find(projectRoot: projectRoot, rules: rules) {
            let current = stamp(atPath: entry.path)
            stamps[entry.path] = current
            // An untouched file is by far the common case on a poll; re-reading
            // and reparsing it is what made every tick cost a full scan.
            if let current, let cached = cache[entry.path], cached.stamp == current {
                reused.insert(entry.path)
                entries.append(LoadedSource(source: cached.source, document: cached.document))
                continue
            }
            guard let raw = try? String(contentsOfFile: entry.path, encoding: .utf8) else {
                stamps[entry.path] = nil
                continue
            }
            let document = TodoParser.parse(raw, path: entry.path)
            let source = ProjectTaskSource(
                path: entry.path,
                projectID: projectID,
                displayPath: entry.displayPath,
                contentHash: document.contentHash,
                lastReadAt: now,
                taskCount: document.tasks.count,
                openTaskCount: document.openTasks.count
            )
            entries.append(LoadedSource(source: source, document: document))
        }
        return ScanResult(entries: entries, stamps: stamps, reusedPaths: reused)
    }

    /// Reads each found file into a parsed document plus its source record.
    static func load(
        projectID: UUID,
        projectRoot: String,
        rules: Rules = .default,
        now: Date = .now
    ) -> [(source: ProjectTaskSource, document: TaskDocument)] {
        scan(projectID: projectID, projectRoot: projectRoot, rules: rules, now: now).loaded
    }

    /// Every task across every source, in source order — the aggregate view.
    static func aggregate(
        _ loaded: [(source: ProjectTaskSource, document: TaskDocument)]
    ) -> [ProjectTask] {
        loaded.flatMap(\.document.tasks)
    }

    static func relativePath(of url: URL, from root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Paths git itself reports as ignored, so generated trees are skipped
    /// without Uncoil reimplementing `.gitignore` semantics.
    static func gitIgnoredPaths(projectRoot: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", projectRoot, "ls-files", "--others", "--ignored",
            "--exclude-standard", "--directory",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
                .filter { !$0.isEmpty }
        )
    }
}

/// Optional portable task ids.
///
/// Off by default: Uncoil's fingerprints work without touching the file, and a
/// `TODO.md` should stay something any agent or editor can own. When a user turns
/// it on, the id is a plain HTML comment — invisible in rendered Markdown and
/// meaningless to tools that ignore it — and it travels with the task's block.
enum PortableTaskID {
    static let prefix = "uncoil:task:"

    /// `<!-- uncoil:task:<id> -->`
    static func comment(for id: String) -> String {
        "<!-- \(prefix)\(id) -->"
    }

    /// Reads an id out of a task's raw block, if one is present.
    static func parse(inBlock block: String) -> String? {
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"),
                  let range = trimmed.range(of: prefix) else { continue }
            let value = trimmed[range.upperBound...]
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The line to insert for a task, indented to sit inside its block so moving
    /// the task moves its id.
    static func line(for id: String, indent: String) -> String {
        "\(indent)  \(comment(for: id))"
    }

    /// True when the file already carries an id for this task.
    static func hasID(inBlock block: String) -> Bool {
        parse(inBlock: block) != nil
    }
}
