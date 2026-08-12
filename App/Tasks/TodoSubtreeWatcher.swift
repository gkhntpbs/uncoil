import Foundation
import CoreServices

/// Notices a task file appearing anywhere under a project.
///
/// The per-file watch can only watch files that already exist, and watching
/// every directory in a project would mean thousands of descriptors kept open
/// for a file that may never be written. FSEvents is the mechanism built for
/// this question: one stream, the whole subtree, and the kernel already knows
/// the answer.
///
/// It is deliberately narrow about what counts. A build writes thousands of
/// files a second, and a task list that rescanned on every one of them would
/// cost more than the feature is worth — so an event only counts when it names
/// a task file, or when a directory was created, renamed or removed (which is
/// how a folder with a `TODO.md` already inside it arrives), and never when it
/// happened inside a dependency tree or a build cache.
final class TodoSubtreeWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(
        label: "com.gokhantopbas.uncoil.todo-subtree", qos: .utility
    )
    private let latency: TimeInterval
    private let isTaskFile: (String) -> Bool
    private let onChange: () -> Void

    /// - Parameters:
    ///   - latency: how long FSEvents may batch events before delivering them.
    ///   - onChange: called on the main queue, already coalesced by `latency`.
    init(
        latency: TimeInterval = 1.0,
        isTaskFile: @escaping (String) -> Bool = { TodoDiscovery.Rules.default.isTaskFile(named: $0) },
        onChange: @escaping () -> Void
    ) {
        self.latency = latency
        self.isTaskFile = isTaskFile
        self.onChange = onChange
    }

    deinit {
        teardown()
    }

    func start(root: String) {
        stop()
        // FSEvents reports real paths and watches real directories: handed a
        // symlink it delivers nothing at all, silently. `/var` → `/private/var`
        // is the case that matters — every temporary directory on macOS.
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TodoSubtreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for index in 0..<min(count, paths.count) {
                events.append((paths[index], rawFlags[index]))
            }
            watcher.handle(events)
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            // `UseCFTypes` is not optional: without it the callback is handed a
            // C array of `char *` rather than a `CFArray`, and reading it as
            // one crashes the process on the first event.
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard events.contains(where: { Self.isInteresting(path: $0.path, flags: $0.flags) }) else {
            return
        }
        DispatchQueue.main.async { [onChange] in onChange() }
    }

    /// Whether one event is worth a rescan. Static and pure so the rule can be
    /// tested without a filesystem.
    static func isInteresting(
        path: String,
        flags: FSEventStreamEventFlags,
        isTaskFile: (String) -> Bool = { TodoDiscovery.Rules.default.isTaskFile(named: $0) }
    ) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        // A dependency tree or a build cache is never scanned, so nothing that
        // happens inside one can change what the project's tasks are.
        if components.dropLast().contains(where: TodoDiscovery.defaultExcludedDirectories.contains) {
            return false
        }
        guard let name = components.last else { return false }
        if isTaskFile(name) { return true }
        // A directory that appeared, moved or went away may have brought a task
        // file with it — the event names the directory, not what is inside it.
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard isDirectory else { return false }
        let structural = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemRemoved
        )
        return flags & structural != 0
    }
}
