import Foundation

/// A machine-readable explanation of why a run failed, paired with a hint a
/// human or agent can act on. `code` values are stable API (returned over MCP).
struct RunIssue: Equatable {
    let code: String
    let hint: String

    func asJSON() -> JSONValue {
        .object(["code": .string(code), "hint": .string(hint)])
    }
}

/// Pure failure classification from what we know after a process died (or
/// refused to become ready): exit code + captured output + the configuration.
enum RunDiagnostics {
    static func diagnose(
        exitCode: Int32?, logTail: String, config: RunConfiguration
    ) -> RunIssue {
        let log = logTail.lowercased()
        if log.contains("eaddrinuse") || log.contains("address already in use")
            || log.contains("port is already allocated") {
            let ports = config.ports.map(String.init).joined(separator: ", ")
            return RunIssue(
                code: "port_in_use",
                hint: "A port this configuration needs\(ports.isEmpty ? "" : " (\(ports))") is "
                    + "already taken. Stop the other process, or change the port in the "
                    + "command/env and update 'ports' in .uncoil/run.json."
            )
        }
        if exitCode == 127 || log.contains("command not found") || log.contains("no such file or directory: ") {
            return RunIssue(
                code: "command_not_found",
                hint: "The command isn't on PATH in a login shell. Install the tool or use "
                    + "an absolute path in .uncoil/run.json."
            )
        }
        if log.contains("cannot find module") || log.contains("err_module_not_found")
            || log.contains("missing script") {
            return RunIssue(
                code: "missing_dependencies",
                hint: "Node modules or the script are missing. Run the package manager "
                    + "install step in \(config.cwd) and check the script name in package.json."
            )
        }
        if log.contains("does not contain a scheme named") || log.contains("cannot find a scheme") {
            return RunIssue(
                code: "invalid_scheme",
                hint: "The Xcode scheme in the command doesn't exist. Run `xcodebuild -list` "
                    + "in \(config.cwd) and fix the -scheme argument in .uncoil/run.json."
            )
        }
        if log.contains("unable to find a destination") || log.contains("no destinations were provided") {
            return RunIssue(
                code: "invalid_destination",
                hint: "xcodebuild couldn't match the destination (simulator/device). Run "
                    + "`xcrun simctl list devices available` and set an available -destination."
            )
        }
        if log.contains("cannot connect to the docker daemon") || log.contains("is the docker daemon running") {
            return RunIssue(
                code: "docker_unavailable",
                hint: "The Docker daemon isn't running. Start Docker Desktop (or colima) "
                    + "and retry."
            )
        }
        if log.contains("build failed") || log.contains("** build failed **") {
            return RunIssue(
                code: "build_failed",
                hint: "The build failed; read the compiler errors in the log, fix the "
                    + "source, and start again."
            )
        }
        if log.contains("permission denied") {
            return RunIssue(
                code: "permission_denied",
                hint: "The command hit a permission error — check file modes and whether "
                    + "the script is executable."
            )
        }
        if let exitCode {
            return RunIssue(
                code: "exited",
                hint: "The process exited with code \(exitCode) before becoming ready. "
                    + "Read the log tail for the real error, then repair the configuration."
            )
        }
        return RunIssue(
            code: "not_ready",
            hint: "The process is alive but never matched ready_pattern or opened its "
                + "declared port. Fix 'ready_pattern'/'ports' in .uncoil/run.json if the "
                + "server is actually fine."
        )
    }
}
