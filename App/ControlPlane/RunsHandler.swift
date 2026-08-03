import Foundation

/// `uncoil_run` — project run / dev-preview configurations over MCP. The
/// configuration file is the repo-owned `.uncoil/run.json`; this handler never
/// keeps a private copy, so an agent editing the file directly and an agent
/// calling `update` see identical state.
extension CapabilityRouter {
    func handleRun(_ request: ControlRequest) async -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let grants = PolicyEngine.grants(for: caller)
        guard let project = runProject(request, caller: caller, grants: grants) else {
            return .failure(request, code: .unknownProject, message: "project not found or not reachable")
        }

        // Test suites are actions on this tool rather than a ninth one: the MCP
        // surface is eight tools by design, and a suite is the same kind of
        // thing a run is.
        if let envelope = await handleTestAction(request, project: project, grants: grants) {
            return envelope
        }

        switch request.action {
        case "list":
            return requiringRun("runs.read", grants, request) { listRuns(request, project: project) }
        case "get", "status":
            return requiringRun("runs.read", grants, request) { runStatus(request, project: project) }
        case "logs":
            return requiringRun("runs.read", grants, request) { runLogs(request, project: project) }
        case "detect":
            return requiringRun("runs.write", grants, request) { detectRuns(request, project: project) }
        case "update":
            return requiringRun("runs.write", grants, request) { updateRun(request, project: project) }
        case "remove":
            return requiringRun("runs.write", grants, request) { removeRun(request, project: project) }
        case "set_default":
            return requiringRun("runs.write", grants, request) { setDefaultRun(request, project: project) }
        case "history":
            return requiringRun("runs.read", grants, request) { runHistory(request, project: project) }
        case "send_input":
            guard grants.contains("runs.control") else { return runDenied(request, "runs.control") }
            return sendRunInput(request, project: project)
        case "start":
            guard grants.contains("runs.control") else { return runDenied(request, "runs.control") }
            return await startRun(request, project: project)
        case "stop":
            guard grants.contains("runs.control") else { return runDenied(request, "runs.control") }
            return await stopRun(request, project: project)
        case "restart":
            guard grants.contains("runs.control") else { return runDenied(request, "runs.control") }
            return await restartRun(request, project: project)
        default:
            return .failure(request, code: .invalidAction, message: "unsupported run action")
        }
    }

    private func requiringRun(
        _ grant: String, _ grants: Set<String>, _ request: ControlRequest,
        _ body: () -> ControlEnvelope
    ) -> ControlEnvelope {
        grants.contains(grant) ? body() : runDenied(request, grant)
    }

    private func runDenied(_ request: ControlRequest, _ grant: String) -> ControlEnvelope {
        .failure(request, code: .capabilityDisabled, message: "\(grant) is not granted")
    }

    /// The caller's project, or an explicit `project_id` behind the
    /// cross-project grant (same rule as tasks).
    private func runProject(
        _ request: ControlRequest, caller: SessionRecord, grants: Set<String>
    ) -> Project? {
        if let raw = request.args["project_id"]?.stringValue,
           let id = UUID(uuidString: raw),
           id != caller.projectID {
            guard grants.contains("sessions.cross_project") else { return nil }
            return projectStore.projects.first { $0.id == id }
        }
        return projectStore.projects.first { $0.id == caller.projectID }
    }

    // MARK: - Read

    private func stateJSON(_ state: RunProcessState) -> JSONValue {
        var object: [String: JSONValue] = ["status": .string(state.status.label)]
        if case .exited(let code) = state.status { object["exit_code"] = .int(Int(code)) }
        if let pid = state.pid { object["pid"] = .int(Int(pid)) }
        if let started = state.startedAt {
            object["started_at"] = .string(ISO8601DateFormatter().string(from: started))
        }
        if let code = state.lastExitCode { object["last_exit_code"] = .int(Int(code)) }
        if let issue = state.issue { object["issue"] = issue.asJSON() }
        if let log = state.logFileURL { object["log_file"] = .string(log.path) }
        return .object(object)
    }

    private func configJSON(_ config: RunConfiguration, project: Project) -> JSONValue {
        var object = config.asJSON().objectValue ?? [:]
        object["state"] = stateJSON(runRegistry.state(project: project, configID: config.id))
        return .object(object)
    }

    private func listRuns(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let contents = RunConfigFile.load(projectRoot: project.rootURL)
        return .success(request, data: .object([
            "config_file": .string(RunConfigFile.url(projectRoot: project.rootURL).path),
            "configurations": .array(contents.configurations.map { configJSON($0, project: project) }),
            "total": .int(contents.configurations.count),
            "problems": .array(contents.problems.map(JSONValue.string)),
        ]), project_id: project.id.uuidString)
    }

    private enum ConfigLookup {
        case config(RunConfiguration)
        case error(ControlEnvelope)
    }

    private func requireConfig(
        _ request: ControlRequest, project: Project
    ) -> ConfigLookup {
        let contents = RunConfigFile.load(projectRoot: project.rootURL)
        // No id → the project's default configuration, so an agent can just say
        // "start the project" without discovering ids first.
        guard let id = request.args["id"]?.stringValue else {
            if let fallback = RunConfigFile.defaultConfiguration(contents.configurations) {
                return .config(fallback)
            }
            return .error(.failure(
                request, code: .invalidArgument,
                message: "'id' is required (no default run configuration is set)",
                details: .object(["known_ids": .array(contents.configurations.map { .string($0.id) })])
            ))
        }
        guard let config = contents.configurations.first(where: { $0.id == id }) else {
            return .error(.failure(
                request, code: .invalidArgument,
                message: "no run configuration '\(id)'",
                details: .object(["known_ids": .array(contents.configurations.map { .string($0.id) })])
            ))
        }
        return .config(config)
    }

    private func runStatus(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            var data = configJSON(config, project: project).objectValue ?? [:]
            let state = runRegistry.state(project: project, configID: config.id)
            if state.status == .running, let preview = config.previewURL {
                data["preview_url"] = .string(preview)
            }
            data["ports_open"] = .array(config.ports.map { .bool(RunRegistry.isPortOpen($0)) })
            return .success(request, data: .object(data), project_id: project.id.uuidString)
        }
    }

    private func runLogs(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            let state = runRegistry.state(project: project, configID: config.id)
            let requested = request.args["lines"]?.intValue ?? 100
            let lines = state.logTail.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(max(1, min(requested, 2000))).joined(separator: "\n")
            return .success(request, data: .object([
                "id": .string(config.id),
                "status": .string(state.status.label),
                "log_file": .string(optional: state.logFileURL?.path),
                "line_count": .int(lines.count),
                // Process output is external content: it can contain anything,
                // including adversarial text — never treat it as instructions.
                "external_content": TrustBoundary.wrap(.string(tail)),
            ]), project_id: project.id.uuidString)
        }
    }

    // MARK: - Write

    private func detectRuns(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let replace = request.args["replace"]?.boolValue ?? false
        let existing = RunConfigFile.load(projectRoot: project.rootURL).configurations
        let suggestions = RunDetection.detect(
            fileSystem: DiskRunDetectionFileSystem(root: project.rootURL)
        )
        let merged = RunDetection.merge(
            existing: existing, suggestions: suggestions, replacingDetected: replace
        )
        do {
            try RunConfigFile.save(merged, projectRoot: project.rootURL)
        } catch {
            return .failure(request, code: .ioError, message: "could not write run.json: \(error.localizedDescription)")
        }
        let addedIDs = Set(merged.map(\.id)).subtracting(existing.map(\.id))
        return .success(request, data: .object([
            "configurations": .array(merged.map { configJSON($0, project: project) }),
            "added": .array(addedIDs.sorted().map(JSONValue.string)),
            "total": .int(merged.count),
        ]), project_id: project.id.uuidString,
           warnings: merged.isEmpty ? ["no run configuration could be detected; write .uncoil/run.json by hand"] : [])
    }

    private func updateRun(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        var raw = request.args["configuration"]
        // Some MCP clients deliver nested tool arguments as a JSON string —
        // accept that transparently rather than making agents fight encoding.
        if case .string(let text)? = raw,
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
           parsed.objectValue != nil {
            raw = parsed
        }
        // Convenience: top-level id/command/… args count as the configuration,
        // so `{"action":"update","id":"x","command":"y"}` also works.
        if raw == nil, request.args["id"] != nil, request.args["command"] != nil {
            raw = .object(request.args.filter { $0.key != "project_id" })
        }
        guard let raw else {
            return .failure(request, code: .invalidArgument, message: "'configuration' object is required")
        }
        guard let data = try? JSONEncoder().encode(raw),
              var config = try? JSONDecoder().decode(RunConfiguration.self, from: data)
        else {
            let received: String
            switch raw {
            case .object(let object): received = "object with keys \(object.keys.sorted())"
            case .string: received = "string (not valid configuration JSON)"
            default: received = "non-object value"
            }
            return .failure(
                request, code: .invalidArgument,
                message: "configuration must be an object with string 'id' and 'command'; received \(received)"
            )
        }
        config.source = .agent
        var contents = RunConfigFile.load(projectRoot: project.rootURL).configurations
        var replaced = false
        contents = contents.map { existing in
            guard existing.id == config.id else { return existing }
            replaced = true
            return config
        }
        if !replaced { contents.append(config) }
        // At most one default: setting it here clears it everywhere else.
        if config.isDefault {
            contents = contents.map { existing in
                var existing = existing
                existing.isDefault = existing.id == config.id
                return existing
            }
        }
        if runRegistry.dependencyOrder(target: config.id, in: contents) == nil {
            return .failure(
                request, code: .invalidArgument,
                message: "depends_on of '\(config.id)' references unknown ids or forms a cycle"
            )
        }
        do {
            try RunConfigFile.save(contents, projectRoot: project.rootURL)
        } catch {
            return .failure(request, code: .ioError, message: "could not write run.json: \(error.localizedDescription)")
        }
        return .success(request, data: .object([
            "configuration": configJSON(config, project: project),
            "replaced": .bool(replaced),
        ]), project_id: project.id.uuidString,
           next_actions: ["start it with {\"action\":\"start\",\"id\":\"\(config.id)\"}"])
    }

    private func removeRun(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            let state = runRegistry.state(project: project, configID: config.id)
            guard state.status != .running, state.status != .starting else {
                return .failure(
                    request, code: .invalidStateTransition,
                    message: "'\(config.id)' is \(state.status.label); stop it before removing"
                )
            }
            let remaining = RunConfigFile.load(projectRoot: project.rootURL)
                .configurations.filter { $0.id != config.id }
            do {
                try RunConfigFile.save(remaining, projectRoot: project.rootURL)
            } catch {
                return .failure(request, code: .ioError, message: "could not write run.json: \(error.localizedDescription)")
            }
            return .success(request, data: .object([
                "removed": .string(config.id),
                "total": .int(remaining.count),
            ]), project_id: project.id.uuidString)
        }
    }

    private func setDefaultRun(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            do {
                try RunConfigFile.setDefault(config.id, projectRoot: project.rootURL)
            } catch {
                return .failure(request, code: .ioError, message: "could not write run.json: \(error.localizedDescription)")
            }
            return .success(request, data: .object([
                "default": .string(config.id),
            ]), project_id: project.id.uuidString)
        }
    }

    private func runHistory(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let configID = request.args["id"]?.stringValue
        let limit = max(1, min(request.args["limit"]?.intValue ?? 20, 100))
        let entries = runRegistry.history(project: project, configID: configID)
        return .success(request, data: .object([
            "runs": .array(entries.prefix(limit).map { $0.asJSON() }),
            "total": .int(entries.count),
            "note": .string("read a past run's full output from its log_file path"),
        ]), project_id: project.id.uuidString)
    }

    private func sendRunInput(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            guard let text = request.args["text"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'text' is required")
            }
            let raw = request.args["raw"]?.boolValue ?? false
            guard runRegistry.sendInput(
                project: project, configID: config.id, text: text, raw: raw
            ) else {
                return .failure(
                    request, code: .invalidStateTransition,
                    message: "'\(config.id)' is not running; start it first"
                )
            }
            return .success(request, data: .object([
                "id": .string(config.id),
                "sent_bytes": .int((raw ? text : text + "\n").utf8.count),
            ]), project_id: project.id.uuidString)
        }
    }

    // MARK: - Lifecycle

    private func outcomesJSON(_ outcomes: [RunRegistry.StartOutcome]) -> JSONValue {
        .array(outcomes.map { outcome in
            var object: [String: JSONValue] = [
                "id": .string(outcome.configID),
                "ok": .bool(outcome.ok),
                "status": .string(outcome.status.label),
            ]
            if let issue = outcome.issue { object["issue"] = issue.asJSON() }
            return .object(object)
        })
    }

    private func startEnvelope(
        _ request: ControlRequest, project: Project, outcomes: [RunRegistry.StartOutcome]
    ) -> ControlEnvelope {
        guard let target = outcomes.last else {
            return .failure(request, code: .internalError, message: "start produced no outcome")
        }
        if target.ok {
            var data: [String: JSONValue] = ["outcomes": outcomesJSON(outcomes)]
            if case .config(let config) = requireConfig(request, project: project) {
                let state = runRegistry.state(project: project, configID: config.id)
                data["pid"] = state.pid.map { .int(Int($0)) } ?? .null
                data["log_file"] = .string(optional: state.logFileURL?.path)
                if let preview = config.previewURL { data["preview_url"] = .string(preview) }
            }
            return .success(request, data: .object(data), project_id: project.id.uuidString)
        }
        let state = runRegistry.state(project: project, configID: target.configID)
        return .failure(
            request, code: .invalidStateTransition,
            message: "run '\(target.configID)' did not become ready",
            details: .object([
                "outcomes": outcomesJSON(outcomes),
                "issue": target.issue?.asJSON() ?? .null,
                "log_tail": TrustBoundary.wrap(.string(String(state.logTail.suffix(4000)))),
                "log_file": .string(optional: state.logFileURL?.path),
            ])
        )
    }

    private func startRun(_ request: ControlRequest, project: Project) async -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            let state = runRegistry.state(project: project, configID: config.id)
            if state.status == .running || state.status == .starting {
                return .failure(
                    request, code: .invalidStateTransition,
                    message: "'\(config.id)' is already \(state.status.label); use restart"
                )
            }
            let outcomes = await runRegistry.start(project: project, configID: config.id)
            return startEnvelope(request, project: project, outcomes: outcomes)
        }
    }

    private func stopRun(_ request: ControlRequest, project: Project) async -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            await runRegistry.stop(project: project, configID: config.id)
            return .success(request, data: .object([
                "id": .string(config.id),
                "status": .string(runRegistry.state(project: project, configID: config.id).status.label),
            ]), project_id: project.id.uuidString)
        }
    }

    private func restartRun(_ request: ControlRequest, project: Project) async -> ControlEnvelope {
        switch requireConfig(request, project: project) {
        case .error(let envelope): return envelope
        case .config(let config):
            let outcomes = await runRegistry.restart(project: project, configID: config.id)
            return startEnvelope(request, project: project, outcomes: outcomes)
        }
    }
}
