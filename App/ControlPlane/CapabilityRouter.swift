import Foundation

/// Dispatches a decoded `ControlRequest` to the right capability handler.
/// Deliberately socket-free: constructed with plain stores so the whole
/// router + policy + handler stack is unit-testable without any IPC.
@MainActor
final class CapabilityRouter {
    let projectStore: ProjectStore
    let sessionStore: SessionStore
    let settings: SettingsStore?
    let audit: AuditLog
    let dataDirectory: URL
    let appVersion: String

    /// Injected liveness probes (overridable in tests).
    var hookServerRunning: () -> Bool = { false }
    var runtimeReachable: () -> Bool = { RuntimeClient.shared.phase == .ready }

    /// Optional external-driver engines (Milestones 3+4). Default to the real
    /// CLI adapters; tests inject fakes. Marked `var` so they are swappable.
    var browserEngine: BrowserEngine = AgentBrowserAdapter()
    var computerEngine: ComputerEngine = CuaDriverAdapter()

    /// In-memory computer window bindings, keyed by the caller session id.
    /// Established by inspect_window/snapshot; required by mutating actions.
    var computerBindings: [UUID: WindowBinding] = [:]

    /// Directional permission grants/requests (nil in socket-free tests that
    /// don't exercise the permission flow).
    var permissions: PermissionService?

    /// Idempotency map for create_child, keyed "callerID:idempotency_key" →
    /// the child session id already created for that key.
    var childIdempotency: [String: UUID] = [:]

    /// Per-project task metadata, cached so repeated task calls share one
    /// in-memory view of the assignments they mutate.
    var taskMetadataStores: [UUID: ProjectTaskMetadataStore] = [:]
    var taskResultStores: [UUID: TaskResultStore] = [:]

    /// Run/dev-preview process registry. Defaults to the app-wide one so the
    /// MCP surface and the Run UI see the same statuses; tests swap in a fresh
    /// registry with a fake launcher.
    var runRegistry: RunRegistry = .shared

    /// The blueprints an agent can read and, with the grant, write. Defaults to
    /// the app-wide store so a blueprint an agent saves appears in Settings
    /// without a reload; tests point it at a temporary directory.
    var blueprints: BlueprintStore = .shared

    /// Launches a freshly-created child session's terminal (and delivers its
    /// initial prompt). Injected by the app; nil in tests, where the child
    /// record is still created but no PTY is spawned. Also what `resume`
    /// uses: starting an existing record's terminal resumes its conversation.
    var childLauncher: ((_ record: SessionRecord, _ initialPrompt: String?) -> Void)?

    /// Issues and checks the per-session tokens that make a caller's identity
    /// more than a claim. Kept beside the rest of the control plane's data, so
    /// the app's router and the terminal that launches sessions share one
    /// secret, and a test's router never touches the real one.
    var credentials: SessionCredentials

    /// Where structured sessions publish; the timeline and events actions read it.
    var eventHub: AgentEventHub = .shared

    /// The way into a *running* session, or nil when nothing is running. The
    /// control plane never talks to a PTY or a provider directly — only to
    /// what this returns. Tests hand in a fake.
    var sessionControl: (SessionRecord) -> AgentSessionControl? = { record in
        let registry = TerminalRegistry.shared
        guard registry.hasTerminal(for: record.id)
                || RuntimeClient.shared.isAlive(sid: record.id) else { return nil }
        return registry.control(for: record.id, provider: record.provider)
    }

    /// Whether the provider's CLI is on this machine. The app wires the real
    /// probe; the default says yes so socket-free tests do not depend on what
    /// happens to be installed where they run.
    var providerInstalled: (AgentProvider) -> Bool = { _ in true }

    /// What the installed CLI offers for model, effort and working mode.
    var launchCapabilities: (AgentProvider) async -> AgentLaunchCapabilities = { provider in
        AgentLaunchCapabilities(workingModes: AgentWorkingMode.options(for: provider))
    }

    /// The worktree paths of a repository.
    var worktreeLister: (String) -> [String] = { repoPath in
        GitService.worktrees(repoPath: repoPath).map(\.path)
    }

