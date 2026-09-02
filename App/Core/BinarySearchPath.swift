import Foundation

/// The one list of directories Uncoil looks in for an agent CLI.
///
/// There used to be three: `SettingsStore.which` searched six locations through
/// the login shell, `AgentAdapterSupport.locateBinary` searched a different six
/// without it, and each usage probe carried a third list of its own. They
/// disagreed — a CLI installed under `~/.volta/bin` was found by the Extensions
/// screen and not by session launch, and one under `~/.npm-global/bin` the other
/// way round. The same machine answered "installed?" differently depending on
/// which screen asked.
///
/// Being the single choke point is also why the user's own answer lives here.
/// A fixed list of eight directories cannot cover every way a CLI gets onto a
/// Mac — nix, pipx, mise, a company image, an install kept on an external disk —
/// and the honest fix is to let someone say "look here" once and have every
/// surface believe them. An override registered here reaches the Extensions
/// screen, session launch and the usage probes together, because they all end
/// up in `locate`.
///
/// Pure and `nonisolated` so the tests drive it directly, with `home` injected
/// rather than read from the process.
enum BinarySearchPath {
    /// Union of every location the old three lists knew about, in the order
    /// `SettingsStore.which` already used, with the directories only the other
    /// lists knew appended.
    ///
    /// The order is inherited rather than redesigned on purpose: `which`'s
    /// result is cached and persisted by `resolveBinaries()`, so promoting
    /// `~/.npm-global/bin` above Homebrew would silently re-resolve users onto
    /// an abandoned npm copy and *keep* them there — the cache only drops a
    /// path once it stops being executable.
    static func directories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
        ]
    }

    static func directories() -> [String] {
        directories(home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - User-chosen locations

    /// Locations the user pointed Uncoil at, keyed by command name.
    ///
    /// Held here rather than passed down from `SettingsStore` because the two
    /// callers cannot share an actor: the adapters run on the main actor and
    /// `SettingsStore.which` runs on a detached task. A locked box is what lets
    /// one answer serve both without either waiting on the other.
    private final class LocationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        var all: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        func replaceAll(with newValues: [String: String]) {
            lock.lock()
            values = newValues
            lock.unlock()
        }

        func value(for command: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[command]
        }
    }

    private static let box = LocationBox()

    /// Replaces every user-chosen location. Called by `SettingsStore` on load
    /// and after any change, so the search path and the settings never disagree.
    static func setUserLocations(_ locations: [String: String]) {
        box.replaceAll(with: locations)
    }

    static var userLocations: [String: String] { box.all }

    static func userLocation(for command: String) -> String? {
        box.value(for: command)
    }

    /// What a user-chosen path actually resolves to for `command`.
    ///
    /// The path is whatever they picked in the open panel, which is either the
    /// executable itself or a directory holding it — both are reasonable
    /// answers to "where is it", so both are accepted. `bin/` is tried inside a
    /// directory as well, because someone pointing at an install root rather
    /// than at its `bin` is the same mistake everybody makes once.
    ///
    /// Returns nil when nothing executable is there, which is the case the UI
    /// reports back instead of silently keeping a location that finds nothing.
    /// `isExecutable` is deliberately the last parameter, here and in `locate`:
    /// the existing call sites pass it as a trailing closure, and a probe added
    /// after it would silently take that closure's place — the call would still
    /// compile and start asking the real filesystem instead of the test's.
    static func resolveUserLocation(
        _ chosen: String,
        command: String,
        isDirectory: (String) -> Bool = {
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
            return exists && directory.boolValue
        },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let path = (chosen as NSString).expandingTildeInPath
        if isDirectory(path) {
            for candidate in ["\(path)/\(command)", "\(path)/bin/\(command)"]
            where isExecutable(candidate) {
                return candidate
            }
            // A directory is never itself the binary, whatever its permissions
            // say: every directory carries the executable bit.
            return nil
        }
        return isExecutable(path) ? path : nil
    }

    // MARK: - Lookup

    /// First executable named `command` in the search path, or nil.
    ///
    /// A user-chosen location wins over the fixed list: they were explicit, and
    /// an override that lost to whatever happened to be in `/usr/local/bin`
    /// would be a setting that appears to do nothing.
    ///
    /// It does *not* win over being reachable. An override pointing at an
    /// unmounted external disk falls through to the ordinary search rather than
    /// reporting the agent as gone — the alternative is that ejecting a drive
    /// makes an agent that is also installed normally disappear from every
    /// screen. `userLocationIsReachable` is what the UI asks to say so out loud.
    ///
    /// Filesystem only — no shell is spawned, so this is cheap enough to call on
    /// every rescan. `SettingsStore.which` layers the login-shell fallback on
    /// top for the cases neither a fixed list nor an override covers.
    static func locate(
        _ command: String,
        home: String,
        extraDirectories: [String] = [],
        userLocation: String? = nil,
        isDirectory: (String) -> Bool = {
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
            return exists && directory.boolValue
        },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let chosen = userLocation ?? box.value(for: command),
           let resolved = resolveUserLocation(
               chosen, command: command, isDirectory: isDirectory, isExecutable: isExecutable
           ) {
            return resolved
        }
        for directory in extraDirectories + directories(home: home) {
            let path = "\(directory)/\(command)"
            if isExecutable(path) { return path }
        }
        return nil
    }

    static func locate(_ command: String, extraDirectories: [String] = []) -> String? {
        locate(
            command,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            extraDirectories: extraDirectories
        )
    }

    /// Whether the location the user chose for `command` finds anything right
    /// now. False for a path that has gone away — an unmounted disk, a
    /// reinstall that moved — which is a thing worth telling them rather than
    /// quietly falling back.
    static func userLocationIsReachable(for command: String) -> Bool {
        guard let chosen = box.value(for: command) else { return true }
        return resolveUserLocation(chosen, command: command) != nil
    }
}
