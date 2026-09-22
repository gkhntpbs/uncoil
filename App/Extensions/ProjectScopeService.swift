import Foundation

/// Answers "what may a session started in this project load?" at launch time.
///
/// Deliberately not an `ExtensionRegistry`. The registry is an observable store
/// that a screen keeps alive, replays an audit log into, and writes back; a
/// session launch needs none of that and must not pay for it. This reads the
/// two things it needs — the project's records and the agent's live config —
/// and answers.
///
/// Reading the agent's config at launch rather than caching it is the point:
/// the user may have added a server in another window a second ago, and a
/// scope computed from a stale snapshot would exclude a server that is not
/// there or admit one that is.
@MainActor
final class ProjectScopeService {
    static let shared = ProjectScopeService()

    private let layout: ExtensionStoreLayout
    private let adapters: AgentAdapterRegistry

    init(layout: ExtensionStoreLayout = .default(), adapters: AgentAdapterRegistry? = nil) {
        self.layout = layout
        self.adapters = adapters ?? AgentAdapterRegistry()
    }

    /// A project's decisions plus the config text they were read from.
    ///
    /// The raw text travels with the decisions because Claude Code's allow-list
    /// has to be copied out of it verbatim — see
    /// `ProjectExtensionScope.filteredMCPServers`. Re-reading the file at the
    /// point of writing would open a window for it to change in between.
    struct Resolved {
        var scope: ProjectExtensionScope = .unrestricted
        var rawConfig: String = ""

        static let unrestricted = Resolved()
    }

    /// The project's scope for one provider, or `.unrestricted` whenever the
    /// question does not apply or cannot be answered.
    ///
    /// Every failure path returns `.unrestricted` on purpose. A scope this
    /// cannot compute must leave the command line exactly as it found it —
    /// guessing narrow would silently strip an agent of tools the user never
    /// asked to lose, and a launch is the worst place to discover that.
    ///
    /// `configDirectory` is the isolated config root the session will actually
    /// launch with — an account profile's `CODEX_HOME` / `CLAUDE_CONFIG_DIR`.
    /// It has to be honoured, because the decisions are subtractive: naming a
    /// server the session's own config never declares does not switch anything
    /// off, it invents a nameless entry, and Codex refuses the whole file with
    /// `invalid transport in mcp_servers.<name>`. Reading the default home for
    /// a session running on a work account produced exactly that.
    func resolve(
        for provider: AgentProvider,
        projectID: UUID,
        configDirectory: URL? = nil
    ) -> Resolved {
        guard provider.extensionScoping != .none,
              let agent = provider.extensionAgent,
              let adapter = adapters.adapter(for: agent)
        else { return .unrestricted }

        // The fast path, and the one almost every launch takes: with no project
        // records anywhere there is nothing to enforce, so the agent's config is
        // never even opened.
        guard let document = loadDocument(), !document.projectBindings.isEmpty else {
            return .unrestricted
        }

        guard let detected = adapter.detectInstallations().first else { return .unrestricted }
        let installation = Self.rebase(detected, onto: configDirectory)
        guard let configuration = try? adapter.readConfiguration(installation)
        else { return .unrestricted }

        return Resolved(
            scope: ProjectExtensionScope.resolve(
                configuration: configuration,
                packages: document.packages,
                projectBindings: document.projectBindings,
                projectID: projectID
            ),
            rawConfig: configuration.raw
        )
    }

    /// Points one installation at an isolated config root, keeping each file's
    /// own name. An agent decides where its config lives inside the root — a
    /// TOML for Codex, a dotfile for Claude Code — and moving the root must not
    /// rename either, so only the directory is replaced.
    static func rebase(_ installation: AgentInstallation, onto directory: URL?) -> AgentInstallation {
        guard let directory else { return installation }
        var moved = installation
        moved.configDirectory = directory.path
        moved.skillsDirectory = installation.skillsDirectory.map {
            directory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path
        }
        moved.mcpConfigPath = installation.mcpConfigPath.map {
            directory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path
        }
        return moved
    }

    /// Decodes the registry document directly, without the audit log an
    /// `ExtensionRegistry` would replay alongside it.
    private func loadDocument() -> ExtensionRegistry.Document? {
        let url = layout.locks.appendingPathComponent("registry.json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ExtensionRegistry.Document.self, from: data),
              document.version <= ExtensionRegistry.Document.currentVersion
        else { return nil }
        return document
    }
}
