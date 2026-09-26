import Foundation

/// `uncoil_agents`: what can be run, before anything is.
///
/// An orchestrator deciding "a Codex session on account X with model Y" needs
/// the same facts the new-session sheet shows the user. They come from the
/// same places: the provider descriptors, the user's accounts, and the launch
/// options detected from each installed CLI.
extension CapabilityRouter {
    func handleAgents(_ request: ControlRequest) async -> ControlEnvelope {
        let context = callContext(request)
        guard context.caller != nil else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        guard context.grants.contains("projects.read") else {
            return .failure(request, code: .capabilityDisabled, message: "projects.read is not granted")
        }
        switch request.action {
        case "list":
            return .success(request, data: .object([
                "agents": .array(AgentProvider.agents.map(agentEntry)),
            ]))
        case "inspect":
            guard let raw = request.args["provider"]?.stringValue,
                  let provider = AgentProvider(rawValue: raw), provider.isAgent else {
                return .failure(
                    request, code: .invalidArgument, message: "'provider' must name an agent",
                    details: .object([
                        "valid_providers": .array(AgentProvider.agents.map { .string($0.rawValue) }),
                    ]))
            }
            let launch = await launchCapabilities(provider)
            guard case .object(var entry) = agentEntry(provider) else {
                return .failure(request, code: .internalError, message: "could not describe provider")
            }
            entry["launch"] = .object([
                "models": .array(launch.models.map(option)),
                "efforts": .array(launch.efforts.map(option)),
                "working_modes": .array(launch.workingModes.map { .string($0.rawValue) }),
                "default_model": .string(optional: launch.defaultModelDetail),
            ])
            return .success(request, data: .object(entry))
        default:
            return .failure(request, code: .invalidAction, message: "unsupported agents action")
        }
    }

    private func agentEntry(_ provider: AgentProvider) -> JSONValue {
        let descriptor = provider.descriptor
        let defaultAccount = settings?.defaultAccount(for: provider)?.id
        let accounts = settings?.accounts(for: provider) ?? []
        return .object([
            "provider": .string(provider.rawValue),
            "display_name": .string(descriptor.displayName),
            "full_name": .string(descriptor.fullName),
            "installed": .bool(providerInstalled(provider)),
            "status_source": .string(descriptor.statusSource.rawValue),
            "control_plane": .string(descriptor.controlPlane.rawValue),
            "resumes_conversation": .bool(descriptor.resumesConversation),
            "working_modes": .array(descriptor.workingModes.map { .string($0.rawValue) }),
            "accounts": .array(accounts.map { account in
                .object([
                    "id": .string(account.id.uuidString),
                    "name": .string(account.name),
                    "is_default": .bool(account.id == defaultAccount),
                ])
            }),
        ])
    }

    private func option(_ option: AgentLaunchCapabilities.Option) -> JSONValue {
        .object(["id": .string(option.id), "label": .string(option.label)])
    }
}
