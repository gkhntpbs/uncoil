import Foundation

/// Everything a session started through the control plane can be asked for —
/// the same choices the app's own launchers offer, and nothing they don't.
///
/// Parsed and validated here, then created through `ProjectStore` and started
/// through the router's `childLauncher`, which is the app's normal terminal
/// path. So a session an agent creates is the same kind of thing as one the
/// user creates: same record, same launch selection, same account isolation,
/// same sidebar row.
struct SessionCreationSpec: Equatable {
    var provider: AgentProvider
    var accountID: UUID?
    var projectID: UUID
    var worktreePath: String?
    var launch: AgentLaunchSelection
    var title: String?
    var initialPrompt: String?
    var capabilities: [String]
    var extraArguments: [String]
    var presetID: String?
    var warnings: [String] = []
}

extension CapabilityRouter {
    static let initialPromptLimit = 16_000

    /// Parses `create_session` / `create_child` arguments against the caller
    /// and the app's settings. Returns the spec, or the envelope that says
    /// what is wrong with the request.
    func sessionCreationSpec(
        _ request: ControlRequest,
        context: ControlCallContext,
        requirePreset: Bool
    ) async -> Result<SessionCreationSpec, ControlEnvelopeError> {
        guard let caller = context.caller else {
            return .failure(.init(.failure(request, code: .unknownSession, message: "caller session not found")))
        }
        guard let settings else {
            return .failure(.init(.failure(request, code: .controlPlaneUnavailable, message: "settings unavailable")))
        }
        func invalid(_ message: String, _ details: JSONValue? = nil) -> Result<SessionCreationSpec, ControlEnvelopeError> {
            .failure(.init(.failure(request, code: .invalidArgument, message: message, details: details)))
        }
        let args = request.args

        // A preset is a role: which grants the new session may hold and which
        // extra arguments its agent starts with. Optional for create_session.
        var preset: SessionPreset?
        if let presetID = args["preset_id"]?.stringValue {
            guard let found = settings.preset(id: presetID) else {
                return invalid("unknown preset_id '\(presetID)'",
                    .object(["valid_presets": .array(settings.presets.map { .string($0.id) })]))
            }
            preset = found
        } else if requirePreset {
            return invalid("'preset_id' is required")
        }

        // Provider: explicit, else the preset's, else the caller's own.
        var provider = preset?.provider ?? caller.provider
        if let raw = args["provider"]?.stringValue {
            guard let parsed = AgentProvider(rawValue: raw) else {
                return invalid("unknown provider '\(raw)'",
                    .object(["valid_providers": .array(AgentProvider.agents.map { .string($0.rawValue) })]))
            }
            provider = parsed
        }
        // No raw shell through the control plane: a plain terminal's
        // "initial prompt" would be a command line.
        guard provider.isAgent else {
            return invalid("provider '\(provider.rawValue)' is not an agent; the control plane does not start shells")
        }
        guard providerInstalled(provider) else {
            return .failure(.init(.failure(
                request, code: .providerUnavailable,
                message: "\(provider.descriptor.fullName) is not installed", retryable: false)))
        }

        // Project and cross-project gating.
        var projectID = caller.projectID
        if let raw = args["project_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), project(id: id) != nil else {
                return .failure(.init(.failure(request, code: .unknownProject, message: "project not found")))
            }
            if id != caller.projectID, !context.grants.contains("sessions.cross_project") {
                return .failure(.init(.failure(
                    request, code: .permissionDenied,
                    message: "a session in another project requires the sessions.cross_project grant")))
            }
            projectID = id
        }
        guard let project = project(id: projectID) else {
            return .failure(.init(.failure(request, code: .unknownProject, message: "project not found")))
        }

        var worktreePath: String?
        if let raw = args["worktree_path"]?.stringValue ?? args["worktree_id"]?.stringValue {
            let worktrees = worktreeLister(project.rootPath)
            guard let match = worktrees.first(where: { $0 == raw }) else {
                return invalid("worktree is not a known worktree of this project")
            }
            worktreePath = match
        }

