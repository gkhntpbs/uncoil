import Foundation

/// What the user picked for a new agent session: model, effort and working
/// mode. `nil` everywhere means "the provider's own default" — Uncoil adds no
/// flag it wasn't asked for.
struct AgentLaunchSelection: Equatable, Codable {
    var model: String?
    var effort: String?
    var workingMode: AgentWorkingMode?

    static let providerDefault = AgentLaunchSelection()

    var isDefault: Bool { self == .providerDefault }

    /// One line for messages: "opus · high · Plan", or nil when default.
    var summary: String? {
        let parts = [model, effort, workingMode.map(\.rawValue)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What each installed agent CLI can actually be asked for.
///
/// The lists are not invented: Claude's come from its own `--help` (models and
/// efforts are only offered when the flag exists in the installed build), and
/// Codex's default model is read from the user's `~/.codex/config.toml` — the
/// same file the CLI itself reads.
struct AgentLaunchCapabilities: Equatable {
    struct Option: Equatable, Identifiable {
        let id: String
        var label: String
    }

    /// Empty = the CLI takes no model flag; the picker is not shown.
    var models: [Option] = []
    /// Empty = no effort control.
    var efforts: [Option] = []
    var workingModes: [AgentWorkingMode] = []
    /// What "default" currently resolves to, when known (Codex config).
    var defaultModelDetail: String?
}

/// Builds capabilities and the launch arguments a selection turns into.
enum AgentLaunchCatalog {
    // MARK: - Capabilities

    /// Pure part, testable: capabilities from the CLI's own help text.
    static func capabilities(
        for provider: AgentProvider,
        helpText: String?,
        codexConfig: String? = nil
    ) -> AgentLaunchCapabilities {
        var result = AgentLaunchCapabilities(
            workingModes: AgentWorkingMode.options(for: provider)
        )
        switch provider {
        case .claude:
            // Aliases the help text documents; a build without the flag gets no
            // picker instead of a guessed one.
            if helpText?.contains("--model") ?? false {
                result.models = [
                    AgentLaunchCapabilities.Option(id: "fable", label: "Fable"),
                    AgentLaunchCapabilities.Option(id: "opus", label: "Opus"),
                    AgentLaunchCapabilities.Option(id: "sonnet", label: "Sonnet"),
                    AgentLaunchCapabilities.Option(id: "haiku", label: "Haiku"),
                ]
            }
            if let helpText, helpText.contains("--effort") {
                // "(low, medium, high, xhigh, max)" — read from the help line so
                // a build that adds or drops a level is followed automatically.
                result.efforts = effortLevels(fromHelp: helpText)
                    .map { AgentLaunchCapabilities.Option(id: $0, label: $0) }
            }
        case .codex:
            if helpText?.contains("--model") ?? false {
                var options: [AgentLaunchCapabilities.Option] = []
                if let current = codexConfigValue(codexConfig, key: "model") {
                    options.append(AgentLaunchCapabilities.Option(id: current, label: current))
                    result.defaultModelDetail = current
                }
                result.models = options
            }
            // `model_reasoning_effort` is config, not a flag, so help says
            // nothing about it; the levels are the ones the config accepts.
            result.efforts = ["minimal", "low", "medium", "high", "xhigh"]
                .map { AgentLaunchCapabilities.Option(id: $0, label: $0) }
        case .terminal:
            break
        }
        return result
    }

    /// The levels inside "(low, medium, high, xhigh, max)" on the --effort line.
    static func effortLevels(fromHelp helpText: String) -> [String] {
        guard let range = helpText.range(of: "--effort") else { return [] }
        let after = helpText[range.upperBound...]
        guard let open = after.firstIndex(of: "("),
              let close = after[open...].firstIndex(of: ")") else {
            return ["low", "medium", "high"]
        }
        let levels = after[after.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        return levels.isEmpty ? ["low", "medium", "high"] : levels
    }

    /// `model = "gpt-…"` from a TOML the CLI wrote. Line-based on purpose: a
    /// full TOML parser for one key is more code than the key deserves.
    static func codexConfigValue(_ config: String?, key: String) -> String? {
        guard let config else { return nil }
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only the top-level assignment; `[section]` ends the preamble.
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Arguments

    /// The exact flags a selection adds to the launch command. Working-mode
    /// arguments are handled by `AgentWorkingMode.launchArguments` and composed
    /// here so a dispatch needs one call.
    static func launchArguments(
        for provider: AgentProvider,
        selection: AgentLaunchSelection
    ) -> [String] {
        var arguments: [String] = []
        switch provider {
        case .claude:
            if let model = selection.model { arguments += ["--model", model] }
            if let effort = selection.effort { arguments += ["--effort", effort] }
        case .codex:
            if let model = selection.model { arguments += ["-m", model] }
            if let effort = selection.effort {
                arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
        case .terminal:
            break
        }
        if let mode = selection.workingMode {
            arguments += mode.normalized(for: provider).launchArguments(for: provider)
        }
        return arguments
    }

    // MARK: - Detection

    /// Probes the installed CLI once per provider and remembers the answer for
    /// the rest of the run; a `--help` call per sheet-open would be waste.
    @MainActor private static var cache: [String: AgentLaunchCapabilities] = [:]

    @MainActor
    static func detect(
        provider: AgentProvider,
        binaryPath: String?
    ) async -> AgentLaunchCapabilities {
        if let cached = cache[provider.rawValue] { return cached }
        let helpText = await Task.detached(priority: .utility) {
            helpOutput(binaryPath: binaryPath, name: provider.launchCommand)
        }.value
        let codexConfig = provider == .codex
            ? try? String(
                contentsOf: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/config.toml"),
                encoding: .utf8
            )
            : nil
        let result = capabilities(
            for: provider, helpText: helpText, codexConfig: codexConfig
        )
        cache[provider.rawValue] = result
        return result
    }

    private nonisolated static func helpOutput(binaryPath: String?, name: String?) -> String? {
        guard let executable = binaryPath
            ?? name.flatMap({ AgentAdapterSupport.locateBinary($0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
