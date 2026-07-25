import Foundation

/// Wire format between Uncoil and the `uncoil-extension` launcher.
///
/// Agent configs point at `uncoil-extension run <extension-id>` rather than at a
/// real MCP binary, so the command an agent stores never has to change when a
/// revision is updated: the launcher resolves the active revision at start-up.
///
/// The manifest is written by the app and holds NO secret values — only the
/// names of the environment variables to inject. Values come from the app over
/// `ExtensionSecretProtocol` at launch time and stay in the Keychain otherwise.
struct ExtensionLaunchManifest: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "launcher.json"

    var version = ExtensionLaunchManifest.currentVersion
    var entries: [Entry] = []

    struct Entry: Codable, Equatable {
        var extensionID: String
        var name: String
        /// Directory the launcher runs from: the active revision (usually a
        /// symlink, resolved fresh on every start).
        var revisionPath: String
        /// Entrypoint relative to `revisionPath`.
        var entrypoint: String
        var runtime: Runtime
        /// Extra arguments inserted before the entrypoint's own.
        var arguments: [String] = []
        /// Non-secret environment values, safe to keep on disk.
        var environment: [String: String] = [:]
        /// Keychain account names to fetch and inject at launch.
        var secretKeys: [String] = []
        /// A quarantined extension is refused by the launcher, which is how
        /// quarantine survives an agent that still has it in its config.
        var isQuarantined = false
        /// Revision the entry was written for, so an old process is
        /// recognisable after an update.
        var revisionID: String?
    }

    enum Runtime: String, Codable, Equatable, CaseIterable {
        case node
        case python
        case shell
        /// The entrypoint is itself executable.
        case binary

        /// Interpreter to look for, or nil when the entrypoint runs directly.
        var interpreter: String? {
            switch self {
            case .node: "node"
            case .python: "python3"
            case .shell: "/bin/sh"
            case .binary: nil
            }
        }

        /// Guessed from the entrypoint's extension; callers may override.
        static func inferred(fromEntrypoint entrypoint: String) -> Runtime {
            switch (entrypoint as NSString).pathExtension.lowercased() {
            case "js", "mjs", "cjs": .node
            case "py": .python
            case "sh", "bash", "zsh": .shell
            default: .binary
            }
        }
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.extensionID == id }
    }
}

/// Request/response the launcher uses to fetch an extension's secrets from the
/// running app. One line of JSON each way over a 0600, euid-checked socket, so a
/// secret value never touches disk.
enum ExtensionSecretProtocol {
    static let socketName = "extension-secrets.sock"

    struct Request: Codable, Equatable {
        var extension_id: String
    }

    struct Response: Codable, Equatable {
        var ok: Bool
        /// Environment variables to inject, present only when `ok`.
        var environment: [String: String]?
        var error: String?

        static func failure(_ message: String) -> Response {
            Response(ok: false, environment: nil, error: message)
        }

        static func success(_ environment: [String: String]) -> Response {
            Response(ok: true, environment: environment, error: nil)
        }
    }
}

/// How the launcher recorded a child's exit, so the app can show crashes and
/// detect a crash loop without supervising the process itself (the agent owns
/// it, not Uncoil).
struct ExtensionRunRecord: Codable, Equatable {
    var extensionID: String
    var revisionID: String?
    var pid: Int32
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    /// Set when the child died on a signal rather than exiting.
    var signal: Int32?
    /// Which agent started this process, when the agent identified itself
    /// through `UNCOIL_EXTENSION_AGENT`.
    var agent: String?

    var isRunning: Bool { endedAt == nil }
    var crashed: Bool { signal != nil || (exitCode ?? 0) != 0 }
}
