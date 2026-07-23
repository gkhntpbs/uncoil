import Foundation

/// `ComputerEngine` backed by the `cua-driver` CLI (cua.ai).
///
/// cua-driver is NOT assumed installed; when absent every call degrades to a
/// typed COMPUTER_UNAVAILABLE with an install remedy. The command table below
/// is written defensively against a documented surface — verify with
/// `cua-driver --help` when the binary is present. Assumed contract (mirrors
/// agent-browser): `--json` machine output emitting
/// `{"success":bool,"data":<any>,"error":<string|null>}`.
///
/// Documented subcommands used:
///   doctor · permissions status · app list · app launch <bundle> ·
///   window list [<bundle>] · window inspect <bundle> [<window>] ·
///   snapshot --window <id> · click/dblclick/rightclick --window <id> --x <n> --y <n> ·
///   type --window <id> <text> · key --window <id> <keys> · hotkey --window <id> <keys> ·
///   scroll --window <id> --dir <d> [--amount <n>] · screenshot [--window <id>] <path> ·
///   front --window <id>
///
/// All verbs are fixed literals; only value args come from the caller; nothing
/// is passed through a shell.
final class CuaDriverAdapter: ComputerEngine, @unchecked Sendable {
    static let binaryName = "cua-driver"
    static let installRemedy = "install cua-driver from cua.ai (e.g. `pip install cua-driver` or the vendor installer), then grant Accessibility + Screen Recording permissions"

    private let resolveBinary: () -> String?
    private let defaultTimeout: TimeInterval

    init(resolver: @escaping () -> String? = { SettingsStore.which(CuaDriverAdapter.binaryName) },
         defaultTimeout: TimeInterval = 30) {
        self.resolveBinary = resolver
        self.defaultTimeout = defaultTimeout
    }

    func probe() -> DependencyInfo {
        guard let path = resolveBinary() else {
            return DependencyInfo(name: Self.binaryName, installed: false, path: nil,
                                  version: nil, detail: "binary not found on PATH",
                                  remedy: Self.installRemedy)
        }
        // Best-effort version + permissions detail.
        let version = ProcessRunner.run(executable: path, arguments: ["--version"], timeout: 8)
        let ver = version.launched && version.exitCode == 0
            ? version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let perms = ProcessRunner.run(executable: path, arguments: ["--json", "permissions", "status"], timeout: 8)
        let permDetail = perms.launched ? perms.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return DependencyInfo(name: Self.binaryName, installed: true, path: path,
                              version: ver,
                              detail: permDetail.map { "permissions: \($0)" },
                              remedy: nil)
    }

    func perform(_ command: ComputerCommand, session: String)
        -> Swift.Result<EngineResult, EngineError> {
        guard let binary = resolveBinary() else {
            return .failure(EngineError(.computerUnavailable,
                "cua-driver is not installed", remedy: Self.installRemedy))
        }
        let (verb, produced) = argv(for: command)
        let result = ProcessRunner.run(executable: binary, arguments: ["--json"] + verb,
                                       timeout: defaultTimeout)
        if result.timedOut {
            return .failure(EngineError(.timeout, "cua-driver timed out"))
        }
        if !result.launched {
            return .failure(EngineError(.computerUnavailable,
                result.launchError ?? "cua-driver failed to launch", remedy: Self.installRemedy))
        }
        return parse(result, produced: produced)
    }

    // MARK: - Command → argv

    private func argv(for command: ComputerCommand) -> ([String], String?) {
        switch command {
        case .doctor: return (["doctor"], nil)
        case .permissions: return (["permissions", "status"], nil)
        case .listApps: return (["app", "list"], nil)
        case .launchApp(let bundleID): return (["app", "launch", bundleID], nil)
        case .listWindows(let bundleID):
            return (bundleID == nil ? ["window", "list"] : ["window", "list", bundleID!], nil)
        case .inspectWindow(let bundleID, let windowID):
            var v = ["window", "inspect", bundleID]
            if let windowID { v.append(String(windowID)) }
            return (v, nil)
        case .snapshot(let w):
            return (["snapshot", "--window", String(w.windowID)], nil)
        case .click(let w, let x, let y):
            return (["click", "--window", String(w.windowID), "--x", String(x), "--y", String(y)], nil)
        case .doubleClick(let w, let x, let y):
            return (["dblclick", "--window", String(w.windowID), "--x", String(x), "--y", String(y)], nil)
        case .rightClick(let w, let x, let y):
            return (["rightclick", "--window", String(w.windowID), "--x", String(x), "--y", String(y)], nil)
        case .type(let w, let text):
            return (["type", "--window", String(w.windowID), text], nil)
        case .press(let w, let keys):
            return (["key", "--window", String(w.windowID), keys], nil)
        case .hotkey(let w, let keys):
            return (["hotkey", "--window", String(w.windowID), keys], nil)
        case .scroll(let w, let direction, let amount):
            var v = ["scroll", "--window", String(w.windowID), "--dir", direction]
            if let amount { v.append(contentsOf: ["--amount", String(amount)]) }
            return (v, nil)
        case .screenshot(let w, let path):
            var v = ["screenshot"]
            if let w { v.append(contentsOf: ["--window", String(w.windowID)]) }
            v.append(path)
            return (v, path)
        case .bringToFront(let w):
            return (["front", "--window", String(w.windowID)], nil)
        case .status:
            return (["doctor"], nil)
        }
    }

    private func parse(_ result: ProcessRunner.Result, produced: String?)
        -> Swift.Result<EngineResult, EngineError> {
        let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let obj = jsonObject(text)
        let success = obj?["success"]?.boolValue ?? (result.exitCode == 0)
        if !success {
            let message = obj?["error"]?.stringValue
                ?? (result.stderrString.isEmpty ? text : result.stderrString)
            return .failure(classify(message))
        }
        let dataValue = obj?["data"] ?? .string(text)
        var files: [String] = []
        if let produced, FileManager.default.fileExists(atPath: produced) { files.append(produced) }
        return .success(EngineResult(
            data: .object(["success": .bool(true)]),
            externalContent: dataValue,
            artifactFiles: files))
    }

    private func classify(_ message: String) -> EngineError {
        let lower = message.lowercased()
        if lower.contains("permission") || lower.contains("accessibility") || lower.contains("not authorized") {
            return EngineError(.permissionDenied, message,
                remedy: "grant Accessibility and Screen Recording to cua-driver in System Settings → Privacy")
        }
        if lower.contains("no such window") || lower.contains("window not found") || lower.contains("stale") {
            return EngineError(.staleWindowBinding, message,
                remedy: "re-inspect the window to establish a fresh binding")
        }
        if lower.contains("timeout") { return EngineError(.timeout, message) }
        return EngineError(.invalidStateTransition, message)
    }

    private func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = value else { return nil }
        return obj
    }
}