    /// First answers to effects, by idempotency key.
    let idempotency = IdempotencyLedger()

    init(
        projectStore: ProjectStore,
        sessionStore: SessionStore,
        settings: SettingsStore? = nil,
        audit: AuditLog,
        dataDirectory: URL,
        appVersion: String = "0.1.0"
    ) {
        self.projectStore = projectStore
        self.sessionStore = sessionStore
        self.settings = settings
        self.audit = audit
        self.dataDirectory = dataDirectory
        self.appVersion = appVersion
        credentials = dataDirectory.standardizedFileURL == ProjectStore.defaultDirectory().standardizedFileURL
            ? .shared
            : SessionCredentials(directory: dataDirectory)
    }

    /// The language Uncoil composes agent prompts in.
    ///
    /// Only prompts Uncoil *writes* follow this — the protocol surface itself
    /// (tool help, error messages, field names) stays English in every language,
    /// because agents parse it.
    var agentPromptLanguage: PromptLanguage {
        settings?.language.resolvedAgent() ?? .english
    }

    // MARK: - Entry point

    func handle(_ request: ControlRequest) async -> ControlEnvelope {
        let context = callContext(request)
        // Every request is proof the caller's MCP link is alive — that is what
        // the session header's indicator reports. Not a caller that named a
        // session it could not prove it was.
        if context.verification != .mismatched, let id = context.callerSessionID {
            McpStatusStore.shared.recordContact(sessionID: id)
        }
        let envelope = await route(request, context: context)
        audit.record(
            requestID: request.request_id,
            callerSessionID: request.caller_session_id,
            capability: request.capability,
            action: request.action,
            target: envelope.target_session_id,
            decision: envelope.ok ? "allow" : "deny",
            errorCode: envelope.error?.code,
            argKeys: Array(request.args.keys),
            verification: context.verification.rawValue
        )
        return envelope
    }

    /// Who is calling. The one place identity is decided; handlers read it.
    func callContext(_ request: ControlRequest) -> ControlCallContext {
        ControlCallContext.resolve(request, sessions: projectStore.sessions, credentials: credentials)
    }

    private func route(_ request: ControlRequest, context: ControlCallContext) async -> ControlEnvelope {
        guard request.version <= ControlProtocol.version else {
            return .failure(
                request, code: .unsupportedVersion,
                message: "request version \(request.version) is newer than this app's \(ControlProtocol.version); update Uncoil",
                details: .object([
                    "server_version": .int(ControlProtocol.version),
                    "minimum_version": .int(ControlProtocol.minimumVersion),
                ]))
        }
        guard let capabilityDoc = HelpRegistry.capabilities[request.capability] else {
            return .failure(
                request, code: .invalidAction,
                message: "unknown capability '\(request.capability)'",
                details: .object(["valid_capabilities": .array(HelpRegistry.capabilityNames.map(JSONValue.string))]))
        }
        guard capabilityDoc.actionNames.contains(request.action) else {
            return .failure(
                request, code: .invalidAction,
                message: "unknown action '\(request.action)' for \(request.capability)",
                details: .object(["valid_actions": .array(capabilityDoc.actionNames.map(JSONValue.string))]))
        }

        if request.action == "help" {
            return handleHelp(request, capabilityDoc: capabilityDoc)
        }

        if let refused = identityGate(request, context: context, capabilityDoc: capabilityDoc) {
            return refused
        }

        // An effect sent with an idempotency key runs once; a retry gets the
        // first answer. Session creation keeps its own ledger, which answers
        // with the child as it is now rather than as it was.
        if !capabilityDoc.isRead(request.action),
           let key = request.args["idempotency_key"]?.stringValue, !key.isEmpty,
           !["create_child", "create_session"].contains(request.action) {
            return await idempotency.run(
                key: IdempotencyLedger.key(for: request, idempotencyKey: key),
                request: request
            ) { [unowned self] in
                await self.dispatch(request)
            }
        }
        return await dispatch(request)
    }

