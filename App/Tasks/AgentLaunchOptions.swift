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
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: " · "))
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
        case .gemini:
            // Only what the installed build documents. No model list is
            // hard-coded: Gemini's names change often enough that a stale one
            // would be handed to `--model` and fail the launch, and there is
            // no `--help` line to read them from the way Claude's efforts are.
            break
        case .opencode:
            // Same reasoning, and more so: OpenCode's model ids are
            // `provider/model` and come from whatever providers the user
            // configured, so no list can be right for two machines. Its
            // `--variant` (reasoning effort) is documented on `run`, not on
            // the TUI Uncoil launches, so no effort picker is offered either.
            break
        case .grok:
            // `--model` and `--reasoning-effort` are both documented, but
            // neither lists its values in `--help`: models come from the
            // account (`grok models`) and the effort levels are named only in
            // config. A picker here would be a guess, so selections made
            // elsewhere are passed through and nothing is offered.
            break
        case .cursor:
            // `--list-models` is an account query, not a help line, so the
            // names cannot be known without running the CLI. Same rule.
            break
        case .hermes:
            // No model list: Hermes' ids are `provider/model` drawn from
            // whatever providers the account has configured, so no fixed list
            // could be right on two machines. The reasoning levels are
            // different — `--reasoning` names its own values in `--help`, so
            // they are read from there rather than hard-coded, exactly as
            // Claude's `--effort` levels are.
            if let helpText, helpText.contains("--reasoning") {
                result.efforts = reasoningLevels(fromHelp: helpText)
                    .map { AgentLaunchCapabilities.Option(id: $0, label: $0) }
            }
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

    /// Hermes names its reasoning levels in prose rather than in parentheses:
    /// "Reasoning effort for this invocation: none, minimal, low, medium, high,
    /// xhigh, max, or ultra. Overrides …". So the list is the comma-separated
    /// run after the colon, stopping at the sentence that follows it — and a
    /// build that adds or drops a level is followed automatically, which is the
    /// whole reason this is read rather than typed out.
    ///
    /// Returns empty rather than a guess when the line cannot be read: no
    /// picker is better than one offering a level the CLI would reject.
    static func reasoningLevels(fromHelp helpText: String) -> [String] {
        guard let flag = helpText.range(of: "--reasoning") else { return [] }
        let after = helpText[flag.upperBound...]
        guard let colon = after.firstIndex(of: ":") else { return [] }
        // The description is wrapped across lines by argparse, so the sentence
        // has to be rejoined before it can be split on commas.
        let sentence = after[after.index(after: colon)...]
            .prefix { $0 != "." }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return sentence
            .split(separator: ",")
            .map {
                $0.replacingOccurrences(of: "or ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && !$0.contains(" ") }
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

    /// Codex's two axes as the app server wants them, rather than as flags.
    ///
    /// The app server takes no command line, so the same choice has to arrive
    /// as two protocol fields — and that second mapping had drifted from the
    /// first: everything it did not name fell through to workspace-write, so
    /// Read Only could write, and "the provider's own settings" was Uncoil's
    /// settings. Kept beside the flag mapping so the two cannot part again.
    static func codexApproval(
        mode: AgentWorkingMode,
        config: String?
    ) -> (approvalPolicy: String, sandbox: String) {
        switch mode.normalized(for: .codex) {
        case .readOnly: ("on-request", "read-only")
        case .askForApproval: ("on-request", "workspace-write")
        case .approveForMe: ("never", "workspace-write")
        case .fullAccess: ("never", "danger-full-access")
        default:
            // What the user set in `~/.codex/config.toml`, which is what
            // "provider default" means. The fallbacks are the pair Uncoil sent
            // before there was any way to ask it to leave the choice alone.
            (
                codexConfigValue(config, key: "approval_policy") ?? "on-request",
                codexConfigValue(config, key: "sandbox_mode") ?? "workspace-write"
            )
        }
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
        case .gemini:
            // `--model` is documented, so it is passed when the user picked
            // one; there is no verified effort flag, so none is invented.
            if let model = selection.model { arguments += ["--model", model] }
        case .opencode:
            // `--model` is on the TUI's own help; `--variant` is not, so an
            // effort picked elsewhere is deliberately not passed here.
            if let model = selection.model { arguments += ["--model", model] }
        case .grok:
            if let model = selection.model { arguments += ["--model", model] }
            if let effort = selection.effort {
                arguments += ["--reasoning-effort", effort]
            }
        case .cursor:
            // `--model` is documented; Cursor carries effort inside the model
            // id (`claude-opus-4-8[effort=high]`) rather than as a flag, so
            // there is nothing separate to pass.
            if let model = selection.model { arguments += ["--model", model] }
        case .hermes:
            // Both documented on the top-level parser: `-m/--model` and
            // `--reasoning LEVEL`.
            if let model = selection.model { arguments += ["-m", model] }
            if let effort = selection.effort { arguments += ["--reasoning", effort] }
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
