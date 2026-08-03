import Foundation

/// Why a session's process stopped.
///
/// Nothing used to ask. Every exit went down the same path — status
/// `.terminated`, `endedAt` stamped, the row goes quiet — so an agent that
/// crashed mid-task looked exactly like one the user had closed on purpose,
/// and a crash in a session that was not on screen was silent.
///
/// Pure so the classification is a test rather than a thing to reproduce: a
/// crash is hard to stage on demand, and getting this wrong in either
/// direction is bad — crying crash at every clean exit teaches people to
/// ignore it, missing a real one is the bug being fixed.
enum SessionExit: Equatable {
    /// The process ended the way it was asked to, or the user closed it.
    case clean
    /// The app lost the process rather than watched it exit: the runtime
    /// daemon went away, or the user closed the session and no code was
    /// recorded. Not a crash — Uncoil simply does not know.
    case unknown
    /// Ended on its own, badly.
    case crashed(code: Int32)

    var isCrash: Bool {
        if case .crashed = self { return true }
        return false
    }

    /// Exit codes above this are the shell's way of reporting a signal:
    /// 128 + signal number, so 139 is SIGSEGV and 137 is SIGKILL.
    static let signalBase: Int32 = 128

    /// Classifies an exit.
    ///
    /// `isAgent` gates the whole thing. A shell that exits non-zero has simply
    /// run a command that failed and then been closed; that is not a crash and
    /// saying so on every `exit 1` would be noise.
    static func classify(exitCode: Int32?, isAgent: Bool) -> SessionExit {
        guard let exitCode else { return .unknown }
        guard isAgent else { return .clean }
        return exitCode == 0 ? .clean : .crashed(code: exitCode)
    }

    /// What to tell the user, in the terms the exit was reported in.
    var reason: String? {
        guard case .crashed(let code) = self else { return nil }
        if code > Self.signalBase {
            return String(localized: "killed by signal \(code - Self.signalBase)")
        }
        return String(localized: "exit code \(code)")
    }
}
