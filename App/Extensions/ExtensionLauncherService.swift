import Foundation

/// Writes the launcher manifest and produces the MCP definition agents get.
///
/// Agent configs point at `uncoil-extension run <id>`, never at a real binary,
/// so updating a revision never means rewriting an agent's config.
@MainActor
struct ExtensionLauncherService {
    var layout: ExtensionStoreLayout
    /// Absolute path of the bundled launcher.
    var launcherPath: String

    static func bundledLauncherPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uncoil-extension").path
    }

    var manifestURL: URL {
        layout.locks.appendingPathComponent(ExtensionLaunchManifest.fileName)
    }

    /// The command an agent config should contain for this extension.
    func launchCommand(extensionID: String) -> (command: String, arguments: [String]) {
        (launcherPath, ["run", extensionID])
    }

    /// MCP definition to hand an adapter: a fixed launcher command plus the
    /// names — never the values — of the secrets the server needs.
    func definition(
        for package: ExtensionPackage,
        secretKeys: [String] = [],
        environment: [String: String] = [:]
    ) -> MCPServerDefinition {
        let command = launchCommand(extensionID: package.id)
        return MCPServerDefinition(
            id: package.id,
            name: package.name,
            transport: .stdio,
            command: command.command,
            arguments: command.arguments,
            environmentKeys: secretKeys,
            environment: environment,
            isEnabled: package.state == .active
        )
    }

    /// Rewrites the manifest atomically from the current packages. Quarantined
    /// and disabled extensions stay in the manifest, marked, so the launcher
    /// refuses them even while an agent still lists them.
    @discardableResult
    func writeManifest(
        packages: [ExtensionPackage],
        entrypoints: [String: String],
        runtimes: [String: ExtensionLaunchManifest.Runtime] = [:],
        environments: [String: [String: String]] = [:],
        secretKeys: [String: [String]] = [:]
    ) throws -> ExtensionLaunchManifest {
        try layout.ensure()
        let entries = packages.compactMap { package -> ExtensionLaunchManifest.Entry? in
            guard package.kind == .mcpServer, let entrypoint = entrypoints[package.id] else {
                return nil
            }
            return ExtensionLaunchManifest.Entry(
                extensionID: package.id,
                name: package.name,
                revisionPath: layout.activeSkill(package.name).path,
                entrypoint: entrypoint,
                runtime: runtimes[package.id]
                    ?? .inferred(fromEntrypoint: entrypoint),
                environment: environments[package.id] ?? [:],
                secretKeys: secretKeys[package.id] ?? [],
                isQuarantined: package.state == .quarantined || package.state == .disabled,
                revisionID: package.activeRevision?.id
            )
        }
        let manifest = ExtensionLaunchManifest(entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        AtomicFile.write(try encoder.encode(manifest), to: manifestURL)
        return manifest
    }

    func readManifest() -> ExtensionLaunchManifest? {
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExtensionLaunchManifest.self, from: data)
    }

    /// Run records the launcher wrote, newest first.
    func runRecords() -> [ExtensionRunRecord] {
        let directory = layout.root.appendingPathComponent("runs", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries
            .compactMap { url -> ExtensionRunRecord? in
                guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
                return try? decoder.decode(ExtensionRunRecord.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