        // Account: must be one of this provider's logins.
        var accountID = settings.defaultAccount(for: provider)?.id
        if let raw = args["account_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), let account = settings.account(id: id) else {
                return invalid("unknown account_id '\(raw)'",
                    .object(["valid_accounts": .array(settings.accounts(for: provider).map { .string($0.id.uuidString) })]))
            }
            guard account.provider == provider else {
                return invalid("account '\(account.name)' belongs to \(account.provider.rawValue), not \(provider.rawValue)")
            }
            accountID = id
        }

        // Launch selection, checked against what the installed CLI offers.
        var warnings: [String] = []
        var launch = AgentLaunchSelection()
        let offered = await launchCapabilities(provider)
        if let model = args["model"]?.stringValue {
            guard Self.isPlainToken(model, limit: 128) else {
                return invalid("'model' must be a single token of at most 128 characters")
            }
            if !offered.models.isEmpty, !offered.models.contains(where: { $0.id == model }) {
                warnings.append("model '\(model)' is not one Uncoil lists for \(provider.rawValue); passed through as given")
            }
            launch.model = model
        }
        if let effort = args["effort"]?.stringValue ?? args["reasoning"]?.stringValue {
            if offered.efforts.isEmpty {
                guard Self.isPlainToken(effort, limit: 32) else {
                    return invalid("'effort' must be a single token")
                }
                warnings.append("\(provider.rawValue) lists no effort levels; '\(effort)' is passed through unverified")
            } else if !offered.efforts.contains(where: { $0.id == effort }) {
                return invalid("effort '\(effort)' is not offered by \(provider.rawValue)",
                    .object(["valid_efforts": .array(offered.efforts.map { .string($0.id) })]))
            }
            launch.effort = effort
        }
        if let raw = args["working_mode"]?.stringValue {
            let modes = AgentWorkingMode.options(for: provider)
            guard let mode = AgentWorkingMode(rawValue: raw), modes.contains(mode) else {
                return invalid("working_mode '\(raw)' is not offered by \(provider.rawValue)",
                    .object(["valid_working_modes": .array(modes.map { .string($0.rawValue) })]))
            }
            launch.workingMode = mode == .providerDefault ? nil : mode
        }

        if let mode = args["mode"]?.stringValue, mode != "fresh" {
            return invalid("mode '\(mode)' is not supported here; resume an existing session with the 'resume' action")
        }

        var initialPrompt = preset?.initialPromptTemplate
        if let raw = args["initial_prompt"]?.stringValue ?? args["prompt"]?.stringValue {
            guard raw.count <= Self.initialPromptLimit else {
                return invalid("initial_prompt exceeds \(Self.initialPromptLimit) characters")
            }
            initialPrompt = Self.sanitizePrompt(raw)
        }

        var title: String?
        if let raw = args["title"]?.stringValue {
            let cleaned = Self.sanitizePrompt(raw).replacingOccurrences(of: "\n", with: " ")
            if !cleaned.isEmpty { title = String(cleaned.prefix(120)) }
        }

        // Grants: never beyond the role and never beyond the caller.
        let roleGrants = preset?.grantedCapabilities
            ?? ProjectStore.defaultSessionCapabilities
            ?? Array(PolicyEngine.defaultGrants)
        let requested = args["capabilities"]?.arrayValue?.compactMap(\.stringValue)
        let capabilities = PolicyEngine.childCapabilities(
            requested: requested, preset: roleGrants, callerGrants: context.grants)

        return .success(SessionCreationSpec(
            provider: provider,
            accountID: accountID,
            projectID: projectID,
            worktreePath: worktreePath,
            launch: launch,
            title: title,
            initialPrompt: initialPrompt,
            capabilities: capabilities,
            extraArguments: preset?.extraArguments ?? [],
            presetID: preset?.id,
            warnings: warnings))
    }

    /// Creates the record and starts it. The new session is the caller's
    /// child: that relationship is what lets the caller control it later
    /// without asking the user.
    func createSession(_ spec: SessionCreationSpec, parent: SessionRecord) -> SessionRecord {
        let presetName = spec.presetID.flatMap { settings?.preset(id: $0)?.name }
        let title = spec.title
            ?? presetName.map { "\(spec.provider.rawValue): \($0)" }
            ?? String(localized: "\(spec.provider.rawValue): new session")
        let record = projectStore.createSession(
            projectID: spec.projectID,
            provider: spec.provider,
            accountID: spec.accountID,
            title: title,
            worktreePath: spec.worktreePath,
            launchSelection: spec.launch)
        projectStore.updateSession(record.id) {
            $0.parentSessionID = parent.id
            $0.capabilities = spec.capabilities
            $0.extraArguments = spec.extraArguments.isEmpty ? nil : spec.extraArguments
        }
        let created = projectStore.sessions.first { $0.id == record.id } ?? record
        childLauncher?(created, spec.initialPrompt)
        return created
    }

    /// No whitespace, no control characters: a value that ends up as one
    /// command-line argument must not be able to become two.
    nonisolated static func isPlainToken(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit && value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

/// An envelope carried through a `Result` failure.
struct ControlEnvelopeError: Error {
    let envelope: ControlEnvelope
    init(_ envelope: ControlEnvelope) { self.envelope = envelope }
}
