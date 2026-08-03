import Foundation

/// A main window, written down so it can come back.
///
/// Sessions already outlive the app — the runtime daemon owns the processes —
/// so a relaunch that dropped someone back to a single window would not lose
/// their work, only the arrangement of it. That arrangement is the thing
/// multi-window is *for*: two projects side by side, an agent in one window
/// and its diff in another. Rebuilding it by hand every morning would undo
/// most of the point.
struct PersistedWindow: Codable, Equatable, Identifiable {
    var id: UUID
    /// `""` when the window was showing nothing.
    var selectionKind: String
    var selectionID: String
    /// Absent in files written before windows had project lists of their own,
    /// and read as "everything" — which is what those windows were showing.
    var projects: WindowProjects?

    init(id: UUID, selection: MainSelection?, projects: WindowProjects = .all) {
        self.id = id
        let coded = SelectionCoding.encode(selection)
        selectionKind = coded.kind
        selectionID = coded.id
        self.projects = projects
    }
}

/// Which projects a window shows.
///
/// A clean window has to be clean, and a window listing every project in the
/// sidebar is not — the list is the first thing you look at. So the project
/// list belongs to the window rather than to the app: open a project in one
/// window and it is in *that* window, the way a workspace works.
///
/// `.all` is not the same as `.some` of everything, and the difference is
/// projects added later. A window that was never asked the question shows
/// whatever exists, then and afterwards; that is what every window did before
/// this, and what the first window still does. Collapsing the two would mean
/// the original window quietly stopped picking up new projects.
enum WindowProjects: Codable, Equatable {
    case all
    case some(Set<UUID>)

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .all: true
        case .some(let ids): ids.contains(id)
        }
    }

    /// Opening a project in a window puts it in that window. `.all` already
    /// has it, and must stay `.all` — pinning it to a fixed set here is how a
    /// window would stop seeing anything added afterwards.
    func adding(_ id: UUID) -> WindowProjects {
        switch self {
        case .all: .all
        case .some(let ids): .some(ids.union([id]))
        }
    }

    func removing(_ id: UUID) -> WindowProjects {
        switch self {
        case .all: .all
        case .some(let ids): .some(ids.subtracting([id]))
        }
    }

    /// Order is the store's, never the set's: the sidebar's sort is pinning,
    /// manual order and Scratch last, and a `Set` has no order to offer.
    func filter(_ projects: [Project]) -> [Project] {
        switch self {
        case .all: projects
        case .some(let ids): projects.filter { ids.contains($0.id) }
        }
    }
}

/// `MainSelection` as two strings.
///
/// The same two strings the single-window build already wrote into
/// `UserDefaults`, kept deliberately: the first launch after this change
/// reads the old keys and hands them to the first window, so nobody's
/// selection is thrown away by the upgrade that made windows plural.
enum SelectionCoding {
    static func encode(_ selection: MainSelection?) -> (kind: String, id: String) {
        switch selection {
        case .project(let id): ("project", id.uuidString)
        case .group(let id): ("group", id.uuidString)
        case .session(let id): ("session", id.uuidString)
        case nil: ("", "")
        }
    }

    static func decode(kind: String, id: String) -> MainSelection? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        switch kind {
        case "project": return .project(uuid)
        case "group": return .group(uuid)
        case "session": return .session(uuid)
        default: return nil
        }
    }
}

/// Why a window is opening, which decides whether it asks anything.
///
/// The overlay is a question, and a question is only worth asking when the
/// answer is not already known. At launch it is known — the windows are
/// coming back as they were — and for the very first window there is nothing
/// to clone. Asking in either case would put a modal panel between the user
/// and an app they just opened, every single time.
enum WindowOpening {
    enum Mode: Equatable {
        /// Restored from the last run; takes the saved selection, asks nothing.
        case restored(PersistedWindow)
        /// The only window there is. Nothing to copy, so nothing to ask.
        case first
        /// Opened by hand while other windows are up: this one asks.
        case asks
    }

    static func mode(restoreQueue: [PersistedWindow], openCount: Int) -> Mode {
        if let next = restoreQueue.first { return .restored(next) }
        return openCount == 0 ? .first : .asks
    }
}

/// Which window answers "show me this".
///
/// With one window the question never came up. With several, a request from
/// the menu bar, a notification or the command palette has to land somewhere,
/// and landing it in every window at once — which is what a broadcast does —
/// would make one click rearrange the user's whole desktop.
enum SessionRouting {
    /// A session already open somewhere goes to the window that has it, in
    /// preference to anything else. Sending it to the key window instead would
    /// answer "take me to my agent" with "this session is open in another
    /// window", which is the app refusing its own shortcut.
    ///
    /// Otherwise the key window, because that is where the user is looking,
    /// and the main window when Uncoil is not frontmost at all — the menu-bar
    /// monitor is used precisely when it is not.
    static func target(
        for selection: MainSelection,
        holder: UUID?,
        key: UUID?,
        main: UUID?
    ) -> UUID? {
        if case .session = selection, let holder { return holder }
        return key ?? main
    }
}

/// An open window, as the "new window" overlay needs to describe it.
struct WindowSummary: Equatable, Identifiable {
    var id: UUID
    /// What the window is showing — a project name, usually.
    var title: String
    /// The oldest window still open. There is nothing special about it beyond
    /// that, but "the main window" is what people call the one they started in.
    var isMain: Bool
}

/// What a newly opened window should do.
enum NewWindowChoice: Hashable {
    case clone(UUID)
    case empty
}

struct NewWindowOption: Identifiable, Equatable {
    var choice: NewWindowChoice
    var title: String
    var detail: String

    var id: NewWindowChoice { choice }
}

enum NewWindowOptions {
    /// The main window first, then the others in the order they were opened,
    /// then the empty window last — the offers run from "most like what you
    /// already have" to "nothing at all", because someone opening a second
    /// window usually wants a variation on the first.
    static func options(windows: [WindowSummary]) -> [NewWindowOption] {
        let ordered = windows.sorted { lhs, rhs in
            lhs.isMain && !rhs.isMain
        }
        var options = ordered.map { window in
            NewWindowOption(
                choice: .clone(window.id),
                title: window.isMain
                    ? String(localized: "Clone Main Window")
                    : String(localized: "Clone “\(window.title)” Window"),
                detail: window.isMain
                    ? String(localized: "Opens on the same project and view as the main window.")
                    : String(localized: "Opens on the same project and view as that window.")
            )
        }
        options.append(
            NewWindowOption(
                choice: .empty,
                title: String(localized: "New Empty Window"),
                detail: String(localized: "Opens with nothing selected.")
            )
        )
        return options
    }

    /// What a clone actually starts on.
    ///
    /// Not the source's selection verbatim, because a session cannot be in two
    /// windows and a clone that opened straight onto "this session is open in
    /// another window" would be a window that arrives broken. A session
    /// collapses to the project it belongs to — which is what someone cloning
    /// a window is nearly always after anyway: the same project, room for a
    /// second thing in it. Projects and groups are not exclusive and are
    /// copied as they are.
    static func clonedSelection(
        from selection: MainSelection?,
        projectOfSession: (UUID) -> UUID?
    ) -> MainSelection? {
        switch selection {
        case .session(let id):
            return projectOfSession(id).map { MainSelection.project($0) }
        case .project, .group, nil:
            return selection
        }
    }
}
