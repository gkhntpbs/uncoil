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

    /// The newest version, asked of the channel this install came from.
    ///
    /// `brewOutdated` is passed in rather than read here so the whole set of
    /// Homebrew packages is fetched once per check instead of once per agent.
    static func latestVersion(
        provider: AgentProvider,
        source: AgentInstallSource,
        binaryPath: String?,
        installed: String?,
        brewOutdated: [String: String]
    ) async -> String? {
        switch AgentUpdateCheck.versionSource(provider: provider, source: source) {
        case .npm(let package):
            return await npmLatestVersion(package: package)
        case .selfReport(let arguments):
            guard let binaryPath else { return nil }
            return await Task.detached(priority: .utility) {
                run(binaryPath, arguments, timeout: 20).flatMap(SelfReportedUpdate.latestVersion)
            }.value
        case .homebrew(let name):
            // Absent from `brew outdated` means Homebrew has nothing newer,
            // which is the answer "you are up to date" — handed back as the
            // installed version rather than as nil, because nil means "not
            // known yet" and would leave the row checking forever.
            //
            // The installed version comes from the tool itself rather than
            // from a second `brew list --versions`: that command does not list
            // casks, so asking it about Codex — which is a cask — answered
            // nothing at all.
            return brewOutdated[name] ?? installed
        case .none:
            return nil
        }
    }

    /// Latest published version from the npm registry.
    static func npmLatestVersion(package: String) async -> String? {
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

    /// What Homebrew has that is newer than what is installed, for everything
    /// at once. Empty when Homebrew is not on this machine.
    ///
    /// Blocking; call from a background task.
    static func brewOutdated() -> [String: String] {
        guard let brew = brewPath else { return [:] }
        guard let data = run(brew, ["outdated", "--json=v2"], timeout: 60) else { return [:] }
        return HomebrewOutdated.parse(data)
    }

    static var brewPath: String? {
        BinarySearchPath.locate("brew")
            ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The PATH anything Uncoil runs on the user's behalf must run with.
    ///
    /// An update is only correct if it runs the same programs the user's own
    /// terminal would. A login shell is not enough for that: `zsh -l` sources
    /// `.zprofile` but not `.zshrc`, and a version manager — nvm, above all —
    /// is initialised in `.zshrc`. Under `zsh -l -c`, nvm's npm therefore runs
    /// under Homebrew's node and installs into Homebrew's tree, which is an
    /// update that succeeds and changes nothing. Handing the interactive
    /// shell's own PATH to a plain `zsh -c` is what makes the two agree.
    static func shellEnvironment(prepending directories: [String] = []) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let ordered = (directories + SettingsStore.interactivePATH + existing)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if !ordered.isEmpty { environment["PATH"] = ordered.joined(separator: ":") }
        return environment
    }

    /// Runs the update command with the user's own PATH.
    /// Blocking (can take minutes); call from a background task.
    static func runUpdate(command: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = shellEnvironment()
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
        run("/bin/zsh", ["-c", command], timeout: timeout)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Runs a tool with the user's own PATH and gives back its stdout, or nil
    /// if it failed or ran out of time.
    ///
    /// stderr is discarded into a pipe nobody reads only up to the point where
    /// that is safe: it is drained alongside stdout, because a tool that
    /// writes more than a pipe will hold and is never read blocks forever, and
    /// takes the wait with it.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = shellEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let done = DispatchGroup()
        done.enter()
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