    /// Refuses a call whose identity cannot carry it, before any handler runs.
    ///
    /// - A token that does not match its id is refused outright: the caller is
    ///   claiming to be someone it is not.
    /// - An effect needs a verified caller. An id with no token may still read
    ///   what any session may read, but it may not act — otherwise any process
    ///   that learned a session id would hold that session's authority.
    private func identityGate(
        _ request: ControlRequest,
        context: ControlCallContext,
        capabilityDoc: HelpRegistry.CapabilityDoc
    ) -> ControlEnvelope? {
        if HelpRegistry.isIdentityFree(capability: request.capability, action: request.action) {
            return nil
        }
        func refuse(_ reason: String, _ message: String) -> ControlEnvelope {
            .failure(request, code: .identityUnverified, message: message,
                     details: .object(["reason": .string(reason)]))
        }
        switch context.verification {
        case .mismatched:
            return refuse("mismatch", "the session token does not belong to the caller session id")
        case .verified:
            return nil
        case .unverified where capabilityDoc.isRead(request.action):
            return nil
        case .unverified:
            return refuse(
                "unverified",
                "this action changes state and the caller session could not be verified; restart the session so Uncoil can issue it a session token")
        case .anonymous where capabilityDoc.isRead(request.action):
            // Left to the handler, which reports the unknown caller in its
            // own terms, as it always has.
            return nil
        case .anonymous:
            // The code every handler has always used for "no such caller".
            return .failure(request, code: .unknownSession,
                            message: "caller session not found: this action needs to know which session is calling",
                            details: .object(["reason": .string("missing")]))
        }
    }

    private func dispatch(_ request: ControlRequest) async -> ControlEnvelope {
        switch request.capability {
        case "uncoil_projects": return handleProjects(request)
        case "uncoil_sessions": return await handleSessions(request)
        case "uncoil_artifacts": return handleArtifacts(request)
        case "uncoil_tasks": return await handleTasks(request)
        case "uncoil_system": return handleSystem(request)
        case "uncoil_browser": return await handleBrowser(request)
        case "uncoil_computer": return await handleComputer(request)
        case "uncoil_run": return await handleRun(request)
        case "uncoil_agents": return await handleAgents(request)
        default:
            return .failure(request, code: .invalidAction, message: "unhandled capability")
        }
    }

    // MARK: - Help

    private func handleHelp(_ request: ControlRequest, capabilityDoc: HelpRegistry.CapabilityDoc) -> ControlEnvelope {
        if let forAction = request.args["for_action"]?.stringValue {
            guard let doc = capabilityDoc.action(forAction) else {
                return .failure(
                    request, code: .invalidAction,
                    message: "unknown action '\(forAction)'",
                    details: .object(["valid_actions": .array(capabilityDoc.actionNames.map(JSONValue.string))]))
            }
            return .success(request, data: .object([
                "action": .string(doc.action),
                "summary": .string(doc.summary),
                "markdown": .string(doc.doc),
            ]))
        }
        let full = ([capabilityDoc.overview] + capabilityDoc.actions.map(\.doc)).joined(separator: "\n\n")
        return .success(request, data: .object([
            "capability": .string(capabilityDoc.capability),
            "overview": .string(capabilityDoc.overview),
            "actions": .array(capabilityDoc.actionNames.map(JSONValue.string)),
            "markdown": .string(full),
        ]))
    }

    // MARK: - Resolution helpers

    func sessionMap() -> [UUID: SessionRecord] {
        Dictionary(uniqueKeysWithValues: projectStore.sessions.map { ($0.id, $0) })
    }

    func caller(of request: ControlRequest) -> SessionRecord? {
        guard let raw = request.caller_session_id, let id = UUID(uuidString: raw) else { return nil }
        return projectStore.sessions.first { $0.id == id }
    }

    func session(id raw: String?) -> SessionRecord? {
        guard let raw, let id = UUID(uuidString: raw) else { return nil }
        return projectStore.sessions.first { $0.id == id }
    }

    func project(id: UUID) -> Project? {
        projectStore.projects.first { $0.id == id }
    }
}
