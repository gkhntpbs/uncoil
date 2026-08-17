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

    /// First executable named `command` in the search path, or nil.
    ///
    /// Filesystem only — no shell is spawned, so this is cheap enough to call on
    /// every rescan. `SettingsStore.which` layers the login-shell fallback on
    /// top for the cases a fixed list cannot cover (asdf, mise, a hand-rolled
    /// PATH in `~/.zshrc`).
    static func locate(
        _ command: String,
        home: String,
        extraDirectories: [String] = [],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
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
}
