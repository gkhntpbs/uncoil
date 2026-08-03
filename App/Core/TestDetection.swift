import Foundation

/// Proposes test suites for a repository.
///
/// Reads through the same injectable filesystem as `RunDetection`, and follows
/// the same rule: everything returned is a suggestion with `source == .detected`,
/// and merging never touches what a user or an agent wrote.
///
/// A suite is only proposed when the project says it has tests. A `package.json`
/// with no `test` script, or one whose script is npm's own "no test specified"
/// placeholder, is a project without tests — and offering to run it produces a
/// green tick from a command that tested nothing.
enum TestDetection {
    static func detect(fileSystem: RunDetectionFileSystem) -> [TestSuiteConfiguration] {
        var results = detect(in: ".", prefix: "", fileSystem: fileSystem)
        for name in fileSystem.list(".").sorted() {
            guard !name.hasPrefix("."), !ignoredDirectories.contains(name),
                  !name.contains("."), fileSystem.isDirectory(name) else { continue }
            results += detect(in: name, prefix: slug(name) + "-", fileSystem: fileSystem)
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".build", ".build-cache", "backups", "dist",
        "build", "out", "Pods", "vendor", ".uncoil-worktrees", "DerivedData",
        ".next", ".venv", "venv", "__pycache__", "exports", "cache", "logs",
    ]

    private static func detect(
        in dir: String, prefix: String, fileSystem: RunDetectionFileSystem
    ) -> [TestSuiteConfiguration] {
        let entries = Set(fileSystem.list(dir))
        var suites: [TestSuiteConfiguration] = []
        suites += xcodeSuites(dir: dir, prefix: prefix, entries: entries)
        suites += swiftSuites(dir: dir, prefix: prefix, entries: entries)
        suites += goSuites(dir: dir, prefix: prefix, entries: entries)
        suites += cargoSuites(dir: dir, prefix: prefix, entries: entries)
        suites += nodeSuites(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        suites += pythonSuites(dir: dir, prefix: prefix, entries: entries, fs: fileSystem)
        return suites
    }

    private static func path(_ dir: String, _ name: String) -> String {
        dir == "." ? name : "\(dir)/\(name)"
    }

    private static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    // MARK: - Apple

    /// An Xcode container wins over a bare `swift test`: a project with an
    /// `.xcodeproj` has its tests wired to a scheme, and `swift test` on it
    /// either fails or silently runs a different, smaller set.
    private static func xcodeSuites(
        dir: String, prefix: String, entries: Set<String>
    ) -> [TestSuiteConfiguration] {
        let workspace = entries.first { $0.hasSuffix(".xcworkspace") }
        let project = entries.first { $0.hasSuffix(".xcodeproj") }
        guard workspace != nil || project != nil else { return [] }
        let container = workspace.map { "-workspace \"\($0)\"" } ?? "-project \"\(project!)\""
        let scheme = ((workspace ?? project)! as NSString).deletingPathExtension
        return [TestSuiteConfiguration(
            id: prefix + "xcode-test",
            name: "Test \(scheme)",
            command: "xcodebuild \(container) -scheme \"\(scheme)\" "
                + "-destination 'platform=macOS,arch=arm64' "
                + "-derivedDataPath .build-cache/DerivedData test",
            cwd: dir,
            framework: .xcodebuild,
            notes: "Scheme guessed from the container name — run `xcodebuild -list` to "
                + "verify, and change the destination for iOS/simulator targets."
        )]
    }

    private static func swiftSuites(
        dir: String, prefix: String, entries: Set<String>
    ) -> [TestSuiteConfiguration] {
        guard entries.contains("Package.swift"),
              !entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        else { return [] }
        return [TestSuiteConfiguration(
            id: prefix + "swift-test",
            name: dir == "." ? "swift test" : "\(dir) swift test",
            command: "swift test",
            cwd: dir,
            framework: .swift,
            notes: "Detected from Package.swift"
        )]
    }

    // MARK: - Go, Rust

    private static func goSuites(
        dir: String, prefix: String, entries: Set<String>
    ) -> [TestSuiteConfiguration] {
        guard entries.contains("go.mod") else { return [] }
        return [TestSuiteConfiguration(
            id: prefix + "go-test",
            name: dir == "." ? "go test" : "\(dir) go test",
            // -json, because go's plain output reports a package summary and
            // leaves individual results to be inferred from indentation.
            command: "go test -json ./...",
            cwd: dir,
            framework: .go,
            notes: "Detected from go.mod"
        )]
    }

    private static func cargoSuites(
        dir: String, prefix: String, entries: Set<String>
    ) -> [TestSuiteConfiguration] {
        guard entries.contains("Cargo.toml") else { return [] }
        return [TestSuiteConfiguration(
            id: prefix + "cargo-test",
            name: dir == "." ? "cargo test" : "\(dir) cargo test",
            command: "cargo test",
            cwd: dir,
            framework: .cargo,
            notes: "Detected from Cargo.toml"
        )]
    }

    // MARK: - Node

    /// npm writes a placeholder `test` script into every `npm init` project:
    /// it prints "Error: no test specified" and exits 1. Treating that as a
    /// suite would offer to run a command that tests nothing.
    static let npmPlaceholderMarker = "no test specified"

    private static func nodeSuites(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [TestSuiteConfiguration] {
        guard entries.contains("package.json"),
              let text = fs.read(path(dir, "package.json")),
              let data = text.data(using: .utf8),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = raw.objectValue
        else { return [] }
        let scripts = object["scripts"]?.objectValue ?? [:]
        guard let body = scripts["test"]?.stringValue,
              !body.contains(npmPlaceholderMarker) else { return [] }

        let packageManager = entries.contains("pnpm-lock.yaml") ? "pnpm"
            : entries.contains("yarn.lock") ? "yarn"
            : entries.contains("bun.lockb") || entries.contains("bun.lock") ? "bun"
            : "npm"
        // Both Jest and Vitest print the same per-test lines, so one parser
        // covers them; anything else runs but reports a total only.
        let framework: TestFramework = body.contains("jest") || body.contains("vitest")
            ? .jest : .unknown
        return [TestSuiteConfiguration(
            id: prefix + "npm-test",
            name: dir == "." ? "Tests" : "\(dir) tests",
            command: packageManager == "npm" ? "npm test" : "\(packageManager) test",
            cwd: dir,
            framework: framework,
            notes: framework == .unknown
                ? "Detected from the package.json 'test' script: \(body) — the output format "
                    + "is not recognised, so only the overall result is reported"
                : "Detected from the package.json 'test' script: \(body)"
        )]
    }

    // MARK: - Python

    private static func pythonSuites(
        dir: String, prefix: String, entries: Set<String>, fs: RunDetectionFileSystem
    ) -> [TestSuiteConfiguration] {
        // A tests directory alone is not enough: pytest has to actually be the
        // runner, and that is what these files say.
        let declaresPytest = entries.contains("pytest.ini")
            || entries.contains("tox.ini")
            || (fs.read(path(dir, "pyproject.toml"))?.contains("pytest") ?? false)
            || (fs.read(path(dir, "setup.cfg"))?.contains("[tool:pytest]") ?? false)
        guard declaresPytest else { return [] }
        let hasUv = entries.contains("uv.lock")
        return [TestSuiteConfiguration(
            id: prefix + "pytest",
            name: dir == "." ? "pytest" : "\(dir) pytest",
            // -v, because pytest's default output is a row of dots with no test
            // names in it at all.
            command: (hasUv ? "uv run pytest -v" : "python3 -m pytest -v"),
            cwd: dir,
            framework: .pytest,
            notes: "Detected from a pytest configuration"
        )]
    }
}
