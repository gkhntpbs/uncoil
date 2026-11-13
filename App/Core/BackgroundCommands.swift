import Darwin
import Foundation

/// A process seen in one pass over the process table.
struct ProcessEntry: Equatable, Sendable {
    let pid: pid_t
    let parent: pid_t
    /// The kernel's short name (`p_comm`, at most 16 characters).
    let name: String
}

/// Finds commands an agent left running after its turn ended.
///
/// An agent can end its turn while a command it started keeps going — Claude
/// Code's `run_in_background`, a dev server, a long test run it means to come
/// back to. The hooks then say "Stop", and the session looked finished while
/// the agent was in fact waiting for that command to report back. Every agent
/// CLI runs a command through a shell it spawns, so a shell still alive under
/// the agent's process after the turn is the signal — independent of which
/// agent it is.
enum BackgroundCommands {
    static let shellNames: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// Helpers that run through a shell for a moment and are not the agent's
    /// work: Uncoil's own hook forwarder.
    static let ignoredNames: Set<String> = ["uncoil-hook"]

    /// One pass over every process of this user. Empty when the table cannot
    /// be read.
    static func snapshot() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let filled = size / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(filled).map { info in
            var comm = info.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ProcessEntry(pid: info.kp_proc.p_pid, parent: info.kp_eproc.e_ppid, name: name)
        }
    }

    /// Shell processes running commands below the agent rooted at `root`.
    ///
    /// The session's own process may itself be a login shell that started the
    /// agent, so the agent is the first non-shell process found walking down
    /// from the root; only shells *below the agent* are its commands. A shell
    /// whose subtree contains an ignored helper is skipped.
    ///
    /// Pure over `processes`, so it is testable with a made-up table.
    static func commandShells(under root: pid_t, in processes: [ProcessEntry]) -> [pid_t: String] {
        var children: [pid_t: [ProcessEntry]] = [:]
        var byPID: [pid_t: ProcessEntry] = [:]
        for entry in processes {
            children[entry.parent, default: []].append(entry)
            byPID[entry.pid] = entry
        }
        // The agent: breadth-first, the first process that is not a shell.
        var agent: pid_t?
        var queue: [pid_t] = [root]
        var seen: Set<pid_t> = []
        while !queue.isEmpty, agent == nil {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            if let entry = byPID[pid], !shellNames.contains(entry.name) {
                agent = pid
                break
            }
            queue.append(contentsOf: (children[pid] ?? []).map(\.pid))
        }
        guard let agent else { return [:] }

        func subtree(_ pid: pid_t) -> [ProcessEntry] {
            var out: [ProcessEntry] = []
            var stack = children[pid] ?? []
            var guardSet: Set<pid_t> = []
            while let next = stack.popLast() {
                guard guardSet.insert(next.pid).inserted else { continue }
                out.append(next)
                stack.append(contentsOf: children[next.pid] ?? [])
            }
            return out
        }

        var result: [pid_t: String] = [:]
        // Only the outermost shells: a shell's own sub-shells are one command.
        for child in children[agent] ?? [] where shellNames.contains(child.name) {
            let below = subtree(child.pid)
            if below.contains(where: { ignoredNames.contains($0.name) }) { continue }
            let work = below.first { !shellNames.contains($0.name) }?.name
            result[child.pid] = work ?? child.name
        }
        return result
    }

    /// The shell's `-c` script, trimmed to the command a person would
    /// recognise. Claude Code wraps the command as `… && eval '<cmd>' …`.
    static func commandLine(of pid: pid_t) -> String? {
        guard let argv = arguments(of: pid) else { return nil }
        guard let flag = argv.firstIndex(where: { $0 == "-c" || $0.hasPrefix("-c") && $0.count <= 3 }),
              flag + 1 < argv.count else { return nil }
        return summarize(script: argv[(flag + 1)...].joined(separator: " "))
    }

    static func summarize(script: String) -> String {
        var text = script
        if let start = text.range(of: "eval '") {
            let rest = text[start.upperBound...]
            if let end = rest.range(of: "' ") ?? rest.range(of: "'", options: .backwards) {
                text = String(rest[..<end.lowerBound])
            } else {
                text = String(rest)
            }
            text = text.replacingOccurrences(of: "'\\''", with: "'")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if text.count > 80 { text = String(text.prefix(79)) + "…" }
        return text
    }

    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Executable path, then padding NULs.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

/// Watches sessions whose turn ended with a command still running, and moves
/// them on when the command finishes.
@MainActor
final class BackgroundCommandWatcher {
    static let shared = BackgroundCommandWatcher()

    /// The session's root process. Replaceable for tests.
    var rootPID: @MainActor (UUID) -> pid_t? = { RuntimeClient.shared.processID(sid: $0) }

    private var watching: [UUID: Task<Void, Never>] = [:]
    /// Shells that were already there when the turn started — long-lived
    /// helpers an agent may run through a shell, which are not this turn's work.
    private var baseline: [UUID: Set<pid_t>] = [:]

    /// The turn began: remember what was already running, stop any watch.
    func turnStarted(_ sessionID: UUID) {
        watching[sessionID]?.cancel()
        watching[sessionID] = nil
        guard let root = rootPID(sessionID) else {
            baseline[sessionID] = nil
            return
        }
        let shells = BackgroundCommands.commandShells(under: root, in: BackgroundCommands.snapshot())
        baseline[sessionID] = Set(shells.keys)
    }

    /// The turn ended. After letting hook helpers exit, decides whether a
    /// command is still running.
    ///
    /// - Parameters:
    ///   - isStill: whether the session is still in the state the turn ended
    ///     in (or, later, still waiting) — anything else means the agent moved
    ///     on and its own events speak now.
    ///   - noCommand: nothing is running; the turn really is done.
    ///   - waiting: a command is running; its summary is passed.
    ///   - finished: the commands it was waiting for have all exited.
    func turnEnded(
        _ sessionID: UUID,
        isStill: @escaping @MainActor (_ waiting: Bool) -> Bool,
        noCommand: @escaping @MainActor () -> Void,
        waiting: @escaping @MainActor (String) -> Void,
        finished: @escaping @MainActor () -> Void
    ) {
        watching[sessionID]?.cancel()
        guard rootPID(sessionID) != nil else {
            noCommand()
            return
        }
        watching[sessionID] = Task { @MainActor [weak self] in
            // Two looks a moment apart: a process has to survive both to count,
            // which rules out hook helpers and status-line scripts.
            try? await Task.sleep(for: .milliseconds(1200))
            let first = self?.runningShells(sessionID) ?? [:]
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, isStill(false) else { return }
            let second = self.runningShells(sessionID)
            let lasting = second.filter { first[$0.key] != nil }
            guard let (pid, name) = lasting.min(by: { $0.key < $1.key }) else {
                noCommand()
                return
            }
            let command = BackgroundCommands.commandLine(of: pid) ?? name
            AppLog.log(.sessions, "session \(sessionID.uuidString.prefix(8)): turn ended with \(lasting.count) command(s) running — \(command)")
            waiting(command)
            var remaining = Set(lasting.keys)
            while !Task.isCancelled, !remaining.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                guard isStill(true) else { return }
                let now = self.runningShells(sessionID, includeBaseline: true)
                remaining.formIntersection(now.keys)
            }
            guard !Task.isCancelled, isStill(true) else { return }
            AppLog.log(.sessions, "session \(sessionID.uuidString.prefix(8)): background command(s) finished")
            finished()
        }
    }

    func forget(_ sessionID: UUID) {
        watching[sessionID]?.cancel()
        watching[sessionID] = nil
        baseline[sessionID] = nil
    }

    private func runningShells(_ sessionID: UUID, includeBaseline: Bool = false) -> [pid_t: String] {
        guard let root = rootPID(sessionID) else { return [:] }
        var shells = BackgroundCommands.commandShells(under: root, in: BackgroundCommands.snapshot())
        if !includeBaseline, let known = baseline[sessionID] {
            shells = shells.filter { !known.contains($0.key) }
        }
        return shells
    }
}
