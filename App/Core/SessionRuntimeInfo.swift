import Foundation

/// What model and effort a session is actually running with, and how sure
/// Uncoil is about it.
///
/// Three different things could answer "which model?", and they disagree:
/// what the user picked at launch, what the provider defaults to, and what the
/// agent is using right now after someone typed `/model` inside it. The status
/// bar has to show one of them without pretending to know more than it does —
/// a confidently wrong model is worse than an honest "default".
struct SessionRuntimeInfo: Equatable {
    /// Where a displayed value came from. Drives the tooltip, not the text:
    /// the chip stays short, the explanation is on hover.
    enum Source: Equatable {
        /// The agent itself said so, in a hook payload.
        case reported
        /// The user chose it when the session was launched.
        case chosen
        /// Nobody chose; this is what the provider's own configuration says.
        case providerDefault
    }

    var model: String?
    var modelSource: Source?
    var effort: String?
    var effortSource: Source?

    /// "opus · high", or nil when nothing is known.
    var summary: String? {
        let parts = [model, effort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Resolves the three answers in order of authority.
    ///
    /// - `reportedModel` wins: it is the agent describing itself, so it follows
    ///   a `/model` typed inside the session, which nothing else can see.
    /// - then the launch selection, which is what the user asked for.
    /// - then the provider's resolved default, where it is known — Codex writes
    ///   its model into its own config, so Uncoil can read the same file.
    ///
    /// Effort has no reported source: no agent puts it in a hook payload, so it
    /// is the launch selection or nothing. Showing the provider's default
    /// effort would be a guess, and this is exactly where a guess costs.
    static func resolve(
        reportedModel: String?,
        selection: AgentLaunchSelection?,
        defaultModelDetail: String?
    ) -> SessionRuntimeInfo {
        var info = SessionRuntimeInfo()

        if let reportedModel, !reportedModel.isEmpty {
            info.model = reportedModel
            info.modelSource = .reported
        } else if let chosen = selection?.model, !chosen.isEmpty {
            info.model = chosen
            info.modelSource = .chosen
        } else if let fallback = defaultModelDetail, !fallback.isEmpty {
            info.model = fallback
            info.modelSource = .providerDefault
        }

        if let effort = selection?.effort, !effort.isEmpty {
            info.effort = effort
            info.effortSource = .chosen
        }

        return info
    }

    /// The hover text: says what each value is and where it came from, so the
    /// difference between "you picked this" and "this is just the default" is
    /// readable rather than implied.
    var help: String? {
        var lines: [String] = []
        if let model, let modelSource {
            lines.append(String(localized: "Model: \(model) — \(modelSource.explanation)"))
        }
        if let effort, let effortSource {
            lines.append(String(localized: "Effort: \(effort) — \(effortSource.explanation)"))
        } else if model != nil {
            lines.append(String(localized: "Effort: not set, so the CLI's own default."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension SessionRuntimeInfo.Source {
    var explanation: String {
        switch self {
        case .reported: String(localized: "reported by the agent")
        case .chosen: String(localized: "chosen when this session started")
        case .providerDefault: String(localized: "the provider's default")
        }
    }
}
