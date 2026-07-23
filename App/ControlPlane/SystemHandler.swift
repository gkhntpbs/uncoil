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

        case "doctor":
            return .success(request, data: .object(["checks": .array(doctorChecks())]))

        case "dependencies":
            return .success(request, data: .object([
                "dependencies": .array([
                    dependencyStatus("agent-browser"),
                    dependencyStatus("cua-driver"),
                ]),
            ]))

        default:
            return .failure(request, code: .invalidAction, message: "unsupported system action")
        }
    }

    private func dependencyStatus(_ name: String) -> JSONValue {
        .object([
            "name": .string(name),
            "status": .string("not_integrated_yet"),
            "detail": .string("integration arrives in a later milestone"),
        ])
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

        return checks
    }
}
