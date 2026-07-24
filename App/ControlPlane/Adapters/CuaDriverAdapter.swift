import Foundation

final class CuaDriverAdapter: ComputerEngine, @unchecked Sendable {
    static let binaryName = "cua-driver"
    static let installRemedy = "open Uncoil Settings → Permissions → Computer Use Setup and install Cua Driver from the official cua.ai guide"

    typealias Run = @Sendable (String, [String], TimeInterval) -> ProcessRunner.Result

    private let resolveBinary: () -> String?
    private let defaultTimeout: TimeInterval
    private let run: Run

    init(
        resolver: @escaping () -> String? = { SettingsStore.which(CuaDriverAdapter.binaryName) },
        defaultTimeout: TimeInterval = 30,
        run: @escaping Run = { executable, arguments, timeout in
            ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
    ) {
        self.resolveBinary = resolver
        self.defaultTimeout = defaultTimeout
        self.run = run
    }

    func probe() -> DependencyInfo {
        guard let path = resolveBinary() else {
            return DependencyInfo(
                name: Self.binaryName,
                installed: false,
                path: nil,
                version: nil,
                detail: "binary not found",
                remedy: Self.installRemedy
            )
        }
        let version = run(path, ["--version"], 8)
        let permissions = run(path, ["permissions", "status"], 8)
        return DependencyInfo(
            name: Self.binaryName,
            installed: true,
            path: path,
            version: successfulText(version),
            detail: permissions.launched ? combinedText(permissions) : permissions.launchError,
            remedy: nil
        )
    }

    func perform(_ command: ComputerCommand, session: String)
        -> Swift.Result<EngineResult, EngineError> {
        guard let binary = resolveBinary() else {
            return .failure(EngineError(
                .computerUnavailable,
                "cua-driver is not installed",
                remedy: Self.installRemedy
            ))
        }

        switch command {
        case .doctor:
            return execute(binary, arguments: ["doctor", "--json"])
        case .permissions:
            return execute(binary, arguments: ["permissions", "status"])
        case .inspectWindow(let bundleID, let windowID):
            return inspectWindow(binary, bundleID: bundleID, windowID: windowID, session: session)
        case .listWindows(let bundleID):
            return listWindows(binary, bundleID: bundleID)
        default:
            let invocation = toolInvocation(for: command, session: session)
            return executeTool(
                binary,
                tool: invocation.tool,
                arguments: invocation.arguments,
                produced: invocation.produced
            )
        }
    }

    private func listWindows(_ binary: String, bundleID: String?)
        -> Swift.Result<EngineResult, EngineError> {
        guard let bundleID else {
            return executeTool(binary, tool: "list_windows", arguments: [:])
        }
        switch runningApp(binary, bundleID: bundleID) {
        case .failure(let error):
            return .failure(error)
        case .success(let app):
            guard let pid = app["pid"]?.intValue, pid > 0 else {
                return .failure(EngineError(.invalidStateTransition, "\(bundleID) is not running"))
            }
            return executeTool(binary, tool: "list_windows", arguments: ["pid": .int(pid)])
        }
    }

    private func inspectWindow(
        _ binary: String,
        bundleID: String,
        windowID: Int?,
        session: String
    ) -> Swift.Result<EngineResult, EngineError> {
        let app: [String: JSONValue]
        switch runningApp(binary, bundleID: bundleID) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            app = value
        }
        guard let pid = app["pid"]?.intValue, pid > 0 else {
            return .failure(EngineError(.invalidStateTransition, "\(bundleID) is not running"))
        }

        let windowsValue: JSONValue
        switch callTool(binary, tool: "list_windows", arguments: ["pid": .int(pid)]) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            windowsValue = value
        }
        guard case .object(let windowsObject) = windowsValue,
              case .array(let windows)? = windowsObject["windows"] else {
            return .failure(EngineError(.targetChanged, "cua-driver returned no windows for \(bundleID)"))
        }
        let windowObjects = windows.compactMap { value -> [String: JSONValue]? in
            guard case .object(let object) = value else { return nil }
            return object
        }
        let selected = windowID.map { id in
            windowObjects.first { $0["window_id"]?.intValue == id }
        } ?? windowObjects.max { preferredWindowScore($0) < preferredWindowScore($1) }
        guard var selected else {
            return .failure(EngineError(
                .staleWindowBinding,
                "window not found for \(bundleID)",
                remedy: "list windows and inspect a live window"
            ))
        }
        selected["bundle_id"] = .string(bundleID)

