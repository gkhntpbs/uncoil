import Foundation

/// Version checks and updates for the agent CLIs (claude, codex).
enum CLIToolService {
    enum Source: String {
        case homebrew
        case npm
        case nativeInstaller
        case unknown

        var label: String {
            switch self {
            case .homebrew: "Homebrew"
            case .npm: "npm"
            case .nativeInstaller: "yerleşik güncelleyici"
            case .unknown: "bilinmiyor"
            }
        }
    }

    static func source(forBinaryAt path: String, provider: AgentProvider) -> Source {
        if path.contains("/opt/homebrew/") || path.contains("/usr/local/Cellar/") {
            return .homebrew
        }
        if path.contains("node_modules") || path.contains("/.npm") || path.contains("/npm/") {
            return .npm
        }
        if provider == .claude, path.contains("/.local/bin/") {
            return .nativeInstaller
        }
        return .unknown
    }

    /// Shell command that updates the tool, or nil when we can't know how.
    static func updateCommand(provider: AgentProvider, source: Source) -> String? {
        switch (provider, source) {
        case (.claude, .nativeInstaller), (.claude, .unknown):
            return "claude update"
        case (.claude, .npm):
            return "npm install -g @anthropic-ai/claude-code@latest"
        case (.codex, .npm), (.codex, .unknown):
            return "npm install -g @openai/codex@latest"
        case (_, .homebrew):
            return "brew upgrade \(provider.rawValue)"
        default:
            return nil
        }
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
        let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
        return (process.terminationStatus == 0, String(tail))
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
