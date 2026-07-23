import Foundation

/// Centralized, security-conscious external-process spawner used by the
/// browser/computer adapters. Never invokes a shell, never interpolates
/// strings into a command line, and always passes an explicit argv array so
/// there is no word-splitting or glob/interpolation surface.
///
/// Guarantees enforced here (see `run`):
/// - **argv whitelist:** the caller asserts every argument is a value it
///   produced; this type additionally rejects any argument containing a NUL.
/// - **env scrub:** the child sees ONLY PATH/HOME/LANG (plus explicit extras a
///   caller passes), never the parent's full environment (no tokens leak).
/// - **output caps:** stdout/stderr are each capped at 4 MB; excess is dropped
///   and the result is flagged truncated.
/// - **timeout:** a hard wall-clock deadline; on expiry the child is SIGTERM'd
///   then SIGKILL'd and `.timedOut` is returned.
enum ProcessRunner {
    /// Max bytes captured per stream before truncation.
    static let maxOutputBytes = 4 * 1024 * 1024

    struct Result {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var truncated: Bool
        var launchError: String?

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
        var launched: Bool { launchError == nil }
    }

    /// Runs `executable` with exactly `arguments`. `cwd` sets the working
    /// directory; `extraEnv` adds/overrides scrubbed environment entries
    /// (values are still passed literally, never interpreted).
    ///
    /// Blocking: intended to be called off the main thread (the control-plane
    /// handlers dispatch it via `Task.detached`). Returns a `Result`; it does
    /// not throw for non-zero exits — inspect `exitCode`.
    static func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> Result {
        // Defensive argv validation: no embedded NULs (would truncate argv).
        for arg in arguments where arg.utf8.contains(0) {
            return Result(exitCode: -1, stdout: Data(), stderr: Data(),
                          timedOut: false, truncated: false,
                          launchError: "argument contains NUL byte")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        // Env scrub: start empty, admit only a minimal safe allowlist.
        var env: [String: String] = [:]
        let parent = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "LANG"] {
            if let value = parent[key] { env[key] = value }
        }
        // A sane default PATH if the parent had none (GUI launches).
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Reader threads so a large child can't deadlock on a full pipe.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var truncated = false

        func drain(_ handle: FileHandle, into sink: inout Data) {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if sink.count < maxOutputBytes {
                    let room = maxOutputBytes - sink.count
                    if chunk.count <= room {
                        sink.append(chunk)
                    } else {
                        sink.append(chunk.prefix(room))
                        truncated = true
                    }
                } else {
                    truncated = true
                }
                lock.unlock()
            }
        }

        let outThread = Thread { drain(outPipe.fileHandleForReading, into: &outData) }
        let errThread = Thread { drain(errPipe.fileHandleForReading, into: &errData) }
        outThread.stackSize = 512 * 1024
        errThread.stackSize = 512 * 1024

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: Data(), stderr: Data(),
                          timedOut: false, truncated: false,
                          launchError: "launch failed: \(error.localizedDescription)")
        }
        outThread.start()
        errThread.start()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate() // SIGTERM
                // Grace period, then hard kill.
                let killAt = Date().addingTimeInterval(2)
                while process.isRunning && Date() < killAt {
                    usleep(20_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(20_000)
        }
        process.waitUntilExit()
        // Let reader threads flush the last chunks.
        outThread.cancel(); errThread.cancel()
        usleep(30_000)

        lock.lock()
        let capturedOut = outData
        let capturedErr = errData
        let wasTruncated = truncated
        lock.unlock()

        return Result(
            exitCode: process.terminationStatus,
            stdout: capturedOut, stderr: capturedErr,
            timedOut: timedOut, truncated: wasTruncated, launchError: nil)
    }
}
