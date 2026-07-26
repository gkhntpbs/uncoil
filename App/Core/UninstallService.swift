import Foundation

/// What removing Uncoil takes with it — and what it must leave alone.
///
/// The rule that shapes this: Uncoil deletes what Uncoil created. A skill the
/// user wrote by hand, an MCP server they configured themselves, and an agent's
/// own config are none of Uncoil's business on the way out.
struct UninstallPlan: Equatable {
    struct Item: Equatable, Identifiable {
        enum Disposition: Equatable {
            /// Created by Uncoil; removed.
            case removed
            /// The user's own; left exactly where it is.
            case kept(reason: String)

            var isRemoved: Bool { self == .removed }
        }

        var path: String
        var detail: String
        var disposition: Disposition

        var id: String { path }
    }

    var items: [Item]

    var removals: [Item] { items.filter { $0.disposition.isRemoved } }
    var kept: [Item] { items.filter { !$0.disposition.isRemoved } }

    var summary: String {
        String(localized: "\(removals.count) items will be deleted, \(kept.count) kept")
    }
}

/// Builds and performs the uninstall.
struct UninstallService {
    var dataDirectory: URL
    var extensionLayout: ExtensionStoreLayout
    /// The agent skill directories Uncoil linked into.
    var agentSkillDirectories: [URL]
    /// Skills Uncoil owns, by name, so a hand-written folder next to them is not
    /// mistaken for one of ours.
    var managedSkillNames: Set<String>
    var homeDirectory: URL

    /// Everything the uninstall would do. Nothing is deleted here.
    func plan() -> UninstallPlan {
        var items: [UninstallPlan.Item] = []

        // Uncoil's own state.
        for name in ["projects.json", "sessions.json", "session-groups.json", "settings.json",
                     "presets.json", "permissions.json", "audit.jsonl", "task-patches.jsonl"] {
            let url = dataDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(.init(
                path: url.path, detail: "Uncoil verisi", disposition: .removed
            ))
        }
        for directory in ["projects", "transcripts", "todo-backups"] {
            let url = dataDirectory.appendingPathComponent(directory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(.init(
                path: url.path, detail: "Uncoil dizini", disposition: .removed
            ))
        }

        // The extension store: revisions and mirrors Uncoil fetched are ours; the
        // canonical skills directory holds copies the user may still want.
        for url in [extensionLayout.mirrors, extensionLayout.revisions,
                    extensionLayout.locks, extensionLayout.scans]
        where FileManager.default.fileExists(atPath: url.path) {
            items.append(.init(
                path: url.path, detail: "Extension store", disposition: .removed
            ))
        }

        // Links Uncoil made in agent directories go; anything else there stays.
        for directory in agentSkillDirectories {
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: directory.path).sorted() else { continue }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let isLink = (try? FileManager.default
                    .destinationOfSymbolicLink(atPath: url.path)) != nil
                if isLink, managedSkillNames.contains(name) {
                    items.append(.init(
                        path: url.path, detail: "Uncoil symlink'i", disposition: .removed
                    ))
                } else {
                    items.append(.init(
                        path: url.path,
                        detail: isLink ? "Someone else's symlink" : "Your own file",
                        disposition: .kept(reason: "Not created by Uncoil")
                    ))
                }
            }
        }

        // The shared lock file is Uncoil's own output, but the directory around it
        // is not.
        let skillLock = ExtensionLockFiles.defaultSkillLockURL(home: homeDirectory)
        if FileManager.default.fileExists(atPath: skillLock.path) {
            items.append(.init(
                path: skillLock.path, detail: "Uncoil lock file", disposition: .removed
            ))
        }

        // Agent configs are never touched: Uncoil's entries can be removed from
        // the Extensions screen before uninstalling, and doing it here would edit
        // a file the user shares with another tool.
        for name in [".claude.json", ".codex/config.toml", ".gemini/settings.json",
                     ".cursor/mcp.json", ".config/amp/settings.json"] {
            let url = homeDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(.init(
                path: url.path,
                detail: "Agent config",
                disposition: .kept(reason: "The agent's own file; Uncoil never deletes it")
            ))
        }

        return UninstallPlan(items: items)
    }

    /// Performs exactly what the plan says is removable, and reports what it did.
    @discardableResult
    func perform(_ plan: UninstallPlan) -> (removed: [String], failed: [String]) {
        var removed: [String] = []
        var failed: [String] = []
        for item in plan.removals {
            do {
                try FileManager.default.removeItem(atPath: item.path)
                removed.append(item.path)
            } catch {
                failed.append(item.path)
            }
        }
        return (removed, failed)
    }
}

/// Crash reporting, off until the user turns it on.
///
/// There is no server: enabling this writes crash information into Uncoil's own
/// debug bundle so the user can attach it to a report themselves. Nothing leaves
/// the machine either way, which is the only claim worth making.
struct CrashReportingPolicy: Equatable, Codable {
    /// Off by default. An opt-out default would make the promise above untrue.
    var isEnabled = false
    /// Where local crash information is collected when enabled.
    var collectsSystemCrashLogs = true

    static let `default` = CrashReportingPolicy()

    var summary: String {
        isEnabled
            ? String(localized: "On — crash details are written only to the local debug bundle.")
            : String(localized: "Off — no crash information is collected.")
    }

    /// The one thing Uncoil promises about data leaving the machine.
    static let networkStatement =
        "Uncoil sends no telemetry or crash report over the network."

    /// Paths a debug bundle collects when reporting is on.
    func crashLogPaths(home: URL) -> [String] {
        guard isEnabled, collectsSystemCrashLogs else { return [] }
        let directory = home.appendingPathComponent(
            "Library/Logs/DiagnosticReports", isDirectory: true
        )
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("Uncoil") }
            .sorted()
            .suffix(5)
            .map { directory.appendingPathComponent($0).path }
    }
}
