import Foundation

/// Installs Uncoil's event hooks into `~/.claude/settings.json`.
///
/// Safety contract (never violated):
/// - a timestamped backup is written before every modification
/// - only entries whose command references the Uncoil helper are touched;
///   the user's own hooks are preserved byte-for-byte at the JSON level
/// - the result is re-parsed before an atomic write
enum HookInstaller {
    static let managedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "Stop", "SessionEnd",
    ]

    /// Marker that identifies entries owned by Uncoil.
    static let helperName = "uncoil-hook"

    enum Status: Equatable {
        case installed
        case notInstalled
        case partiallyInstalled(missing: [String])
    }

    enum InstallerError: LocalizedError {
        case helperMissing
        case invalidSettingsJSON
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                "The uncoil-hook helper was not found in the app bundle."
            case .invalidSettingsJSON:
                "~/.claude/settings.json is not valid JSON — the hook cannot be installed until it is fixed by hand."
            case .writeFailed(let detail):
                "settings.json could not be written: \(detail)"
            }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var helperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(helperName)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var socketPath: String {
        ProjectStore.defaultDirectory().appendingPathComponent("hook.sock").path
    }

    private static var backupDirectory: URL {
        ProjectStore.defaultDirectory().appendingPathComponent("config-backups", isDirectory: true)
    }

    // MARK: - Public operations

    static func install() throws {
        guard let helper = helperURL else { throw InstallerError.helperMissing }
        var root = try loadSettings()
        try backupCurrentSettings()

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(helperPath: helper.path)

        for event in managedEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isUncoilEntry($0) }
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": command]]
            ]
            // Tool events require a matcher; "*" matches every tool.
            if event == "PreToolUse" || event == "PostToolUse" {
                entry["matcher"] = "*"
            }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try write(root)
    }

    static func uninstall() throws {
        var root = try loadSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        try backupCurrentSettings()

        for event in managedEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { isUncoilEntry($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try write(root)
    }

    /// Installed Uncoil commands that do not invoke `helperPath` — the app was
    /// rebuilt elsewhere, moved, or its old DerivedData bundle was deleted.
    /// Pure (takes the parsed settings root) so it is directly testable.
    static func staleCommands(in root: [String: Any], helperPath: String) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        let expected = command(helperPath: helperPath)
        return managedEvents.flatMap { event -> [String] in
            let entries = hooks[event] as? [[String: Any]] ?? []
            return entries.flatMap { entry -> [String] in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.compactMap { hook in
                    guard let command = hook["command"] as? String,
                          command.contains(helperName),
                          command != expected else { return nil }
                    return command
                }
            }
        }
    }

    /// Re-points existing Uncoil entries at the running bundle's helper.
    /// Only rewrites commands that are already there — a stale path makes
    /// every Claude tool call log a hook failure, but a hook the user removed
    /// stays removed. Returns the number of rewritten commands.
    @discardableResult
    static func repairStalePaths() throws -> Int {
        guard let helper = helperURL else { return 0 }
        var root = try loadSettings()
        guard !staleCommands(in: root, helperPath: helper.path).isEmpty,
              var hooks = root["hooks"] as? [String: Any] else { return 0 }
        try backupCurrentSettings()

        let expected = command(helperPath: helper.path)
        var repaired = 0
        for event in managedEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            for index in entries.indices {
                guard var inner = entries[index]["hooks"] as? [[String: Any]] else { continue }
                var changed = false
                for hookIndex in inner.indices {
                    guard let command = inner[hookIndex]["command"] as? String,
                          command.contains(helperName),
                          command != expected else { continue }
                    inner[hookIndex]["command"] = expected
                    changed = true
                    repaired += 1
                }
                if changed { entries[index]["hooks"] = inner }
            }
            hooks[event] = entries
        }
        guard repaired > 0 else { return 0 }
        root["hooks"] = hooks
        try write(root)
        return repaired
    }

    static func command(helperPath: String) -> String {
        "\"\(helperPath)\" \"\(socketPath)\""
    }

    static func status() -> Status {
        guard
            let root = try? loadSettings(),
            let hooks = root["hooks"] as? [String: Any]
        else { return .notInstalled }

        let missing = managedEvents.filter { event in
            let entries = hooks[event] as? [[String: Any]] ?? []
            return !entries.contains(where: isUncoilEntry)
        }
        if missing.isEmpty { return .installed }
        if missing.count == managedEvents.count { return .notInstalled }
        return .partiallyInstalled(missing: missing)
    }

    // MARK: - Internals

    private static func isUncoilEntry(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains(helperName) == true }
    }

    private static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.invalidSettingsJSON
        }
        return object
    }

    private static func backupCurrentSettings() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "claude-settings-\(formatter.string(from: .now)).json"
        try FileManager.default.copyItem(
            at: settingsURL,
            to: backupDirectory.appendingPathComponent(name)
        )
    }

    private static func write(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Validate before touching the user's file.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw InstallerError.invalidSettingsJSON
        }
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallerError.writeFailed(error.localizedDescription)
        }
    }
}
