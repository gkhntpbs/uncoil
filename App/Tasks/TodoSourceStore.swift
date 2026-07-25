import Foundation

/// What changed about one task source between two scans.
enum TodoSourceChange: Equatable {
    case added
    case unchanged
    /// Only checkbox marks moved — the cheapest refresh a board can do.
    case checkboxesChanged(taskIDs: [String])
    /// Tasks or headings were added, removed, reworded or moved, so board
    /// placement has to be recomputed.
    case structureChanged
    /// The file is gone. Relations are kept: a file can come back.
    case missing
    case restored
    /// The same content turned up at a new path.
    case moved(from: String)

    var needsBoardRecompute: Bool {
        switch self {
        case .added, .structureChanged, .restored, .moved: true
        case .unchanged, .checkboxesChanged, .missing: false
        }
    }
}

/// Availability of a source on disk. A missing file never deletes what Uncoil
/// knows about its tasks — an agent mid-rebase, a `git checkout`, or a
/// half-finished move would otherwise wipe real state.
enum TodoSourceStatus: Equatable {
    case present
    case missing(since: Date)

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .present: "Mevcut"
        case .missing: "Source missing"
        }
    }
}

/// Holds the parsed task sources of one project and keeps them current.
///
/// Refresh is a pure-ish rescan-and-diff, so the interesting behaviour — what
/// counts as a checkbox-only change, what happens when a file disappears and
/// comes back, how a moved file is recognised — is testable without any
/// filesystem events. `TodoSourceWatcher` only decides *when* to call it.
@MainActor
final class TodoSourceStore: ObservableObject {
    @Published private(set) var sources: [ProjectTaskSource] = []
    @Published private(set) var documents: [String: TaskDocument] = [:]
    @Published private(set) var statuses: [String: TodoSourceStatus] = [:]
    @Published private(set) var lastChanges: [String: TodoSourceChange] = [:]
    @Published private(set) var lastRefreshAt: Date?
    /// Task ids whose Uncoil-side relations could not be re-attached after the
    /// file changed. Surfaced rather than silently dropped.
    @Published private(set) var needsRelinking: Set<String> = []
    /// A scan is in flight. Lets the UI show progress instead of an empty state.
    @Published private(set) var isLoading = false
    /// At least one scan has completed. Without this the UI cannot tell "not
    /// scanned yet" from "scanned, no TODO.md" and flashes the empty state.
    @Published private(set) var hasLoadedOnce = false

    /// mtime+size per source from the last scan, so an untouched file is never
    /// read again.
    private var stamps: [String: TodoDiscovery.FileStamp] = [:]
    /// Coalescing: a request that arrives mid-scan is remembered, not queued —
    /// ten events during one walk must cost one extra scan, not ten.
    private var isScanning = false
    private var rescanRequested = false
    /// Scans actually performed. Diagnostics — and how coalescing is asserted.
    private(set) var completedScanCount = 0

    let projectID: UUID
    let projectRoot: String
    var rules: TodoDiscovery.Rules

    init(
        projectID: UUID,
        projectRoot: String,
        rules: TodoDiscovery.Rules = .default
    ) {
        self.projectID = projectID
        self.projectRoot = projectRoot
        self.rules = rules
    }

    var allTasks: [ProjectTask] {
        sources.compactMap { documents[$0.path] }.flatMap(\.tasks)
    }

    func document(for path: String) -> TaskDocument? { documents[path] }

    func status(for path: String) -> TodoSourceStatus {
        statuses[path] ?? .present
    }

    /// Rescans the project and folds the result in, reporting per-source changes.
    ///
    /// `trackedTaskIDs` are the tasks Uncoil has state for (a session assignment,
    /// a lease); any that cannot be re-resolved land in `needsRelinking`.
    @discardableResult
    func refresh(
        trackedFingerprints: [String: TaskFingerprint] = [:],
        now: Date = .now
    ) -> [String: TodoSourceChange] {
        let scan = TodoDiscovery.scan(
            projectID: projectID,
            projectRoot: projectRoot,
            rules: rules,
            now: now,
            cache: scanCache
        )
        return apply(scan, trackedFingerprints: trackedFingerprints, now: now)
    }

