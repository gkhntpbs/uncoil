import Foundation

/// Follows the transcripts of agent sessions running in their own terminals.
///
/// Anything that wants to see what a native Claude or Codex session is doing —
/// Uncoil Auto's conversation, its agent panel — retains the session here and
/// reads the result from `AgentEventHub.transcripts`, the way a structured
/// session is read from the shared hub. Nothing is sent to the agent and its
/// terminal is not touched: the transcript is only read.
///
/// The observed events live in a hub of their own rather than the shared one.
/// The shared hub is what the control plane reports as a session's structured
/// timeline; a transcript read after the fact is an observation, not the
/// session speaking, and must not turn a terminal session into one that
/// claims to publish events.
@MainActor
final class NativeSessionObservers {
    static let shared = NativeSessionObservers()

    /// How often a followed transcript is checked for new lines.
    static let interval: TimeInterval = 0.6

    private var watchers: [UUID: NativeTranscriptWatcher] = [:]
    private var retainCount: [UUID: Int] = [:]
    private let hub: AgentEventHub

    init(hub: AgentEventHub = .transcripts) {
        self.hub = hub
    }

    /// Starts following the session's transcript, if its provider keeps one.
    /// Balanced by `release`.
    func retain(_ sessionID: UUID, locate: @escaping () -> NativeTranscriptLocation?) {
        retainCount[sessionID, default: 0] += 1
        guard watchers[sessionID] == nil else { return }
        let hub = hub
        let watcher = NativeTranscriptWatcher(locate: locate) { event in
            hub.publish(event.event, sessionID: sessionID, provider: event.provider)
        } reset: {
            hub.reset(sessionID)
        }
        watchers[sessionID] = watcher
        watcher.start(interval: Self.interval)
    }

    func release(_ sessionID: UUID) {
        guard let count = retainCount[sessionID] else { return }
        if count > 1 {
            retainCount[sessionID] = count - 1
            return
        }
        retainCount[sessionID] = nil
        watchers.removeValue(forKey: sessionID)?.stop()
    }

    /// How far the session's transcript has been read.
    func position(for sessionID: UUID) -> NativeTranscriptPosition? {
        watchers[sessionID]?.position
    }

    func isFollowing(_ sessionID: UUID) -> Bool {
        watchers[sessionID] != nil
    }

    /// Checks every followed transcript now instead of at the next tick.
    func pollNow() {
        watchers.values.forEach { $0.poll() }
    }
}

extension AgentEventHub {
    /// What agent CLIs wrote in their own transcripts, as Uncoil read it.
    static let transcripts = AgentEventHub()
}

/// How far into a transcript someone has read: the file, and the byte after
/// the last whole line taken from it.
struct NativeTranscriptPosition: Equatable, Codable {
    var path: String
    var offset: UInt64
}

/// Where one session's transcript is, and how to read it.
struct NativeTranscriptLocation: Equatable {
    var url: URL
    var provider: AgentProvider

    /// The transcript of a native agent session, when its provider keeps one
    /// and the session has already been told which conversation it is.
    @MainActor
    static func resolve(
        record: SessionRecord, project: Project, account: AccountProfile?, profilesRoot: URL
    ) -> NativeTranscriptLocation? {
        guard let conversation = record.providerSessionID else { return nil }
        let configDirectory = account?.configDirectory(profilesRoot: profilesRoot)
        switch record.provider {
        case .claude:
            return NativeTranscriptLocation(
                url: ClaudeSessionStore.transcriptURL(
                    configDirectory: configDirectory ?? ClaudeSessionStore.defaultConfigDirectory(),
                    cwd: record.workingDirectory(in: project),
                    sessionID: conversation),
                provider: .claude)
        case .codex:
            return CodexSessionStore.transcriptURL(
                codexHome: configDirectory ?? CodexSessionStore.defaultHome(),
                threadID: conversation
            ).map { NativeTranscriptLocation(url: $0, provider: .codex) }
        default:
            return nil
        }
    }
}

/// Tails one transcript file.
///
/// The first read takes only the end of the file — enough for the latest few
/// things the agent did — and reports it as history; everything after is
/// reported as it is appended. A session that moves to another conversation
/// moves the watcher with it.
@MainActor
final class NativeTranscriptWatcher {
    struct Output {
        let event: AgentEvent
        let provider: AgentProvider
    }

