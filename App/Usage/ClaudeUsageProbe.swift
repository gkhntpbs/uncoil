import Foundation

/// Asks the installed `claude` CLI for its usage panel, in a pseudo-terminal.
///
/// A PTY rather than a pipe because the panel is a TUI: with pipes on its
/// standard streams the CLI takes itself to be non-interactive and prints
/// nothing worth parsing. This is the route Uncoil takes first — the CLI reads
/// its own login, so nobody is asked for a credential — and it is deliberately
/// hemmed in:
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
        /// Also ask `/status`.
        ///
        /// Off, because nothing reads it: the panel `/usage` draws already
        /// carries both windows, and the account line it would add is not
        /// parsed. It cost eight seconds of a twenty-eight second probe to
        /// collect something nobody looked at.
        var includeStatus = false
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
            throw UsageFetchError(
                .processFailed,
                detail: "claude did not start: \(String(cString: strerror(status))) (\(configuration.executable))"
            )
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
        // sent before the input exists is swallowed. A first run in this
        // folder asks whether to trust it instead — on a Mac where nobody has
        // answered that yet, `/usage` used to be typed into the question and
        // the probe timed out. The default answer is "Yes, proceed", and the
        // folder holds nothing but the README this probe wrote.
        var answeredTrust = false
        _ = readUntil(master: master, deadline: min(deadline, Date().addingTimeInterval(6)), into: &collected) { text in
            Self.asksForTrust(text)
        }
        if Self.asksForTrust(String(decoding: collected, as: UTF8.self)) {
            answeredTrust = true
            write(master: master, text: "\r")
            _ = readUntil(master: master, deadline: min(deadline, Date().addingTimeInterval(4)), into: &collected) { _ in false }
        }

        write(master: master, text: "/usage\r")
        var sawPanel = false
        // One retry: a slow first start can still swallow the first command.
        let firstTry = min(deadline, Date().addingTimeInterval(10))
        _ = readUntil(master: master, deadline: firstTry, into: &collected) { text in
            sawPanel = ClaudeUsagePanelParser.panelIsPresent(text)
            return sawPanel
        }
        if !sawPanel, Date() < deadline {
            write(master: master, text: "\u{1b}")
            write(master: master, text: "/usage\r")
            _ = readUntil(master: master, deadline: deadline, into: &collected) { text in
                sawPanel = ClaudeUsagePanelParser.panelIsPresent(text)
                return sawPanel
            }
        }
        if !sawPanel {
            // What the CLI was showing instead is the whole diagnosis — a login
            // prompt, an update notice, an error. Logged (redacted), not shown.
            let tail = String(ClaudeUsagePanelParser.strippingANSI(String(decoding: collected, as: UTF8.self))
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(12)
                .joined(separator: " | ")
                .suffix(900))
            AppLog.log(.usage, "claude probe: no panel\(answeredTrust ? " (answered the trust prompt)" : ""); screen ended with: \(tail)")
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
        for key in ["HOME", "LANG", "TMPDIR", "SHELL", "USER", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
                    "https_proxy", "http_proxy", "no_proxy"] {
            if let value = parent[key] { values[key] = value }
        }
        values["PATH"] = Self.probePATH(executable: configuration.executable)
        values["TERM"] = "xterm-256color"
        // Colour is stripped before parsing anyway, and asking for none makes
        // the text that survives closer to what a person reads.
        values["NO_COLOR"] = "1"
        if let directory = configuration.configDirectory {
            values["CLAUDE_CONFIG_DIR"] = directory.path
        }
        return values.map { "\($0.key)=\($0.value)" }
    }

    /// The PATH a probe runs with: the CLI's own folder first (an npm or nvm
    /// install keeps `node` beside `claude`), then the login shell's PATH, then
    /// the app's own.
    ///
    /// A Finder-launched app gets launchd's `/usr/bin:/bin:/usr/sbin:/sbin`.
    /// A `claude` that is a `#!/usr/bin/env node` script cannot start under
    /// that — which never showed on a Mac with the native build, and was the
    /// whole failure on one with the npm package.
    static func probePATH(executable: String) -> String {
        var directories: [String] = []
        func add(_ directory: String) {
            if !directory.isEmpty, !directories.contains(directory) { directories.append(directory) }
        }
        add((executable as NSString).deletingLastPathComponent)
        let resolved = (executable as NSString).resolvingSymlinksInPath
        add((resolved as NSString).deletingLastPathComponent)
        SettingsStore.interactivePATH.forEach(add)
        BinarySearchPath.directories().forEach(add)
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).forEach(add)
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach(add)
        return directories.joined(separator: ":")
    }

    /// Claude's "do you trust the files in this folder?" question.
    static func asksForTrust(_ text: String) -> Bool {
        let lowered = ClaudeUsagePanelParser.strippingANSI(text).lowercased()
        return lowered.contains("trust the files")
            || lowered.contains("do you trust")
            || (lowered.contains("trust") && lowered.contains("yes, proceed"))
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
func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { raw in
        for index in raw.indices { raw[index] = 0 }
    }
}

func fdSet(_ fd: Int32, _ set: inout fd_set) {
    // An `fd_set` holds exactly FD_SETSIZE bits and no more. A descriptor above
    // that is not representable, and writing its bit anyway would run off the
    // end of the struct and corrupt whatever followed it — a process that has
    // been open long enough to reach fd 1024 is precisely the one that cannot
    // afford that.
    guard fd >= 0, fd < Int32(FD_SETSIZE) else { return }
    let intOffset = Int(fd) / 32
    let bitOffset = UInt32(Int(fd) % 32)
    withUnsafeMutableBytes(of: &set.fds_bits) { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: Int32.self) else { return }
        // Shifted as unsigned and reinterpreted, not converted. Bit 31 is the
        // sign bit: `Int32(1 << 31)` is 2_147_483_648, one past `Int32.max`,
        // and the conversion traps rather than wrapping. The bitfield wants
        // that bit set, not that number, so the pattern is what is written.
        base[intOffset] |= Int32(bitPattern: UInt32(1) << bitOffset)
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