    /// Rescans off the main actor and folds the result in on it.
    ///
    /// The walk and the Markdown parse are what used to stall the window when
    /// the Tasks tab opened; only the fold-in needs the main actor.
    func refreshAsync(trackedFingerprints: [String: TaskFingerprint] = [:]) async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        if !hasLoadedOnce { isLoading = true }
        defer {
            isScanning = false
            if isLoading { isLoading = false }
            if !hasLoadedOnce { hasLoadedOnce = true }
        }
        repeat {
            rescanRequested = false
            let projectID = projectID
            let projectRoot = projectRoot
            let rules = rules
            let cache = scanCache
            let now = Date.now
            let scan = await Task.detached(priority: .utility) {
                TodoDiscovery.scan(
                    projectID: projectID,
                    projectRoot: projectRoot,
                    rules: rules,
                    now: now,
                    cache: cache
                )
            }.value
            _ = apply(scan, trackedFingerprints: trackedFingerprints, now: now)
        } while rescanRequested && !Task.isCancelled
    }

    /// What a fresh scan may reuse: everything already parsed whose file is
    /// still stamped the same.
    private var scanCache: [String: TodoDiscovery.CachedSource] {
        var cache: [String: TodoDiscovery.CachedSource] = [:]
        for source in sources {
            guard let stamp = stamps[source.path],
                  let document = documents[source.path] else { continue }
            cache[source.path] = TodoDiscovery.CachedSource(
                stamp: stamp, source: source, document: document
            )
        }
        return cache
    }

    @discardableResult
    private func apply(
        _ scan: TodoDiscovery.ScanResult,
        trackedFingerprints: [String: TaskFingerprint],
        now: Date
    ) -> [String: TodoSourceChange] {
        completedScanCount += 1
        let found = scan.loaded
        var changes: [String: TodoSourceChange] = [:]
        var newDocuments: [String: TaskDocument] = [:]
        var newStatuses: [String: TodoSourceStatus] = [:]
        var newSources: [ProjectTaskSource] = []

        let previousPaths = Set(sources.map(\.path))
        let foundPaths = Set(found.map(\.source.path))

        for entry in found {
            let path = entry.source.path
            newDocuments[path] = entry.document
            newStatuses[path] = .present
            newSources.append(entry.source)

            // Status is checked before content: a source that was missing keeps
            // its last document, so comparing content first would report a
            // returning file as "unchanged".
            if status(for: path).isMissing {
                changes[path] = .restored
            } else if let previous = documents[path] {
                changes[path] = classify(previous: previous, current: entry.document)
            } else if let origin = movedSource(
                for: entry.document, excluding: foundPaths
            ) {
                changes[path] = .moved(from: origin)
            } else {
                changes[path] = .added
            }
        }

        // A source that vanished keeps its last known document and its
        // relations; only its status changes.
        for path in previousPaths.subtracting(foundPaths) {
            newDocuments[path] = documents[path]
            if case .missing(let since) = status(for: path) {
                newStatuses[path] = .missing(since: since)
                changes[path] = .missing
            } else {
                newStatuses[path] = .missing(since: now)
                changes[path] = .missing
            }
            if let source = sources.first(where: { $0.path == path }) {
                newSources.append(source)
            }
        }

        stamps = scan.stamps

        // A poll that finds nothing new must publish nothing: every assignment
        // to an @Published property re-renders the board, which is what made
        // the UI stutter once per poll interval.
        let isNoOp = changes.values.allSatisfy { $0 == .unchanged }
            && previousPaths == foundPaths
        if isNoOp {
            if lastChanges != changes { lastChanges = changes }
            if lastRefreshAt == nil { lastRefreshAt = now }
            if !hasLoadedOnce { hasLoadedOnce = true }
            relink(trackedFingerprints)
            return changes
        }

        sources = newSources.sorted {
            $0.isRoot != $1.isRoot ? $0.isRoot : $0.displayPath < $1.displayPath
        }
        documents = newDocuments
        statuses = newStatuses
        lastChanges = changes
        lastRefreshAt = now
        if !hasLoadedOnce { hasLoadedOnce = true }
        relink(trackedFingerprints)
        return changes
    }

    /// Re-resolves tracked tasks against the current documents. A task whose
    /// file is missing is left alone — it is expected back.
    private func relink(_ tracked: [String: TaskFingerprint]) {
        guard !tracked.isEmpty else {
            if !needsRelinking.isEmpty { needsRelinking = [] }
            return
        }
        var unresolved: Set<String> = []
        let byFile = Dictionary(grouping: tracked, by: { $0.value.filePath })
        for (path, entries) in byFile {
            if status(for: path).isMissing { continue }
            let tasks = documents[path]?.tasks ?? []
            let resolutions = TaskRelinker.resolveAll(
                Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) }),
                in: tasks
            )
            for (key, resolution) in resolutions where resolution.needsRelinking {
                unresolved.insert(key)
            }
        }
        if needsRelinking != unresolved { needsRelinking = unresolved }
    }

    /// Checkbox-only changes are common (an agent ticks a box) and cheap to
    /// apply, so they are distinguished from anything structural.
    func classify(previous: TaskDocument, current: TaskDocument) -> TodoSourceChange {
        guard previous.contentHash != current.contentHash else { return .unchanged }

        let previousByPosition = Dictionary(
            previous.tasks.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first }
        )
        let currentByPosition = Dictionary(
            current.tasks.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first }
        )
        guard previousByPosition.count == previous.tasks.count,
              currentByPosition.count == current.tasks.count,
              Set(previousByPosition.keys) == Set(currentByPosition.keys),
              previous.headings.map(\.text) == current.headings.map(\.text) else {
            return .structureChanged
        }

        var flipped: [String] = []
        for (key, previousTask) in previousByPosition {
            guard let currentTask = currentByPosition[key] else { return .structureChanged }
            if previousTask.checkbox.mark != currentTask.checkbox.mark {
                flipped.append(currentTask.id)
            }
        }
        // Same tasks, same headings, and only marks differ.
        guard !flipped.isEmpty else { return .structureChanged }
        return .checkboxesChanged(taskIDs: flipped.sorted())
    }

    /// Identity for comparing two scans: text and place, not the raw block —
    /// the block's hash changes with the checkbox itself.
    private func key(for task: ProjectTask) -> String {
        [
            task.headingPath.joined(separator: "\u{1}"),
            String(task.orderUnderHeading),
            task.fingerprint.normalizedText,
        ].joined(separator: "\u{2}")
    }

    /// A document whose content matches a source we knew at another path, and
    /// that path is now gone: the file was moved or renamed.
    private func movedSource(
        for document: TaskDocument,
        excluding present: Set<String>
    ) -> String? {
        for source in sources where !present.contains(source.path) {
            guard source.contentHash == document.contentHash else { continue }
            return source.path
        }
        return nil
    }
}

