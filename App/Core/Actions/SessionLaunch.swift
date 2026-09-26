import Foundation

/// One way to start a session, whoever asked for it.
///
/// Starting a session was written out at every surface that offers it — the
/// sidebar's launcher strip, the worktree row, the palette, the menu-bar extra
/// — and each copy decided for itself what to name the session, which login to
/// use and what a worktree does to the title. The naming had already drifted:
/// a terminal in a worktree is `terminal @ feature-x` from the sidebar and
/// plain `terminal` from everywhere else.
///
/// A request rather than a call with six arguments, because the interesting
/// part is what is *not* given: leave `account` nil and the agent's default
/// login is used, leave `worktreePath` nil and the session runs in the project
/// root. Filling those in is this type's job, in one place.
struct SessionLaunchRequest {
    var project: Project
    var provider: AgentProvider
    /// nil = the agent's default login. A plain terminal has none at all.
    var account: AccountProfile?
    /// nil = the project root.
    var worktreePath: String?

    /// What the session is called before the agent has said anything.
    ///
    /// A terminal is named after where it is, because that is the only thing
    /// that distinguishes one from another. An agent's session gets a
    /// placeholder the agent is expected to replace with the actual subject as
    /// soon as it knows it.
    var title: String {
        guard provider == .terminal else {
            return String(localized: "\(provider.rawValue): new session")
        }
        guard let name = worktreePath.map({ URL(fileURLWithPath: $0).lastPathComponent }) else {
            return "terminal"
        }
        return "terminal @ \(name)"
    }

    /// A plain terminal has no login, so it must not be handed one: a stored
    /// account id on a shell session would put a usage ring and an account
    /// name on a window that has neither.
    var accountID: UUID? {
        provider.isAgent ? account?.id : nil
    }
}

@MainActor
struct SessionLauncher {
    let projects: ProjectStore
    let settings: SettingsStore

    /// The agent a bare "new session" starts.
    ///
    /// The first of the user's own launcher order, resolved against what is
    /// actually installed — an agent that is not on the machine is a button
    /// that can only fail.
    var defaultProvider: AgentProvider? {
        settings.launcherProviders.first
    }

    @discardableResult
    func launch(_ request: SessionLaunchRequest) -> SessionRecord {
        var request = request
        if request.account == nil, request.provider.isAgent {
            request.account = settings.defaultAccount(for: request.provider)
        }
        return projects.createSession(
            projectID: request.project.id,
            provider: request.provider,
            accountID: request.accountID,
            title: request.title,
            worktreePath: request.worktreePath
        )
    }

    @discardableResult
    func launch(
        _ provider: AgentProvider,
        in project: Project,
        account: AccountProfile? = nil,
        worktreePath: String? = nil
    ) -> SessionRecord {
        launch(SessionLaunchRequest(
            project: project, provider: provider, account: account, worktreePath: worktreePath
        ))
    }
}
