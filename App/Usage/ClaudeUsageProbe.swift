import Foundation

/// Asks the installed `claude` CLI for its usage panel, in a pseudo-terminal.
///
/// A PTY rather than a pipe because the panel is a TUI: with pipes on its
/// standard streams the CLI takes itself to be non-interactive and prints
/// nothing worth parsing. This is the fallback route, used when the usage
/// endpoint cannot be reached, and it is deliberately hemmed in:
///
/// - **No tools.** `--allowed-tools ""` means the probe cannot read a file,
///   run a command or reach the network on the user's behalf. A monitor should
///   not be capable of doing work.
/// - **A dedicated working directory**, fixed rather than random. Claude keeps
///   history per project directory, so a fresh temporary path each refresh
///   would leave a trail of one-line projects in the user's history. One known
///   directory leaves one entry, and it is named so that whoever finds it can
///   tell what made it.
/// - **Bounded on every axis** — a deadline for the panel, a cap on how much
///   output is kept, and a kill on the way out through every exit.
final class ClaudeUsageProbe {
    struct Configuration {
        var executable: String
        var workingDirectory: URL
        /// `CLAUDE_CONFIG_DIR` for the account being asked about.
        var configDirectory: URL?
        /// How long to wait for the panel before giving up.
        var timeout: TimeInterval = 25
        /// Read after the last byte arrives before deciding the panel is done.
        var quietPeriod: TimeInterval = 1.2
        var maxBytes = 512 * 1024
        /// Also ask `/status`, for the account line.
        var includeStatus = true
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Runs the probe and returns everything the CLI drew. Blocking.
    func run() throws -> String {
        try FileManager.default.createDirectory(
            at: configuration.workingDirectory, withIntermediateDirectories: true
        )
        try writeReadme()

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw UsageFetchError(.processFailed, detail: "could not open a pty")
        }
        let slavePath = String(cString: ttyname(slave))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addchdir_np(&fileActions, configuration.workingDirectory.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let arguments = [configuration.executable, "--allowed-tools", ""]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment().map { strdup($0) } + [nil]

        var pid: pid_t = 0
        let status = posix_spawn(&pid, configuration.executable, &fileActions, &attr, argv, envp)

        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        close(slave)

        guard status == 0 else {
            close(master)
            throw UsageFetchError(.processFailed, detail: "claude did not start")
        }
        defer { terminate(pid: pid, master: master) }

        return try converse(master: master)
    }

    // MARK: - Conversation

    /// Sends the commands and reads until the panel is there and has stopped
    /// changing.
    ///
    /// The quiet period is what makes this reliable without knowing the CLI's
    /// layout: a TUI redraws as it settles, so the first frame containing
    /// "Current session" is often incomplete. Waiting for the drawing to stop
    /// costs a second and is the difference between reading a panel and reading
    /// half of one.
    private func converse(master: Int32) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(configuration.timeout)

        // Let the CLI draw its prompt before typing into it; a slash command
        // sent before the input exists is swallowed.
        _ = readUntil(master: master, deadline: min(deadline, Date().addingTimeInterval(6)), into: &collected) { _ in false }

        write(master: master, text: "/usage\r")
        var sawPanel = false
        _ = readUntil(master: master, deadline: deadline, into: &collected) { text in
            sawPanel = ClaudeUsagePanelParser.panelIsPresent(text)
            return sawPanel
        }

        if sawPanel {
            settle(master: master, into: &collected, deadline: deadline)
        }

        if configuration.includeStatus, Date() < deadline {
            write(master: master, text: "/status\r")
            let statusDeadline = min(deadline, Date().addingTimeInterval(8))
            _ = readUntil(master: master, deadline: statusDeadline, into: &collected) { text in
                text.lowercased().contains("account") || text.lowercased().contains("login")
            }
            settle(master: master, into: &collected, deadline: statusDeadline)
        }

        let text = String(decoding: collected, as: UTF8.self)
        guard !text.isEmpty else {
            throw UsageFetchError(.timedOut, detail: "claude produced no output")
        }
        return text
    }

