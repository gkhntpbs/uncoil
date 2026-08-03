import Foundation

/// Which window a session is open in.
///
/// A session can only be in one window at a time, and that is not a house
/// rule — it is what the machinery already does. `TerminalRegistry` vends one
/// `TerminalView` per session, an `NSView` has exactly one superview, and a
/// second window that mounts the same terminal takes it out of the first
/// silently, mid-render. The choice is not whether sessions are exclusive; it
/// is whether the app says so or lets the user discover it as a bug.
///
/// So ownership is written down, and the window that does not hold a session
/// says so instead of showing an empty frame where a terminal used to be.
///
/// Pure and value-typed on purpose: every rule that can be got wrong — who
/// wins a contested claim, what happens when a window closes, what happens to
/// a session that is deleted while a window holds it — is decided here, where
/// it can be tested without a window on screen.
struct SessionOwnership: Equatable {
    /// session → the window holding it. Absent means free.
    private(set) var holders: [UUID: UUID] = [:]

    init(holders: [UUID: UUID] = [:]) {
        self.holders = holders
    }

    /// What happened, or would happen, when a window asks for a session.
    enum Claim: Equatable {
        /// The session was free and is now this window's.
        case granted
        /// This window already held it — asking again changes nothing.
        case alreadyHeld
        /// Another window holds it. The overlay names that window.
        case heldElsewhere(UUID)
    }

    func holder(of session: UUID) -> UUID? { holders[session] }

    func sessions(heldBy window: UUID) -> Set<UUID> {
        Set(holders.filter { $0.value == window }.map(\.key))
    }

    /// The answer without the side effect, for a view that has to decide what
    /// to draw without changing anything while it draws it.
    func outcome(claiming session: UUID, by window: UUID) -> Claim {
        switch holders[session] {
        case .none: .granted
        case .some(window): .alreadyHeld
        case .some(let other): .heldElsewhere(other)
        }
    }

    /// Takes a free session. A session another window holds is left alone:
    /// merely selecting a row must never pull a running terminal out from
    /// under someone, which is the whole reason any of this exists.
    @discardableResult
    mutating func claim(_ session: UUID, by window: UUID) -> Claim {
        let outcome = outcome(claiming: session, by: window)
        if outcome == .granted { holders[session] = window }
        return outcome
    }

    /// Moves a session to a window whatever its current state — the one thing
    /// that answers "Move Here", and the only way ownership ever changes
    /// hands. Deliberately separate from `claim` so a transfer can never
    /// happen by accident: it takes a second function name to write one.
    mutating func take(_ session: UUID, by window: UUID) {
        holders[session] = window
    }

    /// Gives a session up, but only if this window is the one holding it. A
    /// window that lost a session to `take` still runs its own teardown
    /// afterwards, and that teardown must not evict the new owner.
    mutating func release(_ session: UUID, from window: UUID) {
        guard holders[session] == window else { return }
        holders[session] = nil
    }

    /// A closing window frees everything it held, or those sessions would be
    /// unreachable from anywhere for the rest of the run.
    mutating func releaseAll(of window: UUID) {
        holders = holders.filter { $0.value != window }
    }

    /// A deleted session is nobody's.
    mutating func forget(_ session: UUID) {
        holders[session] = nil
    }

    /// Drops claims that no longer refer to anything — sessions that were
    /// deleted, windows that are gone. Restored state is the case that needs
    /// it: a claim held by a window that never came back would keep a session
    /// locked with no window to reveal, and no way out of the overlay.
    mutating func prune(sessions: Set<UUID>, windows: Set<UUID>) {
        holders = holders.filter { sessions.contains($0.key) && windows.contains($0.value) }
    }
}
