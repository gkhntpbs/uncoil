import Foundation

/// A live binding to a specific native window, established by inspect_window /
/// snapshot and required by every mutating computer action. `generation` bumps
/// each time the binding is (re)established so callers can detect rebinds.
struct WindowBinding: Equatable {
    var target: WindowTarget
    var generation: Int
}

extension CapabilityRouter {

    /// Read-only actions require computer.inspect.
    private static let inspectActions: Set<String> =
        ["status", "doctor", "permissions", "list_apps", "list_windows", "inspect_window", "snapshot", "screenshot"]
    /// Mutating actions require computer.background_control.
    private static let backgroundActions: Set<String> =
        ["launch_app", "click", "double_click", "right_click", "type", "press", "hotkey", "scroll"]
    /// Focus-stealing actions require computer.foreground_control.
    private static let foregroundActions: Set<String> = ["bring_to_front"]
    /// Actions that mutate a bound window (need an established, live binding).
    private static let windowMutatingActions: Set<String> =
        ["click", "double_click", "right_click", "type", "press", "hotkey", "scroll", "bring_to_front"]

    func handleComputer(_ request: ControlRequest) async -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let grants = PolicyEngine.grants(for: caller)
        let action = request.action

        // Grant gating by action class.
        if Self.foregroundActions.contains(action) {
            guard grants.contains("computer.foreground_control") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "computer.foreground_control is not granted",
                    details: .object(["remedy": .string("enable foreground computer control for this session in Uncoil")]))
            }
        } else if Self.backgroundActions.contains(action) {
            guard grants.contains("computer.background_control") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "computer.background_control is not granted",
                    details: .object(["remedy": .string("enable background computer control for this session in Uncoil")]))
            }
        } else if Self.inspectActions.contains(action) {
            guard grants.contains("computer.inspect") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "computer.inspect is not granted",
                    details: .object(["remedy": .string("enable computer inspection for this session in Uncoil")]))
            }
        }

        // Availability probe (status still reports even when uninstalled).
        let engine = computerEngine
        let info = await Task.detached { engine.probe() }.value
        if action == "status" {
            let binding = computerBindings[caller.id]
            return .success(request, data: .object([
                "installed": .bool(info.installed),
                "engine": info.asJSON(),
                "has_binding": .bool(binding != nil),
                "binding": binding.map(bindingJSON) ?? .null,
            ]), target_session_id: caller.id.uuidString)
        }
        if !info.installed {
            return .failure(request, code: .computerUnavailable,
                message: "cua-driver is not installed",
                details: .object([
                    "remedy": .string(info.remedy ?? CuaDriverAdapter.installRemedy),
                    "diagnostics": info.asJSON(),
                ]))
        }

        // Window-mutating actions require an established, live binding.
        if Self.windowMutatingActions.contains(action) {
            guard let binding = computerBindings[caller.id] else {
                return .failure(request, code: .staleWindowBinding,
                    message: "no window is bound; call inspect_window or snapshot first",
                    details: .object(["remedy": .string("inspect_window to establish a window binding")]),
                    target_session_id: caller.id.uuidString)
            }
            guard Self.windowIsLive(binding.target) else {
                computerBindings[caller.id] = nil
                return .failure(request, code: .staleWindowBinding,
                    message: "the bound window's process is no longer running",
                    details: .object(["remedy": .string("re-inspect the window to establish a fresh binding")]),
                    target_session_id: caller.id.uuidString)
            }
        }

        switch action {
        case "doctor":
            return await runComputer(.doctor, request: request, caller: caller)
        case "permissions":
            return await runComputer(.permissions, request: request, caller: caller)
        case "list_apps":
            return await runComputer(.listApps, request: request, caller: caller)
        case "launch_app":
            guard let bundleID = request.args["bundle_id"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'bundle_id' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runComputer(.launchApp(bundleID: bundleID), request: request, caller: caller)
        case "list_windows":
            return await runComputer(.listWindows(bundleID: request.args["bundle_id"]?.stringValue),
                                     request: request, caller: caller)

        case "inspect_window", "snapshot":
            return await establishAndRun(request: request, caller: caller, snapshot: action == "snapshot")

        case "click", "double_click", "right_click":
            guard let target = Self.computerActionTarget(request.args) else {
                return .failure(request, code: .invalidArgument,
                                message: "'element_index' or both 'x' and 'y' are required",
                                target_session_id: caller.id.uuidString)
            }
            let w = computerBindings[caller.id]!.target
            let command: ComputerCommand = action == "click" ? .click(window: w, target: target)
                : action == "double_click" ? .doubleClick(window: w, target: target)
                : .rightClick(window: w, target: target)
            return await runComputer(command, request: request, caller: caller)

        case "type":
            guard let text = request.args["text"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'text' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runComputer(.type(
                window: computerBindings[caller.id]!.target,
                text: text,
                target: Self.computerActionTarget(request.args)
            ),
                                     request: request, caller: caller)
        case "press":
            guard let keys = request.args["keys"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'keys' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runComputer(.press(window: computerBindings[caller.id]!.target, keys: keys),
                                     request: request, caller: caller)
        case "hotkey":
            guard let keys = request.args["keys"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'keys' is required",
                                target_session_id: caller.id.uuidString)
            }
            return await runComputer(.hotkey(window: computerBindings[caller.id]!.target, keys: keys),
                                     request: request, caller: caller)
        case "scroll":
            let direction = request.args["direction"]?.stringValue ?? "down"
            return await runComputer(.scroll(window: computerBindings[caller.id]!.target,
                                             direction: direction, amount: request.args["amount"]?.intValue),
                                     request: request, caller: caller)

        case "screenshot":
            let path = artifactFilePath(caller: caller, subdir: "computer/screenshots",
                                        prefix: "screen", ext: "png")
            return await runComputer(.screenshot(window: computerBindings[caller.id]?.target, path: path),
                                     request: request, caller: caller)

        case "bring_to_front":
            let w = computerBindings[caller.id]!.target
            var env = await runComputer(.bringToFront(window: w), request: request, caller: caller)
            if env.ok {
                env.warnings.append("bring_to_front stole window focus for \(w.bundleID); this is an intrusive, audited action")
            }
            return env

        default:
            return .failure(request, code: .invalidAction, message: "unsupported computer action")
        }
    }

    // MARK: - Binding establishment

    private func establishAndRun(request: ControlRequest, caller: SessionRecord, snapshot: Bool) async -> ControlEnvelope {
        // snapshot may reuse an existing binding; inspect_window needs a target.
        let bundleID = request.args["bundle_id"]?.stringValue
        let windowID = request.args["window_id"]?.intValue

        if snapshot, bundleID == nil, let existing = computerBindings[caller.id] {
            guard Self.windowIsLive(existing.target) else {
                computerBindings[caller.id] = nil
                return .failure(request, code: .staleWindowBinding,
                    message: "the bound window is no longer running",
                    details: .object(["remedy": .string("inspect_window to establish a fresh binding")]),
                    target_session_id: caller.id.uuidString)
            }
            return await runComputer(.snapshot(window: existing.target), request: request, caller: caller,
                                     bindingAfter: existing)
        }

        guard let bundleID else {
            return .failure(request, code: .invalidArgument,
                message: "'bundle_id' is required to establish a window binding",
                target_session_id: caller.id.uuidString)
        }
        let command: ComputerCommand = snapshot
            ? .inspectWindow(bundleID: bundleID, windowID: windowID)
            : .inspectWindow(bundleID: bundleID, windowID: windowID)
        let engine = computerEngine
        let outcome = await Task.detached { engine.perform(command, session: caller.id.uuidString) }.value
        switch outcome {
        case .failure(let error):
            return failureEnvelope(request, caller: caller, error: error)
        case .success(let result):
            guard let target = Self.parseWindowTarget(result.externalContent ?? result.data, fallbackBundle: bundleID) else {
                return .failure(request, code: .targetChanged,
                    message: "driver did not return a resolvable window",
                    target_session_id: caller.id.uuidString)
            }
            let generation = (computerBindings[caller.id]?.generation ?? 0) + 1
            let binding = WindowBinding(target: target, generation: generation)
            computerBindings[caller.id] = binding
            if snapshot {
                // Now actually snapshot the bound window.
                return await runComputer(.snapshot(window: target), request: request, caller: caller,
                                         bindingAfter: binding)
            }
            var data: [String: JSONValue] = ["binding": bindingJSON(binding)]
            if let external = result.externalContent { data["external_content"] = TrustBoundary.wrap(external) }
            let artifacts = registerComputerArtifacts(result.artifactFiles, caller: caller)
            return .success(request, data: .object(data),
                            target_session_id: caller.id.uuidString, artifacts: artifacts)
        }
    }

    // MARK: - Engine execution

    private func runComputer(
        _ command: ComputerCommand,
        request: ControlRequest,
        caller: SessionRecord,
        bindingAfter: WindowBinding? = nil
    ) async -> ControlEnvelope {
        let engine = computerEngine
        let outcome = await Task.detached { engine.perform(command, session: caller.id.uuidString) }.value
        switch outcome {
        case .success(let result):
            var data = objectPairs(result.data)
            if let binding = bindingAfter { data["binding"] = bindingJSON(binding) }
            if let external = result.externalContent {
                data["external_content"] = TrustBoundary.wrap(external)
            }
            let artifacts = registerComputerArtifacts(result.artifactFiles, caller: caller)
            return .success(request, data: .object(data),
                            target_session_id: caller.id.uuidString,
                            artifacts: artifacts, warnings: result.warnings)
        case .failure(let error):
            return failureEnvelope(request, caller: caller, error: error)
        }
    }

    private func failureEnvelope(_ request: ControlRequest, caller: SessionRecord, error: EngineError) -> ControlEnvelope {
        var details = error.details
        if let remedy = error.remedy {
            var obj = objectPairs(details ?? .object([:]))
            obj["remedy"] = .string(remedy)
            details = .object(obj)
        }
        return .failure(request, code: error.code, message: error.message,
                        retryable: error.code == .timeout, details: details,
                        target_session_id: caller.id.uuidString)
    }

    // MARK: - Helpers

    /// A window's owning process must still exist. `kill(pid, 0)` probes
    /// liveness without signalling; ESRCH ⇒ gone.
    nonisolated static func windowIsLive(_ target: WindowTarget) -> Bool {
        guard target.pid > 0 else { return false }
        return kill(pid_t(target.pid), 0) == 0 || errno == EPERM
    }

    nonisolated static func parseWindowTarget(_ value: JSONValue, fallbackBundle: String) -> WindowTarget? {
        guard case .object(let obj) = value else { return nil }
        // Accept either a flat window object or {window:{...}}.
        let win: [String: JSONValue]
        if case .object(let nested)? = obj["window"] { win = nested } else { win = obj }
        guard let windowID = win["window_id"]?.intValue ?? win["id"]?.intValue else { return nil }
        let pid = win["pid"]?.intValue ?? 0
        let bundle = win["bundle_id"]?.stringValue ?? fallbackBundle
        let title = win["title"]?.stringValue ?? ""
        return WindowTarget(bundleID: bundle, pid: pid, windowID: windowID, title: title)
    }

    nonisolated static func computerActionTarget(_ args: [String: JSONValue]) -> ComputerActionTarget? {
        if let index = numericArgument(args["element_index"]) {
            return .element(index: index)
        }
        guard let x = numericArgument(args["x"]), let y = numericArgument(args["y"]) else {
            return nil
        }
        return .point(x: x, y: y)
    }

    nonisolated static func numericArgument(_ value: JSONValue?) -> Int? {
        value?.intValue ?? value?.stringValue.flatMap(Int.init)
    }

    func bindingJSON(_ binding: WindowBinding) -> JSONValue {
        .object([
            "bundle_id": .string(binding.target.bundleID),
            "pid": .int(binding.target.pid),
            "window_id": .int(binding.target.windowID),
            "title": .string(binding.target.title),
            "generation": .int(binding.generation),
        ])
    }

    private func registerComputerArtifacts(_ files: [String], caller: SessionRecord) -> [JSONValue] {
        files.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            recordArtifact(name: name, kind: "computer", description: "computer output", caller: caller)
            return .object(["name": .string(name), "path": .string(path), "kind": .string("computer")])
        }
    }
}
