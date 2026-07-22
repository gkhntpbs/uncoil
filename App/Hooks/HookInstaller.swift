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
                "uncoil-hook yardımcı aracı uygulama paketinde bulunamadı."
            case .invalidSettingsJSON:
                "~/.claude/settings.json geçerli JSON değil — elle düzeltilmeden hook kurulamaz."
            case .writeFailed(let detail):
                "settings.json yazılamadı: \(detail)"
            }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var helperURL: URL? {
        Bundle.main.url(forResource: helperName, withExtension: nil)
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
        let command = "\"\(helper.path)\" \"\(socketPath)\""

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
