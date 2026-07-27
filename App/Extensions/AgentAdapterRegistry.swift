import Foundation

/// The adapters Uncoil ships, and the detection pass over them. Agents without
/// an adapter are still listed by `ExtensionAgentID.allCases` so the UI can say
/// "not managed yet" instead of pretending they do not exist.
@MainActor
struct AgentAdapterRegistry {
    var adapters: [any AgentAdapter]

    init(adapters: [any AgentAdapter]? = nil) {
        self.adapters = adapters ?? [ClaudeCodeAdapter(), CodexAdapter()]
            + JSONMCPConfigLayout.all.map { JSONMCPAdapter(layout: $0) }
    }

    func adapter(for agent: ExtensionAgentID) -> (any AgentAdapter)? {
        adapters.first { $0.agent == agent }
    }

    /// Every install found across every adapter.
    func detectInstallations() -> [AgentInstallation] {
        adapters.flatMap { $0.detectInstallations() }
    }

    /// Agents listed in the UI but not managed by any adapter yet.
    var unmanagedAgents: [ExtensionAgentID] {
        let managed = Set(adapters.map(\.agent))
        return ExtensionAgentID.allCases.filter { !managed.contains($0) }
    }

    /// Reads each detected installation, returning what could be read plus the
    /// failures — a broken config must never hide the healthy ones.
    func readAll(
        installations detected: [AgentInstallation]? = nil
    ) -> (configurations: [AgentConfiguration], failures: [ConfigurationIssue]) {
        var configurations: [AgentConfiguration] = []
        var failures: [ConfigurationIssue] = []
        let byAgent = detected.map { Dictionary(grouping: $0, by: \.agent) }
        for adapter in adapters {
            for installation in byAgent?[adapter.agent] ?? adapter.detectInstallations() {
                do {
                    configurations.append(try adapter.readConfiguration(installation))
                } catch {
                    failures.append(ConfigurationIssue(
                        id: "read.\(installation.id)",
                        severity: .error,
                        message: error.localizedDescription,
                        remedy: nil
                    ))
                }
            }
        }
        return (configurations, failures)
    }
}
