import Foundation

extension CapabilityRouter {
    func handleSystem(_ request: ControlRequest) -> ControlEnvelope {
        switch request.action {
        case "status":
            let caller = caller(of: request)
            return .success(request, data: .object([
                "ok": .bool(true),
                "protocol_version": .int(ControlProtocol.version),
                "caller_session_id": .string(optional: request.caller_session_id),
                "project_id": .string(optional: caller?.projectID.uuidString),
            ]), project_id: caller?.projectID.uuidString)

        case "version":
            return .success(request, data: .object([
                "app_version": .string(appVersion),
                "protocol_version": .int(ControlProtocol.version),
            ]))

        case "capabilities":
            let grants = grants(for: request).sorted()
            return .success(request, data: .object([
                "capabilities": .array(grants.map(JSONValue.string)),
            ]))

        case "request_permission":
            guard let grantKey = request.args["grant_key"]?.stringValue, !grantKey.isEmpty else {
                return .failure(request, code: .invalidArgument, message: "'grant_key' is required")
            }
            let target = request.args["target_session_id"]?.stringValue
            guard let permissions else {
                return .failure(request, code: .controlPlaneUnavailable,
                    message: "permission service unavailable")
            }
            let from = request.caller_session_id ?? "unknown"
            let record = permissions.request(grantKey: grantKey, from: from, target: target)
            return .success(request, data: .object([
                "request_id": .string(record.id),
                "grant_key": .string(record.grantKey),
                "target": .string(optional: record.targetSessionID),
                "status": .string(record.status.rawValue),
            ]), target_session_id: target)

        case "doctor":
            return .success(request, data: .object(["checks": .array(doctorChecks())]))

        case "dependencies":
            let browser = browserEngine.probe()
            let computer = computerEngine.probe()
            return .success(request, data: .object([
                "dependencies": .array([
                    dependencyStatus(browser),
                    dependencyStatus(computer),
                ]),
            ]))

        default:
            return .failure(request, code: .invalidAction, message: "unsupported system action")
        }
    }

    private func dependencyStatus(_ info: DependencyInfo) -> JSONValue {
        var obj = info.asJSON()
        if case .object(var dict) = obj {
            dict["status"] = .string(info.installed ? "installed" : "not_installed")
            obj = .object(dict)
        }
        return obj
    }

    private func check(_ name: String, ok: Bool, detail: String, remedy: String?) -> JSONValue {
        .object([
            "name": .string(name),
            "ok": .bool(ok),
            "detail": .string(detail),
            "remedy": .string(optional: remedy),
        ])
    }

    private func doctorChecks() -> [JSONValue] {
        let fm = FileManager.default
        var checks: [JSONValue] = []

        let socketPath = dataDirectory.appendingPathComponent(ControlProtocol.socketName).path
        let socketOK = fm.fileExists(atPath: socketPath)
        checks.append(check("control_socket", ok: socketOK,
            detail: socketOK ? "listening at \(socketPath)" : "socket file missing",
            remedy: socketOK ? nil : "restart Uncoil to recreate the control socket"))

        let runtimeOK = runtimeReachable()
        checks.append(check("runtime_daemon", ok: runtimeOK,
            detail: runtimeOK ? "uncoil-runtimed reachable" : "daemon not ready",
            remedy: runtimeOK ? nil : "open a terminal session to spawn uncoil-runtimed"))

        let gitOK = fm.isExecutableFile(atPath: "/usr/bin/git")
        checks.append(check("git", ok: gitOK,
            detail: gitOK ? "/usr/bin/git present" : "git not found",
            remedy: gitOK ? nil : "install the Xcode command line tools"))

        let dirOK = fm.isWritableFile(atPath: dataDirectory.path)
        checks.append(check("data_dir", ok: dirOK,
            detail: dirOK ? "writable: \(dataDirectory.path)" : "data dir not writable",
            remedy: dirOK ? nil : "check Application Support permissions"))

        let hookOK = hookServerRunning()
        checks.append(check("hook_server", ok: hookOK,
            detail: hookOK ? "hook socket server running" : "hook server not running",
            remedy: hookOK ? nil : "hooks are optional; install them from Settings → Hooks"))

        // Optional external drivers (Milestones 3+4). These are diagnostics —
        // absence is not a failure of Uncoil itself, so `remedy` is the install
        // hint rather than a hard error.
        let browser = browserEngine.probe()
        checks.append(check("agent_browser", ok: browser.installed,
            detail: browser.installed
                ? "installed at \(browser.path ?? "?")\(browser.version.map { " (v\($0))" } ?? "")"
                : "not installed",
            remedy: browser.installed ? nil : (browser.remedy ?? "npm install -g agent-browser")))

        let computer = computerEngine.probe()
        var computerDetail = computer.installed
            ? "installed at \(computer.path ?? "?")\(computer.version.map { " (v\($0))" } ?? "")"
            : "not installed"
        if let extra = computer.detail { computerDetail += " — \(extra)" }
        checks.append(check("cua_driver", ok: computer.installed, detail: computerDetail,
            remedy: computer.installed ? nil : (computer.remedy ?? "install cua-driver from cua.ai")))

        return checks
    }
}
