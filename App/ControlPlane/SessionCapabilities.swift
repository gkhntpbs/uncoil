import Foundation

/// What the control plane can do with one session, stated rather than
/// inferred from its provider.
///
/// Built from the facts that already exist — the running session's
/// `AgentSessionControl.capabilities`, the provider's `AgentDescriptor`, and
/// whether a structured integration has published a timeline — so there is no
/// second table to keep in step. Operation names are part of the MCP contract:
/// a client checks `operations.<name>.supported` instead of a provider name.
struct SessionCapabilityReport: Equatable {
    /// Operation ids, stable across releases. New ones are added; none is
    /// renamed.
    enum Operation: String, CaseIterable {
        case readOutput = "read_output"
        case timeline
        case events
        case submit
        case interrupt
        case respondApproval = "respond_approval"
        case sendRaw = "send_raw"
        case resume
    }

    struct Support: Equatable {
        var supported: Bool
        /// How the operation reaches the agent when it is supported:
        /// `structured` (the provider's own protocol) or `terminal` (keystrokes).
        var via: String?
        /// Why not, when it is not.
        var reason: String?
    }

    let sessionID: UUID
    let provider: AgentProvider
    let running: Bool
    let ready: Bool
    /// `structured`, `terminal`, or `none` when nothing is running.
    let runtime: String
    let controlCapabilities: [String]
    let operations: [Operation: Support]
    let descriptor: AgentDescriptor

    var supported: [String] {
        Operation.allCases.filter { operations[$0]?.supported == true }.map(\.rawValue)
    }

    func supports(_ operation: Operation) -> Bool {
        operations[operation]?.supported == true
    }

    /// Pure: the same facts always give the same report.
    @MainActor
    static func make(
        record: SessionRecord,
        control: AgentSessionControl?,
        hasTimeline: Bool
    ) -> SessionCapabilityReport {
        let descriptor = record.provider.descriptor
        let capabilities = control?.capabilities ?? []
        let running = control != nil
        let structured = capabilities.contains(.structuredTurns)
        let delivery = structured ? "structured" : "terminal"
        let notRunning = Support(supported: false, reason: "session is not running")
        var operations: [Operation: Support] = [:]

        operations[.readOutput] = running
            ? Support(supported: true, via: "terminal")
            : notRunning
        // A timeline outlives the turn that wrote it, so it stays readable
        // after the process has gone for as long as the app keeps it.
        let hasEvents = capabilities.contains(.events) || hasTimeline
        let noEvents = Support(
            supported: false,
            reason: running
                ? "this session publishes no structured events; use read_output"
                : "session is not running and has no timeline")
        operations[.timeline] = hasEvents ? Support(supported: true, via: "structured") : noEvents
        operations[.events] = operations[.timeline]
        operations[.submit] = running ? Support(supported: true, via: delivery) : notRunning
        operations[.interrupt] = running ? Support(supported: true, via: delivery) : notRunning
        operations[.respondApproval] = capabilities.contains(.approvals)
            ? Support(supported: true, via: "structured")
            : Support(
                supported: false,
                reason: running
                    ? "approvals are answered in the agent's own interface"
                    : "session is not running")
        operations[.sendRaw] = capabilities.contains(.rawInput)
            ? Support(supported: true, via: "terminal")
            : Support(
                supported: false,
                reason: running ? "session takes structured input only" : "session is not running")
        if running {
            operations[.resume] = Support(supported: false, reason: "session is already running")
        } else if !descriptor.resumesConversation {
            operations[.resume] = Support(
                supported: false, reason: "\(descriptor.displayName) cannot resume a conversation")
        } else if record.providerSessionID == nil {
            operations[.resume] = Support(
                supported: false, reason: "no conversation was recorded for this session to resume")
        } else {
            operations[.resume] = Support(supported: true, via: delivery)
        }

        return SessionCapabilityReport(
            sessionID: record.id,
            provider: record.provider,
            running: running,
            ready: control?.isReady ?? false,
            runtime: running ? delivery : "none",
            controlCapabilities: capabilities.names,
            operations: operations,
            descriptor: descriptor)
    }

    var asJSON: JSONValue {
        var ops: [String: JSONValue] = [:]
        for operation in Operation.allCases {
            let support = operations[operation] ?? Support(supported: false)
            ops[operation.rawValue] = .object([
                "supported": .bool(support.supported),
                "via": .string(optional: support.via),
                "reason": .string(optional: support.reason),
            ])
        }
        return .object([
            "session_id": .string(sessionID.uuidString),
            "provider": .string(provider.rawValue),
            "running": .bool(running),
            "ready": .bool(ready),
            "runtime": .string(runtime),
            "supported": .array(supported.map(JSONValue.string)),
            "operations": .object(ops),
            "control_capabilities": .array(controlCapabilities.map(JSONValue.string)),
            "provider_facts": .object([
                "status_source": .string(descriptor.statusSource.rawValue),
                "control_plane": .string(descriptor.controlPlane.rawValue),
                "resumes_conversation": .bool(descriptor.resumesConversation),
                "working_modes": .array(descriptor.workingModes.map { .string($0.rawValue) }),
            ]),
        ])
    }
}