        var arguments: [String: JSONValue] = [
            "pid": .int(pid),
            "window_id": .int(selected["window_id"]?.intValue ?? 0),
            "include_screenshot": .bool(false),
            "session": .string(session),
        ]
        if let state = try? callTool(binary, tool: "get_window_state", arguments: arguments).get() {
            selected["state"] = state
        }
        arguments.removeAll()
        return .success(EngineResult(
            data: .object(["success": .bool(true)]),
            externalContent: .object(selected)
        ))
    }

    private func runningApp(_ binary: String, bundleID: String)
        -> Swift.Result<[String: JSONValue], EngineError> {
        let value: JSONValue
        switch callTool(binary, tool: "list_apps", arguments: [:]) {
        case .failure(let error):
            return .failure(error)
        case .success(let result):
            value = result
        }
        guard case .object(let object) = value,
              case .array(let apps)? = object["apps"],
              let app = apps.compactMap({ value -> [String: JSONValue]? in
                  guard case .object(let object) = value else { return nil }
                  return object
              }).first(where: { $0["bundle_id"]?.stringValue == bundleID }) else {
            return .failure(EngineError(.invalidStateTransition, "app not found: \(bundleID)"))
        }
        return .success(app)
    }

    private func toolInvocation(
        for command: ComputerCommand,
        session: String
    ) -> (tool: String, arguments: [String: JSONValue], produced: String?) {
        switch command {
        case .listApps:
            return ("list_apps", [:], nil)
        case .launchApp(let bundleID):
            return ("launch_app", ["bundle_id": .string(bundleID)], nil)
        case .snapshot(let window):
            return ("get_window_state", windowArguments(window, session: session), nil)
        case .click(let window, let target):
            return ("click", actionArguments(window, session: session, target: target), nil)
        case .doubleClick(let window, let target):
            var arguments = actionArguments(window, session: session, target: target)
            arguments["count"] = .int(2)
            return ("click", arguments, nil)
        case .rightClick(let window, let target):
            var arguments = actionArguments(window, session: session, target: target)
            arguments["button"] = .string("right")
            return ("click", arguments, nil)
        case .type(let window, let text, let target):
            var arguments = windowArguments(window, session: session)
            arguments["text"] = .string(text)
            if let target {
                apply(target, to: &arguments)
            }
            return ("type_text", arguments, nil)
        case .press(let window, let keys):
            var arguments = windowArguments(window, session: session)
            arguments["key"] = .string(keys)
            return ("press_key", arguments, nil)
        case .hotkey(let window, let keys):
            var arguments = windowArguments(window, session: session)
            arguments["keys"] = .array(keyParts(keys).map(JSONValue.string))
            return ("hotkey", arguments, nil)
        case .scroll(let window, let direction, let amount):
            var arguments = windowArguments(window, session: session)
            arguments["direction"] = .string(direction)
            if let amount { arguments["amount"] = .int(amount) }
            return ("scroll", arguments, nil)
        case .screenshot(let window, let path):
            if let window {
                var arguments = windowArguments(window, session: session)
                arguments["screenshot_out_file"] = .string(path)
                return ("get_window_state", arguments, path)
            }
            return ("get_desktop_state", [
                "screenshot_out_file": .string(path),
                "session": .string(session),
            ], path)
        case .bringToFront(let window):
            return ("bring_to_front", [
                "pid": .int(window.pid),
                "window_id": .int(window.windowID),
            ], nil)
        case .doctor, .permissions, .listWindows, .inspectWindow, .status:
            return ("list_apps", [:], nil)
        }
    }

    private func windowArguments(_ window: WindowTarget, session: String) -> [String: JSONValue] {
        [
            "pid": .int(window.pid),
            "window_id": .int(window.windowID),
            "session": .string(session),
        ]
    }

    private func actionArguments(
        _ window: WindowTarget,
        session: String,
        target: ComputerActionTarget
    ) -> [String: JSONValue] {
        var arguments = windowArguments(window, session: session)
        apply(target, to: &arguments)
        return arguments
    }

    private func apply(
        _ target: ComputerActionTarget,
        to arguments: inout [String: JSONValue]
    ) {
        switch target {
        case .point(let x, let y):
            arguments["x"] = .int(x)
            arguments["y"] = .int(y)
        case .element(let index):
            arguments["element_index"] = .int(index)
        }
    }

    private func keyParts(_ keys: String) -> [String] {
        keys
            .split(whereSeparator: { $0 == "+" || $0 == " " })
            .map { String($0).lowercased() }
    }

    private func preferredWindowScore(_ window: [String: JSONValue]) -> Int {
        let visible: Int
        if case .bool(true)? = window["is_on_screen"] {
            visible = 1
        } else {
            visible = 0
        }
        guard case .object(let bounds)? = window["bounds"] else {
            return visible * 1_000_000_000
        }
        let width = bounds["width"]?.intValue ?? 0
        let height = bounds["height"]?.intValue ?? 0
        return visible * 1_000_000_000 + width * height
    }

    private func executeTool(
        _ binary: String,
        tool: String,
        arguments: [String: JSONValue],
        produced: String? = nil
    ) -> Swift.Result<EngineResult, EngineError> {
        switch callTool(binary, tool: tool, arguments: arguments) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            var files: [String] = []
            if let produced, FileManager.default.fileExists(atPath: produced) {
                files.append(produced)
            }
            return .success(EngineResult(
                data: .object(["success": .bool(true)]),
                externalContent: value,
                artifactFiles: files
            ))
        }
    }

    private func callTool(
        _ binary: String,
        tool: String,
        arguments: [String: JSONValue]
    ) -> Swift.Result<JSONValue, EngineError> {
        guard let argumentData = try? JSONEncoder().encode(JSONValue.object(arguments)),
              let argumentText = String(data: argumentData, encoding: .utf8) else {
            return .failure(EngineError(.invalidArgument, "could not encode cua-driver arguments"))
        }

        var result = run(binary, ["call", tool, argumentText], defaultTimeout)
        if isDaemonUnavailable(result) {
            let started = startDaemon(binary)
            if case .failure(let error) = started { return .failure(error) }
            result = run(binary, ["call", tool, argumentText], defaultTimeout)
        }
        if result.timedOut {
            return .failure(EngineError(.timeout, "cua-driver timed out"))
        }
        if !result.launched {
            return .failure(EngineError(
                .computerUnavailable,
                result.launchError ?? "cua-driver failed to launch",
                remedy: Self.installRemedy
            ))
        }
        guard result.exitCode == 0 else {
            return .failure(classify(combinedText(result)))
        }
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = jsonValue(text) else {
            return .failure(EngineError(.invalidStateTransition, "cua-driver returned invalid JSON"))
        }
        return .success(value)
    }

    private func startDaemon(_ binary: String) -> Swift.Result<Void, EngineError> {
        let launched = run(
            "/usr/bin/open",
            ["-n", "-g", "-a", "CuaDriver", "--args", "serve"],
            10
        )
        guard launched.launched, launched.exitCode == 0 else {
            return .failure(EngineError(
                .computerUnavailable,
                combinedText(launched),
                remedy: "start Cua Driver from Uncoil Settings → Permissions"
            ))
        }
        for _ in 0..<20 {
            usleep(100_000)
            let status = run(binary, ["permissions", "status"], 3)
            if status.exitCode == 0 && !isDaemonUnavailable(status) {
                return .success(())
            }
        }
        return .failure(EngineError(
            .computerUnavailable,
            "Cua Driver daemon did not become ready",
            remedy: "open Uncoil Settings → Permissions → Computer Use Setup"
        ))
    }

    private func execute(
        _ binary: String,
        arguments: [String]
    ) -> Swift.Result<EngineResult, EngineError> {
        let result = run(binary, arguments, defaultTimeout)
        if result.timedOut {
            return .failure(EngineError(.timeout, "cua-driver timed out"))
        }
        if !result.launched {
            return .failure(EngineError(
                .computerUnavailable,
                result.launchError ?? "cua-driver failed to launch",
                remedy: Self.installRemedy
            ))
        }
        guard result.exitCode == 0 else {
            return .failure(classify(combinedText(result)))
        }
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(EngineResult(
            data: .object(["success": .bool(true)]),
            externalContent: jsonValue(text) ?? .string(text)
        ))
    }

    private func successfulText(_ result: ProcessRunner.Result) -> String? {
        guard result.launched, result.exitCode == 0 else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func combinedText(_ result: ProcessRunner.Result) -> String {
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return [stdout, stderr, result.launchError]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func isDaemonUnavailable(_ result: ProcessRunner.Result) -> Bool {
        combinedText(result).lowercased().contains("daemon is not running")
    }

    private func classify(_ message: String) -> EngineError {
        let lower = message.lowercased()
        if lower.contains("permission")
            || lower.contains("accessibility")
            || lower.contains("not authorized") {
            return EngineError(
                .permissionDenied,
                message,
                remedy: "open Uncoil Settings → Permissions → Computer Use Setup and grant Accessibility + Screen Recording"
            )
        }
        if lower.contains("daemon is not running") || lower.contains("socket") {
            return EngineError(
                .computerUnavailable,
                message,
                remedy: "start Cua Driver from Uncoil Settings → Permissions"
            )
        }
        if lower.contains("no such window")
            || lower.contains("window not found")
            || lower.contains("stale") {
            return EngineError(
                .staleWindowBinding,
                message,
                remedy: "re-inspect the window to establish a fresh binding"
            )
        }
        if lower.contains("timeout") {
            return EngineError(.timeout, message)
        }
        return EngineError(.invalidStateTransition, message)
    }

    private func jsonValue(_ text: String) -> JSONValue? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
