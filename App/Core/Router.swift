import Foundation

/// Somewhere the user can be sent.
///
/// This is the list that did not exist: each destination outside
/// project/group/session had grown its own singleton — a settings pane was a
/// `String` on `SettingsRoute`, an Extensions screen an enum on
/// `ExtensionsCommandBus`, a project tab a `String` in a per-project dictionary
/// on `ProjectAreaRoute`, a handoff sheet a `UUID` on `HandoffRoute`, onboarding
/// a `Bool` on `OnboardingPresenter`, and cross-window session focus a selection
/// plus a counter on `MainRoute`, declared inside the menu-bar view's file.
/// Six objects, no two the same shape, and nothing that could answer "where can
/// the user go".
enum Destination: Equatable {
    /// A project, optionally on one of its areas.
    case project(UUID, area: ProjectArea? = nil)
    case group(UUID)
    case session(UUID)
    /// A settings pane, by its `SettingsView.Pane` raw value. `nil` opens
    /// Settings wherever it was.
    case settings(pane: String?)
    case extensions(section: ExtensionsView.Section? = nil, action: ExtensionsQuickAction? = nil)
    /// The handoff sheet for a session, which the session's own header owns.
    case handoff(sessionID: UUID)
    case onboarding
}

/// Something the Extensions menu can ask the Extensions window to run.
///
/// The window owns the registry and the scan coordinator, so a menu item cannot
/// act on them directly; it leaves the request here and the window picks it up
/// when it appears — which is also what makes a quick action work whether or
/// not the window was open when it was chosen.
enum ExtensionsQuickAction: String, Identifiable, Equatable {
    case rediscover
    case healthCheck
    case bumblebeeScan

    var id: String { rawValue }
}

/// Where the user is being sent, and where they are.
///
/// One object rather than six singletons. Each destination still keeps the
/// shape its consumer needs — a pending area belongs to a project, a pending
/// handoff to a session, and both are taken by the view that owns the thing —
/// but there is now one place that says what the destinations are, and one
/// `go(to:)` for reaching them.
///
/// Requests are one-shot: the view that answers a request clears it, so a
/// window opened later does not replay it.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    /// Not private: the tests build their own, so one test's pending request
    /// cannot leak into the next.
    init() {}

    // MARK: - Shell selection

    /// What a window has been asked to select. Every window hears it; the one
    /// that owns the target answers, or a single click in the menu bar would
    /// rearrange the whole desktop.
    @Published private(set) var requestedSelection: MainSelection?
    /// Bumped alongside a request so asking for the same target twice still
    /// reaches the window.
    @Published private(set) var selectionCounter = 0
    /// What the main window currently shows. Read by the notification policy,
    /// so "stay quiet about the session I am looking at" has something to
    /// compare against.
    @Published var currentSelection: MainSelection?

    func takeSelection() -> MainSelection? {
        defer { requestedSelection = nil }
        return requestedSelection
    }

    // MARK: - Project areas

    /// The area each project has been asked to open on. Per project rather
    /// than one pending request: two projects can each be waiting for one, and
    /// whichever screen appears first should not consume the other's.
    @Published private(set) var pendingAreas: [UUID: ProjectArea] = [:]

    func takeArea(for projectID: UUID) -> ProjectArea? {
        pendingAreas.removeValue(forKey: projectID)
    }

    // MARK: - Settings

    /// A settings pane, by raw value, waiting for the Settings window.
    @Published private(set) var requestedPane: String?

    func takePane() -> String? {
        defer { requestedPane = nil }
        return requestedPane
    }

    // MARK: - Extensions

    /// The screen the Extensions window should open on. One-shot, like the
    /// rest: the window clears it once it has moved, so reopening the window
    /// later lands where the user left it rather than being dragged back.
    @Published var extensionsSection: ExtensionsView.Section?
    /// A one-shot action, cleared by the window once it has run it.
    @Published var extensionsAction: ExtensionsQuickAction?

    // MARK: - Handoff

    @Published private(set) var requestedHandoffSessionID: UUID?
    /// Bumped alongside the request, for the same reason as the selection's.
    @Published private(set) var handoffCounter = 0

    /// Answered by the session that was asked for, and by nobody else.
    func takeHandoff(for sessionID: UUID) -> Bool {
        guard requestedHandoffSessionID == sessionID else { return false }
        requestedHandoffSessionID = nil
        return true
    }

    // MARK: - Onboarding

    /// Onboarding is not a second window: it covers the main one completely,
    /// and the app appears underneath only once setup is finished or skipped.
    /// Two windows meant the user could click the half-configured app behind
    /// the setup screen, which is the state the flow exists to get them out of.
    @Published private(set) var isPresentingOnboarding = false

    func dismissOnboarding() { isPresentingOnboarding = false }

    // MARK: - Going somewhere

    func go(to destination: Destination) {
        switch destination {
        case .project(let id, let area):
            if let area { pendingAreas[id] = area }
            request(selection: .project(id))
        case .group(let id):
            request(selection: .group(id))
        case .session(let id):
            request(selection: .session(id))
        case .settings(let pane):
            requestedPane = pane
        case .extensions(let section, let action):
            if let section { extensionsSection = section }
            if let action { extensionsAction = action }
        case .handoff(let sessionID):
            requestedHandoffSessionID = sessionID
            handoffCounter += 1
        case .onboarding:
            isPresentingOnboarding = true
        }
    }

    private func request(selection: MainSelection) {
        requestedSelection = selection
        selectionCounter += 1
    }
}
