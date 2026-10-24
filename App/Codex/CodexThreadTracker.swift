import Darwin
import Foundation
import SQLite3

/// Follows a Codex TUI session: which thread it is in, what it is doing, and
/// what Codex itself calls it.
///
/// Codex's TUI reports nothing to Uncoil, and since 0.160 it no longer writes
/// anything about a thread until the first prompt is sent — the rollout file
/// and the index row both appear minutes after launch, if at all. Watching
/// the sessions directory for half a minute after launch therefore found
/// nothing, and a session without its thread id cannot be resumed.
///
/// What Codex does do at launch is take a writer lock named after the thread,
/// and the process holding it is the one Uncoil started — recognisable by the
/// `UNCOIL_SESSION_ID` in its environment. Reading the lock from that process
/// is exact rather than a guess about which new file is whose, and it keeps
/// working when the user switches thread from inside Codex (`/new`,
/// `/resume`): the lock moves, and the record follows.
@MainActor
final class CodexThreadTracker {
    static let shared = CodexThreadTracker()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func track(
        recordID: UUID,
        codexHome: URL,
        cwd: String,
        projectStore: ProjectStore,
        sessionStore: SessionStore
    ) {
        stop(recordID)
        let startedAt = Date()
        let initialThreadID = projectStore.sessions.first { $0.id == recordID }?.providerSessionID
        weak var weakProjects = projectStore
        weak var weakSessions = sessionStore
        tasks[recordID] = Task.detached(priority: .utility) {
            var state = CodexTrackingState(
                recordID: recordID,
                codexHome: codexHome,
                cwd: cwd,
                startedAt: startedAt,
                threadID: initialThreadID
            )
            while !Task.isCancelled {
                let update = state.poll()
                if !update.isEmpty {
                    let accepted = await MainActor.run { () -> Bool in
                        guard let projects = weakProjects else { return false }
                        return Self.apply(update, recordID: recordID,
                                          projects: projects, sessions: weakSessions)
                    }
                    state.confirm(update, accepted: accepted)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop(_ recordID: UUID) {
        tasks.removeValue(forKey: recordID)?.cancel()
    }

    private static func apply(
        _ update: CodexTrackingUpdate,
        recordID: UUID,
        projects: ProjectStore,
        sessions: SessionStore?
    ) -> Bool {
        var accepted = true
        if let threadID = update.threadID {
            accepted = update.replacesThread
                ? projects.bindProviderSessionID(threadID, for: recordID)
                : projects.claimProviderSessionID(threadID, for: recordID)
        }
        if let title = update.title.flatMap(SessionAutoTitle.candidate(from:)) {
            projects.adoptAutomaticTitle(title, for: recordID)
        }
        if let sessions, let event = update.events.last {
            switch event {
            case .turnStarted:
                sessions.setStatus(.thinking, detail: String(localized: "Codex is working"), for: recordID)
            case .working:
                sessions.setStatus(.running, detail: String(localized: "Running a tool"), for: recordID)
            case .turnFinished:
                sessions.setStatus(.completed, for: recordID)
            case .turnAborted:
                sessions.setStatus(.idle, detail: String(localized: "Interrupted"), for: recordID)
            }
        }
        return accepted
    }
}

/// What one round of watching found.
struct CodexTrackingUpdate {
    var threadID: String?
    /// True when the id comes from the process itself, which is authoritative
    /// and may replace the one on the record; false for a guess from the
    /// sessions directory, which may only fill an empty record.
    var replacesThread = false
    var title: String?
    var events: [CodexRolloutTail.Event] = []

    var isEmpty: Bool { threadID == nil && title == nil && events.isEmpty }
}

/// The tracker's working memory, kept off the main actor.
struct CodexTrackingState {
    let recordID: UUID
    let codexHome: URL
    let cwd: String
    let startedAt: Date
    var threadID: String?

    private var pid: pid_t?
    private var lastProcessScan = Date.distantPast
    private var lastRolloutSearch = Date.distantPast
    private var rolloutURL: URL?
    private var tail = CodexRolloutTail()
    private var titled = false
    private var pendingThreadID: String?

    init(recordID: UUID, codexHome: URL, cwd: String, startedAt: Date, threadID: String?) {
        self.recordID = recordID
        self.codexHome = codexHome
        self.cwd = cwd
        self.startedAt = startedAt
        self.threadID = threadID
    }

    mutating func poll(now: Date = .now) -> CodexTrackingUpdate {
        var update = CodexTrackingUpdate()

        if let pid, kill(pid, 0) != 0 { self.pid = nil }
        if pid == nil, now.timeIntervalSince(lastProcessScan) >= 3 {
            lastProcessScan = now
            pid = CodexProcessProbe.codexProcess(sessionID: recordID)
        }

        if let pid {
            let held = CodexProcessProbe.heldThreadIDs(pid: pid)
            if let chosen = Self.mainThread(among: held, current: threadID, codexHome: codexHome),
               chosen != threadID {
                update.threadID = chosen
                update.replacesThread = true
            }
        } else if threadID == nil, now.timeIntervalSince(startedAt) > 10,
                  now.timeIntervalSince(lastRolloutSearch) >= 5 {
            // No process to ask — the control plane is not wired, or the
            // CLI is not one that takes the lock. The sessions directory is
            // the fallback: a thread begun here, in this directory, since.
            lastRolloutSearch = now
            update.threadID = CodexSessionLocator.candidates(
                codexHome: codexHome,
                cwd: cwd,
                startedAfter: startedAt.addingTimeInterval(-2)
            ).last?.id
        }
        pendingThreadID = update.threadID

        let current = update.threadID ?? threadID
        guard let current else { return update }

        // The index is asked only while there is something left to learn from
        // it: the name, or where the rollout is.
        let row = !titled || rolloutURL == nil
            ? CodexThreadIndex.thread(id: current, codexHome: codexHome) : nil
        if !titled, let row {
            let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (name?.isEmpty == false ? name : nil) ?? row.title
            if !title.isEmpty { update.title = title }
        }

        if rolloutURL == nil {
            if let path = row?.rolloutPath, FileManager.default.fileExists(atPath: path) {
                rolloutURL = URL(fileURLWithPath: path)
            } else if now.timeIntervalSince(lastRolloutSearch) >= 5 {
                lastRolloutSearch = now
                rolloutURL = CodexSessionStore.transcriptURL(codexHome: codexHome, threadID: current)
            }
            if let rolloutURL {
                // A file this launch created is read from the start, so the
                // first turn is not missed; one that was already there holds
                // turns that are history, and only what comes next is news.
                let created = (try? rolloutURL.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                tail = CodexRolloutTail(
                    startingAtEndOf: created < startedAt.addingTimeInterval(-5) ? rolloutURL : nil
                )
            }
        }
        if let rolloutURL {
            update.events = tail.read(rolloutURL)
        }
        return update
    }

    mutating func confirm(_ update: CodexTrackingUpdate, accepted: Bool) {
        if let id = pendingThreadID, accepted, id != threadID {
            threadID = id
            rolloutURL = nil
            tail = CodexRolloutTail()
            titled = false
        }
        if update.title != nil { titled = true }
    }

    /// The thread the session is in, out of the locks its process holds.
    ///
    /// Codex runs helper threads in the same process — the guardian that
    /// reviews approvals is one — so a process can hold several. The one
    /// already on the record wins while it is still held; otherwise helper
    /// threads are left out, and of the rest the earliest opened is the main
    /// one.
    static func mainThread(
        among held: [CodexProcessProbe.HeldLock],
        current: String?,
        codexHome: URL
    ) -> String? {
        if let current, held.contains(where: { $0.threadID == current }) { return current }
        return held
            .filter { CodexThreadIndex.thread(id: $0.threadID, codexHome: codexHome)?.isSubagent != true }
            .min { $0.descriptor < $1.descriptor }?
            .threadID
    }
}

// MARK: - Process

/// Reads, from the kernel, which Codex process belongs to a session and which
/// thread locks it holds open.
enum CodexProcessProbe {
    struct HeldLock: Equatable {
        let descriptor: Int32
        let threadID: String
    }

    /// The Codex process started for this Uncoil session, if one is running.
    static func codexProcess(sessionID: UUID) -> pid_t? {
        let marker = "UNCOIL_SESSION_ID=\(sessionID.uuidString)"
        // Codex's helpers (`codex-code-mode-host`, its MCP servers) inherit the
        // same environment, so the name and the marker are not enough: the
        // session's process is the one holding a thread lock.
        let matches = allProcesses().filter { pid in
            guard processName(pid).hasPrefix("codex"),
                  let arguments = processArguments(pid) else { return false }
            return environment(fromProcArgs: arguments).contains(marker)
        }
        return matches.first { !heldThreadIDs(pid: $0).isEmpty }
            ?? matches.first { processName($0) == "codex" }
    }

    /// `thread-writer-locks/<id>.lock` files the process has open.
    static func heldThreadIDs(pid: pid_t) -> [HeldLock] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return [] }
        var held: [HeldLock] = []
        for descriptor in descriptors.prefix(Int(used) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let read = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO,
                &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard read > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if let id = threadID(fromLockPath: path) {
                held.append(HeldLock(descriptor: descriptor.proc_fd, threadID: id))
            }
        }
        return held
    }

    static func threadID(fromLockPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "lock",
              url.deletingLastPathComponent().lastPathComponent == "thread-writer-locks"
        else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// The environment block of a `KERN_PROCARGS2` buffer: argc, the
    /// executable path, padding, argc arguments, then the environment, every
    /// string NUL-terminated.
    static func environment(fromProcArgs data: [UInt8]) -> [String] {
        guard data.count > 4 else { return [] }
        let argc = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        // Executable path, then the NULs padding it.
        while index < data.count, data[index] != 0 { index += 1 }
        while index < data.count, data[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < data.count {
            if data[index] == 0 {
                if index == start { break }
                strings.append(String(decoding: data[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return Array(strings.dropFirst(argc))
    }

    private static func allProcesses() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
    }

    private static func processArguments(_ pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }
}

// MARK: - Index

/// Codex's own thread index (`state_<n>.sqlite`), read-only.
enum CodexThreadIndex {
    struct Thread: Equatable {
        let title: String
        let name: String?
        let rolloutPath: String?
        let isSubagent: Bool
    }

    static func thread(id: String, codexHome: URL) -> Thread? {
        guard let database = databaseURL(codexHome: codexHome) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else { return nil }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)
        var statement: OpaquePointer?
        let query = "SELECT title, name, rollout_path, source FROM threads WHERE id = ?"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        return Thread(
            title: text(0) ?? "",
            name: text(1),
            rolloutPath: text(2),
            isSubagent: text(3)?.contains("subagent") ?? false
        )
    }

    /// The newest `state_<n>.sqlite`: the number is Codex's schema generation.
    static func databaseURL(codexHome: URL, manager: FileManager = .default) -> URL? {
        guard let names = try? manager.contentsOfDirectory(atPath: codexHome.path) else { return nil }
        return names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                      let generation = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                return (generation, name)
            }
            .max { $0.0 < $1.0 }
            .map { codexHome.appendingPathComponent($0.1) }
    }
}

// MARK: - Rollout

/// Reads what a Codex thread is doing from the rollout file it appends to.
struct CodexRolloutTail {
    enum Event: Equatable {
        case turnStarted
        case working
        case turnFinished
        case turnAborted
    }

    private var offset: UInt64 = 0
    private var remainder = Data()

    init() {}

    /// Starts after what is already in `url`, or at the beginning when nil.
    init(startingAtEndOf url: URL?) {
        if let url,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 {
            offset = size
        }
    }

    mutating func read(_ url: URL) -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return [] }
        offset += UInt64(data.count)
        remainder.append(data)
        var events: [Event] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = remainder[remainder.startIndex..<newline]
            if let event = Self.event(fromLine: line) { events.append(event) }
            remainder.removeSubrange(remainder.startIndex...newline)
        }
        return events
    }

    /// The event a rollout line stands for, if it is one that changes status.
    ///
    /// Only the head of the line is looked at: the type comes first, and the
    /// lines that matter are small while some that do not run to hundreds of
    /// kilobytes.
    static func event(fromLine line: Data) -> Event? {
        let head = String(decoding: line.prefix(400), as: UTF8.self)
        guard let match = head.firstMatch(of: lineHead) else { return nil }
        switch (match.1, match.2) {
        case ("event_msg", "task_started"): return .turnStarted
        case ("event_msg", "task_complete"): return .turnFinished
        case ("event_msg", "turn_aborted"): return .turnAborted
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"),
             ("response_item", "local_shell_call"), ("response_item", "web_search_call"):
            return .working
        default: return nil
        }
    }

    nonisolated(unsafe) private static let lineHead =
        /"type":"(event_msg|response_item)","payload":\{"type":"([a-z_]+)"/
}