    /// Reads until `isDone` sees what it is waiting for, or the deadline passes.
    private func readUntil(
        master: Int32,
        deadline: Date,
        into collected: inout Data,
        isDone: (String) -> Bool
    ) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(master, &readSet)
            var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            let ready = select(master + 1, &readSet, nil, nil, &timeout)
            if ready <= 0 { continue }

            let count = read(master, &buffer, buffer.count)
            // 0 is the child closing the terminal, -1 an error; either way
            // there is nothing more coming.
            guard count > 0 else { return false }
            if collected.count < configuration.maxBytes {
                collected.append(contentsOf: buffer[0..<count])
            }
            if isDone(String(decoding: collected, as: UTF8.self)) { return true }
        }
        return false
    }

    /// Keeps reading while the output is still changing.
    private func settle(master: Int32, into collected: inout Data, deadline: Date) {
        let quietUntil = min(deadline, Date().addingTimeInterval(configuration.quietPeriod))
        _ = readUntil(master: master, deadline: quietUntil, into: &collected) { _ in false }
    }

    private func write(master: Int32, text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { pointer in
            Darwin.write(master, pointer.baseAddress, pointer.count)
        }
    }

    // MARK: - Teardown

    /// The CLI is asked to leave, then made to.
    ///
    /// A TUI holding a PTY does not always exit on SIGTERM, and a probe that
    /// leaked one process per refresh would be worse than no probe: the leak
    /// would be invisible, and each copy holds a terminal open.
    private func terminate(pid: pid_t, master: Int32) {
        write(master: master, text: "\u{0003}")           // ^C
        write(master: master, text: "/exit\r")
        let deadline = Date().addingTimeInterval(1.5)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { close(master); return }
            usleep(50_000)
        }
        kill(pid, SIGTERM)
        let hardDeadline = Date().addingTimeInterval(1)
        while Date() < hardDeadline {
            if waitpid(pid, &status, WNOHANG) == pid { close(master); return }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        close(master)
    }

    // MARK: - Environment

    /// A scrubbed environment plus the two things the CLI needs.
    ///
    /// `TERM` matters: without it the CLI cannot decide how to draw, and the
    /// panel this probe exists to read is the thing that does not appear.
    private func environment() -> [String] {
        var values: [String: String] = [:]
        let parent = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "LANG", "TMPDIR", "SHELL", "USER"] {
            if let value = parent[key] { values[key] = value }
        }
        if values["PATH"] == nil {
            values["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        values["TERM"] = "xterm-256color"
        // Colour is stripped before parsing anyway, and asking for none makes
        // the text that survives closer to what a person reads.
        values["NO_COLOR"] = "1"
        if let directory = configuration.configDirectory {
            values["CLAUDE_CONFIG_DIR"] = directory.path
        }
        return values.map { "\($0.key)=\($0.value)" }
    }

    private func writeReadme() throws {
        let url = configuration.workingDirectory.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Uncoil usage probe

        Uncoil runs `claude` here, with every tool disabled, to read the panel
        `/usage` prints. It is a fixed directory rather than a fresh temporary
        one so that the CLI's own per-project history collects a single entry
        instead of one per reading.

        Nothing here is yours and nothing reads your projects. Deleting it is
        safe; it is created again the next time usage is read this way.
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - select() helpers

/// `fd_set` is a C bitfield with no Swift-visible API, so the two operations
/// this file needs are written out rather than reached for.
private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { raw in
        for index in raw.indices { raw[index] = 0 }
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: Int32.self) else { return }
        base[intOffset] |= Int32(1 << bitOffset)
    }
}

extension ClaudeUsagePanelParser {
    /// Whether the drawn text already holds a readable panel.
    ///
    /// Either label is enough. Waiting for both would time out on an account
    /// that has only one of them, and a partial panel read is better than no
    /// panel read as long as nothing is invented to fill the gap — which is
    /// exactly what the parser refuses to do.
    static func panelIsPresent(_ text: String) -> Bool {
        let lowered = strippingANSI(text).lowercased()
        return (sessionLabels + weekLabels).contains { lowered.contains($0) }
    }
}
