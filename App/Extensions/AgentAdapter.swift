import CryptoKit
import Foundation

/// An agent's configuration as Uncoil read it, with the hash the write path
/// re-checks so a config edited outside Uncoil is never overwritten.
struct AgentConfiguration: Equatable {
    var installation: AgentInstallation
    var path: String
    /// Raw file text, kept verbatim so unknown keys and comments survive.
    var raw: String
    var hash: String
    var mcpServers: [MCPServerDefinition]
    /// Skills the agent can see right now, by directory name.
    var skillNames: [String]

    var exists: Bool { !raw.isEmpty }
}

/// A single requested change. Adapters translate these into concrete edits;
/// nothing is written until a plan is applied.
enum ConfigurationChange: Equatable {
    case addMCPServer(MCPServerDefinition)
    case removeMCPServer(name: String)
    case setMCPServerEnabled(name: String, isEnabled: Bool)
}

/// Something wrong with a config Uncoil read.
struct ConfigurationIssue: Identifiable, Equatable {
    enum Severity: String, Equatable {
        case warning
        case error
    }

    let id: String
    var severity: Severity
    var message: String
    var remedy: String?
}

enum ReloadOutcome: Equatable {
    /// Picked up without touching running agents.
    case reloaded
    /// Running processes keep the old config until they restart.
    case restartRequired(String)
    case unsupported(String)
}

enum AgentAdapterError: LocalizedError, Equatable {
    case configUnreadable(String)
    case configMalformed(String)
    case staleConfig(String)
    case unsupportedChange(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .configUnreadable(let path):
            "Agent config could not be read: \(path)"
        case .configMalformed(let detail):
            "Agent config is not in the expected shape: \(detail)"
        case .staleConfig(let path):
            "\(path) changed outside Uncoil; the plan has to be recalculated."
        case .unsupportedChange(let detail):
            "Unsupported change for this agent: \(detail)"
        case .writeFailed(let detail):
            "Agent config could not be written: \(detail)"
        }
    }
}

/// What every agent adapter must provide. Detection, reading and validation are
/// read-only; mutations always go through a plan → apply pair so the user sees
/// the diff first and a rollback is always possible.
@MainActor
protocol AgentAdapter {
    var agent: ExtensionAgentID { get }
    var capabilities: AgentProviderCapabilities { get }

    /// Installations found on disk. Empty when the agent is not installed.
    func detectInstallations() -> [AgentInstallation]

    func readConfiguration(_ installation: AgentInstallation) throws -> AgentConfiguration

    /// Read-only sanity pass — never mutates, so it is safe to run on load.
    func validate(_ configuration: AgentConfiguration) -> [ConfigurationIssue]

    /// Builds the diff and backup for `changes` without writing anything.
    func plan(
        _ changes: [ConfigurationChange],
        for configuration: AgentConfiguration
    ) throws -> ConfigurationTransaction

    /// Writes a planned transaction, refusing if the file changed since the
    /// plan was made.
    func apply(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction

    /// Restores the backup a transaction captured.
    func rollback(_ transaction: ConfigurationTransaction) throws -> ConfigurationTransaction

    func reload(_ installation: AgentInstallation) -> ReloadOutcome

    func skillsDirectory(for installation: AgentInstallation) -> URL?
    func mcpConfigLocation(for installation: AgentInstallation) -> URL?
}

// MARK: - Shared helpers

/// Text and file utilities every adapter needs. Pure and `nonisolated`, so the
/// tests drive them directly.
enum AgentAdapterSupport {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Line-oriented diff good enough to show a user what will change. Not a
    /// minimal edit script — it never claims to be one.
    static func diff(before: String, after: String, path: String) -> String {
        guard before != after else { return "" }
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let oldSet = Set(old)
        let newSet = Set(new)
        var lines = ["--- \(path)", "+++ \(path)"]
        for line in old where !newSet.contains(line) {
            lines.append("-\(line)")
        }
        for line in new where !oldSet.contains(line) {
            lines.append("+\(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// Timestamped copy of the current file, or nil when there is nothing to
    /// back up yet.
    static func backup(path: String, into directory: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(URL(fileURLWithPath: path).lastPathComponent).\(formatter.string(from: .now)).bak"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
        return destination.path
    }

    static func configBackupDirectory() -> URL {
        ProjectStore.defaultDirectory()
            .appendingPathComponent("config-backups", isDirectory: true)
    }

    /// Directory names holding a skill (a folder with a SKILL.md).
    static func skillNames(in directory: URL?) -> [String] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries
            .filter { url in
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("SKILL.md").path
                )
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// First executable match for `name` in the usual install locations, so
    /// detection works without the login shell's PATH.
    static func locateBinary(_ name: String, extraDirectories: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = extraDirectories + [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        for directory in candidates {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Environment variable names that look like secrets, so their values are
    /// kept out of config, diffs and logs.
    static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASS", "CREDENTIAL", "API_KEY"]
            .contains { upper.contains($0) }
    }

    /// Splits an env dictionary into secret names (values dropped) and plain
    /// values that are safe to keep.
    static func partitionEnvironment(
        _ environment: [String: String]
    ) -> (secretKeys: [String], plain: [String: String]) {
        var secretKeys: [String] = []
        var plain: [String: String] = [:]
        for (key, value) in environment {
            if isSecretKey(key) {
                secretKeys.append(key)
            } else {
                plain[key] = value
            }
        }
        return (secretKeys.sorted(), plain)
    }
}
