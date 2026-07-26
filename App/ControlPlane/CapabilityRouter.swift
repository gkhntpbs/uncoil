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

    /// Launches a freshly-created child session's terminal (and delivers its
    /// initial prompt). Injected by the app; nil in tests, where the child
    /// record is still created but no PTY is spawned.
    var childLauncher: ((_ record: SessionRecord, _ initialPrompt: String?) -> Void)?

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
        // Every request is proof the caller's MCP link is alive — that is what
        // the session header's indicator reports.
        if let caller = request.caller_session_id, let id = UUID(uuidString: caller) {
            await MainActor.run { McpStatusStore.shared.recordContact(sessionID: id) }
        }
        let envelope = await route(request)
        audit.record(
            requestID: request.request_id,
            callerSessionID: request.caller_session_id,
            capability: request.capability,
            action: request.action,
            target: envelope.target_session_id,
            decision: envelope.ok ? "allow" : "deny",
            errorCode: envelope.error?.code,
            argKeys: Array(request.args.keys)
        )
        return envelope
    }

    private func route(_ request: ControlRequest) async -> ControlEnvelope {
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

        switch request.capability {
        case "uncoil_projects": return handleProjects(request)
        case "uncoil_sessions": return await handleSessions(request)
        case "uncoil_artifacts": return handleArtifacts(request)
        case "uncoil_tasks": return await handleTasks(request)
        case "uncoil_system": return handleSystem(request)
        case "uncoil_browser": return await handleBrowser(request)
        case "uncoil_computer": return await handleComputer(request)
        case "uncoil_run": return await handleRun(request)
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