    /// How much of an existing transcript is read when following starts.
    static let initialWindow: UInt64 = 96 * 1024

    private let locate: () -> NativeTranscriptLocation?
    private let emit: (Output) -> Void
    private let reset: () -> Void
    private var location: NativeTranscriptLocation?
    private var reader: (any NativeTranscriptReader)?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var timer: Timer?
    private var lastLocateAttempt = Date.distantPast

    init(
        locate: @escaping () -> NativeTranscriptLocation?,
        emit: @escaping (Output) -> Void,
        reset: @escaping () -> Void
    ) {
        self.locate = locate
        self.emit = emit
        self.reset = reset
    }

    func start(interval: TimeInterval) {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Everything read so far, not counting a line still being written.
    var position: NativeTranscriptPosition? {
        location.map { NativeTranscriptPosition(path: $0.url.path, offset: offset - UInt64(partial.count)) }
    }

    /// What was appended to a transcript after `position`, read once and in
    /// full — for a reader who was away, catching up before following again.
    /// Nothing when the transcript has moved or been rewritten since.
    static func read(
        _ location: NativeTranscriptLocation, from position: NativeTranscriptPosition
    ) -> (events: [AgentEvent], position: NativeTranscriptPosition) {
        guard location.url.path == position.path,
              var reader = NativeTranscriptReaders.reader(for: location.provider),
              let handle = try? FileHandle(forReadingFrom: location.url) else { return ([], position) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > position.offset else { return ([], position) }
        try? handle.seek(toOffset: position.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else {
            return ([], position)
        }
        let whole = data.prefix(upTo: lastNewline)
        var events: [AgentEvent] = []
        for line in String(decoding: whole, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            events += reader.events(forLine: line)
        }
        let consumed = UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        return (events, NativeTranscriptPosition(path: position.path, offset: position.offset + consumed))
    }

    func poll() {
        relocateIfNeeded()
        guard let location, var reader else { return }
        guard let handle = try? FileHandle(forReadingFrom: location.url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            // Rewritten from the start: read it again.
            offset = 0
            partial.removeAll()
        }
        guard size > offset else { return }
        let firstRead = offset == 0 && partial.isEmpty && lines == 0
        var start = offset
        if firstRead, size > Self.initialWindow { start = size - Self.initialWindow }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return }
        offset = size
        var chunk = partial + data
        if firstRead, start > 0, let newline = chunk.firstIndex(of: 0x0A) {
            // The window starts mid-line; the first whole line is after it.
            chunk = chunk.suffix(from: chunk.index(after: newline))
        }
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            partial = chunk
            return
        }
        partial = Data(chunk.suffix(from: chunk.index(after: lastNewline)))
        let text = String(decoding: chunk.prefix(upTo: lastNewline), as: UTF8.self)
        var history: [AgentItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            for event in reader.events(forLine: line) {
                if firstRead {
                    switch event {
                    case .itemStarted(let item), .itemCompleted(let item):
                        if let index = history.firstIndex(where: { $0.id == item.id }) {
                            history[index] = item
                        } else {
                            history.append(item)
                        }
                    default:
                        break
                    }
                } else {
                    emit(Output(event: event, provider: location.provider))
                }
            }
        }
        self.reader = reader
        if firstRead, !history.isEmpty {
            emit(Output(event: .historyLoaded(history), provider: location.provider))
        }
    }

    private var lines = 0

    /// Finds the transcript, and follows the session to a new one when it
    /// changes conversation. Looking is not free for Codex — it walks the
    /// sessions tree — so a transcript that is not there yet is looked for
    /// again every few seconds, not on every tick.
    private func relocateIfNeeded() {
        let now = Date()
        if location != nil, now.timeIntervalSince(lastLocateAttempt) < 5 { return }
        if location == nil, now.timeIntervalSince(lastLocateAttempt) < 2 { return }
        lastLocateAttempt = now
        let found = locate()
        guard found != location else { return }
        if location != nil { reset() }
        location = found
        reader = found.flatMap { NativeTranscriptReaders.reader(for: $0.provider) }
        offset = 0
        partial.removeAll()
        lines = 0
    }
}
