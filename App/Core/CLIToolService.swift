import Foundation

/// Version checks and updates for the agent CLIs (claude, codex).
enum CLIToolService {
    /// Where a launcher really points. The launcher is nearly always a
    /// symlink, and which install it belongs to — and therefore how it is
    /// updated — is only visible at the other end of it.
    static func resolvedPath(of path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == path ? nil : resolved
    }

    static func source(
        forBinaryAt path: String, provider: AgentProvider
    ) -> AgentInstallSource {
        AgentCLIInstall.source(
            path: path, resolvedPath: resolvedPath(of: path), provider: provider
        )
    }

    /// Shell command that updates the tool, or why there is none.
    static func updatePlan(
        provider: AgentProvider, source: AgentInstallSource
    ) -> AgentUpdatePlan {
        AgentCLIInstall.updatePlan(provider: provider, source: source) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func npmPackage(for provider: AgentProvider) -> String {
        AgentCLIInstall.npmPackage(for: provider)
    }

    /// Latest published version from the npm registry (both CLIs publish
    /// there regardless of how they were installed locally).
    static func latestVersion(provider: AgentProvider) async -> String? {
        let package = npmPackage(for: provider)
        guard !package.isEmpty,
              let url = URL(string: "https://registry.npmjs.org/\(package)/latest") else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["version"] as? String
    }

    /// First x.y.z found in a version string ("2.1.218 (Claude Code)" -> 2.1.218).
    static func semver(_ string: String?) -> [Int]? {
        guard let string,
              let range = string.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return string[range].split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ latest: String?, than installed: String?) -> Bool {
        guard let latestParts = semver(latest), let installedParts = semver(installed) else {
            return false
        }
        for (l, i) in zip(latestParts, installedParts) where l != i {
            return l > i
        }
        return false
    }

    /// Blocking; call from a background task.
    static func version(binaryPath: String) -> String? {
        runLoginShell("\"\(binaryPath)\" --version 2>/dev/null | head -1", timeout: 20)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the update command through the user's login shell.
    /// Blocking (can take minutes); call from a background task.
    static func runUpdate(command: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A failing `npm install -g` ends with a log path, not the reason —
        // the reason is further up. Keeping only the last three lines was
        // reporting the least useful part of every failure.
        let lines = output.split(separator: "\n")
        let kept = process.terminationStatus == 0
            ? lines.suffix(3)
            : lines.suffix(12)
        return (process.terminationStatus == 0, kept.joined(separator: "\n"))
    }

    private static func runLoginShell(_ command: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
