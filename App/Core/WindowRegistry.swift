import AppKit
import Combine
import Foundation

/// The open main windows, and who holds what.
///
/// SwiftUI's `WindowGroup` will make as many windows as it is asked for, but
/// it gives none of them an identity: every instance of `MainWindow` is the
/// same view, reading the same `@AppStorage`, so two windows shared one
/// selection and fought over it. This is where a window becomes a thing with a
/// name — an id it keeps for its whole life, a selection of its own, and a
/// place in what gets written down for next time.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    /// Open windows, oldest first. Order is what makes one of them "main".
    @Published private(set) var order: [UUID] = []
    @Published private(set) var selections: [UUID: MainSelection?] = [:]
    @Published private(set) var ownership = SessionOwnership()

    /// Windows waiting to come back from the last run, consumed one per
    /// `MainWindow` that appears.
    private var restoreQueue: [PersistedWindow] = []
    private var windows: [UUID: NSWindow] = [:]
    /// popout window id → the session it shows.
    @Published private(set) var popoutSessions: [UUID: UUID] = [:]
    private let directory: URL
    private let fileName = "windows.json"

    private var didPrepareRestore = false
    /// Windows closing because the app is quitting must not rewrite the file.
    ///
    /// Quitting tears every window down one at a time, and each teardown looks
    /// exactly like "the user closed this window" — so the saved arrangement
    /// would shrink window by window and the last one out would record a
    /// single-window app. Which is precisely the state this feature exists to
    /// stop someone rebuilding by hand every morning.
    private var terminating = false

    init(directory: URL = ProjectStore.defaultDirectory()) {
        self.directory = directory
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminating = true }
        }
    }

    var mainWindowID: UUID? { order.first }

    // MARK: - Restore

    /// How many *extra* windows to open, beyond the one SwiftUI opens on its
    /// own. Called once, by whichever window appears first.
    func prepareRestore() -> Int {
        guard !didPrepareRestore else { return 0 }
        didPrepareRestore = true
        return max(0, loadRestoreQueue() - 1)
    }

    /// How many windows to put back at launch, including the one SwiftUI opens
    /// on its own. Zero saved windows still means one window: an app that
    /// opened with no window at all would look like it failed to start.
    func loadRestoreQueue() -> Int {
        guard !LaunchConfig.shared.isUITesting else { return 1 }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([PersistedWindow].self, from: data),
              !saved.isEmpty
        else {
            restoreQueue = [legacyWindow()]
            return 1
        }
        restoreQueue = saved
        return saved.count
    }

    /// The single-window build's selection, so the upgrade does not land
    /// someone on an empty window with no explanation.
    private func legacyWindow() -> PersistedWindow {
        let defaults = UserDefaults.standard
        return PersistedWindow(
            id: UUID(),
            selection: SelectionCoding.decode(
                kind: defaults.string(forKey: "mainSelectionKind") ?? "",
                id: defaults.string(forKey: "mainSelectionID") ?? ""
            )
        )
    }

    // MARK: - Lifecycle

    /// Called once by each `MainWindow` as it appears. Returns the identity it
    /// keeps and how it should start.
    func register() -> (id: UUID, mode: WindowOpening.Mode) {
        let mode = WindowOpening.mode(restoreQueue: restoreQueue, openCount: order.count)
        let id: UUID
        switch mode {
        case .restored(let saved):
            restoreQueue.removeFirst()
            id = saved.id
        case .first, .asks:
            id = UUID()
        }
        order.append(id)
        selections[id] = MainSelection?.none
        return (id, mode)
    }

    func unregister(_ id: UUID) {
        order.removeAll { $0 == id }
        selections[id] = nil
        windows[id] = nil
        ownership.releaseAll(of: id)
        save()
    }

    // MARK: - Popouts

    /// A dragged-out terminal is a window too.
    ///
    /// It shows a session, so it has to be able to hold one, or the same
    /// terminal would be mounted in two places and the ownership rule would
    /// have an exception exactly where the `NSView` problem is worst. It is
    /// kept out of `order` because it is not a main window: it is never
    /// cloned, never counted at launch, and never written down.
    ///
    /// Dragging a session out takes it rather than asking for it. Someone who
    /// pulled a terminal into its own window meant to, and answering that with
    /// "this session is open in another window" would refuse the very thing
    /// they just did.
    func registerPopout(sessionID: UUID) -> UUID {
        let id = UUID()
        popoutSessions[id] = sessionID
        ownership.take(sessionID, by: id)
        return id
    }

    func unregisterPopout(_ id: UUID) {
        popoutSessions[id] = nil
        windows[id] = nil
        ownership.releaseAll(of: id)
    }

    func setSelection(_ selection: MainSelection?, for id: UUID) {
        guard order.contains(id) else { return }
        selections[id] = selection
        save()
    }

    func selection(of id: UUID) -> MainSelection? {
        selections[id] ?? nil
    }

    // MARK: - Ownership

    @discardableResult
    func claim(_ session: UUID, by window: UUID) -> SessionOwnership.Claim {
        ownership.claim(session, by: window)
    }

    func take(_ session: UUID, by window: UUID) {
        ownership.take(session, by: window)
    }

    func release(_ session: UUID, from window: UUID) {
        ownership.release(session, from: window)
    }

    func forget(sessions: Set<UUID>) {
        for session in sessions { ownership.forget(session) }
    }

    /// Drops claims on sessions that no longer exist. A deleted session whose
    /// claim outlived it would lock its id forever — and ids are not reused,
    /// so nothing would ever notice.
    func pruneOwnership(sessions: Set<UUID>) {
        ownership.prune(
            sessions: sessions,
            windows: Set(order).union(popoutSessions.keys)
        )
    }

    // MARK: - Windows on screen

    /// The window the user is looking at, when it is one of ours.
    @Published private(set) var keyWindowID: UUID?

    /// The `NSWindow` behind an id, so "Reveal" has something to raise.
    func bind(_ window: NSWindow, to id: UUID) {
        windows[id] = window
        if window.isKeyWindow { keyWindowID = id }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyWindowID = id }
        }
    }

    func windowID(for window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { $0.value === window }?.key
    }

    /// Where a "show me this" request should land.
    func routeTarget(for selection: MainSelection) -> UUID? {
        var holder: UUID?
        if case .session(let id) = selection { holder = ownership.holder(of: id) }
        return SessionRouting.target(
            for: selection,
            holder: holder,
            key: keyWindowID.flatMap { order.contains($0) ? $0 : nil },
            main: mainWindowID
        )
    }

    func reveal(_ id: UUID) {
        guard let window = windows[id] else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Everything except the window doing the asking — a window is never
    /// offered a clone of itself, since it has not decided anything yet.
    func summaries(excluding id: UUID, projectStore: ProjectStore) -> [WindowSummary] {
        order.compactMap { windowID in
            guard windowID != id else { return nil }
            return WindowSummary(
                id: windowID,
                title: title(of: windowID, projectStore: projectStore),
                isMain: windowID == mainWindowID
            )
        }
    }

    func title(of id: UUID, projectStore: ProjectStore) -> String {
        if let sessionID = popoutSessions[id] {
            let title = projectStore.sessions.first { $0.id == sessionID }?.displayTitle
                ?? String(localized: "Untitled")
            return String(localized: "\(title) (popped out)")
        }
        switch selection(of: id) {
        case .project(let projectID):
            return projectStore.projects.first { $0.id == projectID }?.name
                ?? String(localized: "Untitled")
        case .group(let groupID):
            return projectStore.sessionGroups.first { $0.id == groupID }?.name
                ?? String(localized: "Untitled")
        case .session(let sessionID):
            return projectStore.sessions.first { $0.id == sessionID }?.displayTitle
                ?? String(localized: "Untitled")
        case nil:
            return String(localized: "Empty")
        }
    }

    // MARK: - Persistence

    private func save() {
        guard !LaunchConfig.shared.isUITesting, !terminating else { return }
        let saved = order.map { PersistedWindow(id: $0, selection: selection(of: $0)) }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}
