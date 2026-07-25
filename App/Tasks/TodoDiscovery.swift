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

    /// Walks the project for task files. Blocking; call from a background task.
    static func find(
        projectRoot: String,
        rules: Rules = .default,
        ignoredPaths: Set<String>? = nil
    ) -> [Found] {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
        guard manager.fileExists(atPath: root.path) else { return [] }

        let ignored = ignoredPaths ?? (
            rules.respectsGitIgnore ? gitIgnoredPaths(projectRoot: root.path) : []
        )
        var found: [Found] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]

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
                let relative = relativePath(of: url, from: root)
                if ignored.contains(relative) { continue }
                if rules.excludedPaths.contains(relative) { continue }

                if values?.isDirectory == true {
                    guard !rules.excludes(directoryNamed: url.lastPathComponent) else { continue }
                    queue.append((url, entry.depth + 1))
                    continue
                }
                guard rules.isTaskFile(named: url.lastPathComponent) else { continue }
                found.append(Found(
                    path: url.path,
                    displayPath: relative,
                    isRoot: !relative.contains("/")
                ))
            }
        }
        // The project's own TODO first, then the rest alphabetically.
        return found.sorted {
            $0.isRoot != $1.isRoot ? $0.isRoot : $0.displayPath < $1.displayPath
        }
    }

    /// Reads each found file into a parsed document plus its source record.
    static func load(
        projectID: UUID,
        projectRoot: String,
        rules: Rules = .default,
        now: Date = .now
    ) -> [(source: ProjectTaskSource, document: TaskDocument)] {
        find(projectRoot: projectRoot, rules: rules).compactMap { entry in
            guard let raw = try? String(contentsOfFile: entry.path, encoding: .utf8) else {
                return nil
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
            return (source, document)
        }
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