/// Watches task sources and asks the store to refresh.
///
/// Two mechanisms on purpose: filesystem events for immediacy, and a slow poll
/// as the backstop. An editor or agent that replaces a file atomically swaps the
/// inode, which kills a descriptor-based watch, so every event re-arms the watch
/// and the poll catches whatever slipped through.
@MainActor
final class TodoSourceWatcher {
    private var sources: [Int32: DispatchSourceFileSystemObject] = [:]
    private var watchedPaths: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// nil until the first stat pass: "no baseline yet" is not "nothing on disk".
    private var lastStamps: [String: TodoDiscovery.FileStamp]?
    private let onChange: () -> Void
    private let pollInterval: TimeInterval
    private let debounceInterval: TimeInterval

    init(
        pollInterval: TimeInterval = 5,
        debounceInterval: TimeInterval = 0.3,
        onChange: @escaping () -> Void
    ) {
        self.pollInterval = pollInterval
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        sources.values.forEach { $0.cancel() }
    }

    /// A save, an atomic replace and a re-arm all land within milliseconds of
    /// each other; without this the store would rescan three times for one edit.
    private func scheduleChange() {
        debounceTask?.cancel()
        let delay = debounceInterval
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            // The poll's baseline moves too, so a poll right after an event does
            // not fire a second, redundant rescan.
            self.lastStamps = await Self.stamps(for: self.watchedPaths)
            self.onChange()
        }
    }

    /// Stats the watched paths off the main actor. Cheap enough to run every
    /// poll tick, unlike the walk-and-parse it guards.
    private static func stamps(for paths: Set<String>) async -> [String: TodoDiscovery.FileStamp] {
        await Task.detached(priority: .utility) {
            var result: [String: TodoDiscovery.FileStamp] = [:]
            for path in paths {
                result[path] = TodoDiscovery.stamp(atPath: path)
            }
            return result
        }.value
    }

    /// Watches the given files plus their directories, so a file that is
    /// replaced, renamed away, or created later is still noticed.
    func watch(paths: [String]) {
        let directories = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        let targets = Set(paths).union(directories)
        guard targets != watchedPaths else { return }
        stopWatching()
        watchedPaths = targets
        lastStamps = nil
        for path in targets {
            arm(path)
        }
    }

    func start(paths: [String]) {
        watch(paths: paths)
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let current = await Self.stamps(for: self.watchedPaths)
                guard !Task.isCancelled else { return }
                // The poll is only a backstop for events the descriptor watch
                // missed; without this gate it forced a full rescan on every
                // tick whether or not a byte had moved.
                let baseline = self.lastStamps
                self.lastStamps = current
                guard let baseline, baseline != current else { continue }
                self.onChange()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        stopWatching()
    }

    private func stopWatching() {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        watchedPaths = []
    }

    private func arm(_ path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            self.scheduleChange()
            // A replaced or renamed file needs a fresh descriptor.
            if data.contains(.delete) || data.contains(.rename) {
                source.cancel()
                self.sources[descriptor] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.watchedPaths.contains(path) else { return }
                    self.arm(path)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        sources[descriptor] = source
        source.resume()
    }
}
