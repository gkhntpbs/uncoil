import Foundation

/// Where a handoff can go.
///
/// A destination is an account, not a provider: handing Claude's work to Claude
/// under a second login is as valid as handing it to Codex, and on a machine
/// with two subscriptions it is the more likely answer.
struct HandoffDestination: Identifiable, Equatable {
    var id: String { "\(provider.rawValue):\(accountID?.uuidString ?? "default")" }
    var provider: AgentProvider
    var accountID: UUID?
    var accountName: String?
    /// What this destination has left, when it is known. A destination that is
    /// also low is worth offering and worth marking; hiding it would leave
    /// someone with no options at all on a machine where everything is low.
    var remainingPercent: Int?
    var isAlerting: Bool

    var label: String {
        guard let accountName, !accountName.isEmpty,
              accountName.caseInsensitiveCompare(provider.displayName) != .orderedSame else {
            return provider.displayName
        }
        return "\(provider.displayName) · \(accountName)"
    }
}

/// Builds the handoff, asks the outgoing agent for its half, and starts the
/// agent that takes over.
///
/// Deliberately not automatic. Every step here is something the user asked for
/// by choosing a destination; the rule that no work moves without being asked
/// is enforced by there being no path through this type that starts itself.
@MainActor
final class HandoffService: ObservableObject {
    /// What the service is doing, for a view that has to say so.
    enum Phase: Equatable {
        case idle
        /// Waiting for the outgoing agent to write its file.
        case askingOutgoingAgent
        case startingNewSession
        case done(newSessionID: UUID)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The package as it stands, so the user can read it before it is sent.
    @Published private(set) var package: HandoffPackage?

    private let projectStore: ProjectStore
    private let sessionStore: SessionStore
    private let settings: SettingsStore

    init(projectStore: ProjectStore, sessionStore: SessionStore, settings: SettingsStore) {
        self.projectStore = projectStore
        self.sessionStore = sessionStore
        self.settings = settings
    }

    // MARK: - Destinations

    /// Every account a handoff could go to, minus the one it is coming from.
    ///
    /// Ordered by what is left, so the account with the most room is offered
    /// first — that is the only ordering that answers the question the user is
    /// actually asking.
    static func destinations(
        from key: UsageKey,
        accounts: [AccountProfile],
        installedProviders: Set<AgentProvider>,
        usage: [UsageKey: UsageEntry],
        threshold: Double
    ) -> [HandoffDestination] {
        var result: [HandoffDestination] = []

        for provider in AgentProvider.agents where installedProviders.contains(provider) {
            let profiles = accounts.filter { $0.provider == provider }
            // The provider's own default login is a destination in its own
            // right: most people never make a profile, and a list that only
            // offered profiles would be empty on a normal machine.
            let candidates: [(UUID?, String?)] = profiles.isEmpty
                ? [(nil, nil)]
                : [(nil, nil)] + profiles.map { ($0.id, $0.name) }

            for (accountID, name) in candidates {
                let candidate = UsageKey(provider: provider, accountID: accountID)
                guard candidate != key else { continue }
                let snapshot = usage[candidate]?.snapshot
                let evaluation = UsageAlert.evaluate(snapshot, threshold: threshold)
                result.append(HandoffDestination(
                    provider: provider,
                    accountID: accountID,
                    accountName: name,
                    remainingPercent: UsageDisplay.headlineRemaining(snapshot),
                    isAlerting: evaluation.state.isAlerting
                ))
            }
        }

        return result.sorted { left, right in
            // Unknown sorts last rather than first: an account we cannot read
            // is not a promise of room.
            switch (left.remainingPercent, right.remainingPercent) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.label < right.label
            }
        }
    }

    // MARK: - Building

    /// The half Uncoil can answer for, gathered without asking anyone.
    ///
    /// Blocking git calls are done off the main actor by the caller; everything
    /// here is a read.
    static func groundTruth(
        session: SessionRecord,
        project: Project,
        accountName: String?,
        git: GitService.Snapshot,
        diff: String?,
        task: HandoffPackage.TaskContext?,
        testResults: [HandoffPackage.TestResult],
        runningProcesses: [String],
        now: Date
    ) -> HandoffPackage {
        HandoffPackage(
            projectName: project.name,
            projectPath: project.rootPath,
            workingDirectory: session.workingDirectory(in: project),
            worktreePath: session.worktreePath,
            branch: git.branch,
            changedFiles: git.changedFiles.map {
                HandoffPackage.ChangedFile(status: $0.status, path: $0.path)
            },
            diff: diff,
            task: task,
            testResults: testResults,
            runningProcesses: runningProcesses,
            fromProvider: session.provider,
            fromAccountName: accountName,
            fromSessionTitle: session.displayTitle,
            createdAt: now
        )
    }

    /// Gathers the ground truth for a session, off the main actor.
    ///
    /// Runs first and on its own so the sheet has something to show while the
    /// outgoing agent is still writing: the half that cannot fail is also the
    /// half that is instant.
    func prepare(session: SessionRecord, accountName: String?) async -> HandoffPackage? {
        guard let project = projectStore.projects.first(where: { $0.id == session.projectID })
        else { return nil }

        let directory = session.workingDirectory(in: project)
        let (git, diff) = await Task.detached(priority: .userInitiated) {
            (GitService.snapshot(repoPath: directory),
             GitService.diff(repoPath: directory, maxLines: 200))
        }.value

        let built = Self.groundTruth(
            session: session,
            project: project,
            accountName: accountName,
            git: git,
            diff: diff.isEmpty ? nil : diff,
            task: nil,
            testResults: [],
            runningProcesses: [],
            now: Date()
        )
        package = built
        return built
    }

    /// The whole thing, in the order the parts become available.
    func run(
        session: SessionRecord,
        accountName: String?,
        destination: HandoffDestination,
        remainingPercent: Int?,
        windowTitle: String?,
        askAgent: Bool
    ) async {
        guard let ground = await prepare(session: session, accountName: accountName) else {
            phase = .failed(String(localized: "The project is gone."))
            return
        }
        // Asking is skippable: an agent that has already stopped answering
        // would only cost ninety seconds of waiting, and the ground truth is
        // already in hand.
        let complete = askAgent
            ? await collectFromAgent(
                session: session, into: ground,
                remainingPercent: remainingPercent, windowTitle: windowTitle
            )
            : ground
        // The user closed the sheet while the outgoing agent was being asked.
        // Nothing has moved yet, and after a cancel nothing should: starting a
        // session the user just declined would be the handoff deciding for
        // them.
        if Task.isCancelled {
            phase = .idle
            return
        }
        package = complete
        await handOver(package: complete, from: session, to: destination)
    }

    /// Asks the outgoing agent for its half by running its CLI.
    ///
    /// A failure here is not a failure of the handoff: the ground truth is
    /// already in hand, and a package without the agent's notes is worth far
    /// more than no handoff at all. The reason is recorded so the next agent is
    /// told the silence was silence.
    func collectFromAgent(
        session: SessionRecord,
        into package: HandoffPackage,
        remainingPercent: Int?,
        windowTitle: String?
    ) async -> HandoffPackage {
        phase = .askingOutgoingAgent

        guard let project = projectStore.projects.first(where: { $0.id == session.projectID }) else {
            var lost = package
            lost.agentFailureReason = String(localized: "its project is gone")
            return lost
        }
        // `binaryPath` is a cache the app fills by resolving through the login
        // shell, and it is empty until that has run — on a fresh profile it is
        // empty for the whole first minute. Depending on it alone is what made
        // this look like a broken handoff for three rounds: the CLI was never
        // launched at all, and every layer above reported the same blank "it
        // did not answer".
        // Under UI testing the stub stands in for the CLI, so the ask path —
        // the invocation, the parse, the merge, the wording — runs in every
        // test instead of only on machines with a login and quota to spend.
        guard let executable = LaunchConfig.shared.handoffStubPath
            ?? settings.binaryPath(for: session.provider)
            ?? session.provider.launchCommand.flatMap({ AgentAdapterSupport.locateBinary($0) })
        else {
            var missing = package
            missing.agentFailureReason = String(localized: "its CLI could not be found")
            return missing
        }

        let request = HandoffPrompt.request(
            remainingPercent: remainingPercent, windowTitle: windowTitle
        )
        let directory = session.workingDirectory(in: project)
        let provider = session.provider
        let providerSessionID = session.providerSessionID

        let result = await Task.detached(priority: .userInitiated) {
            HandoffProducer.produce(
                provider: provider,
                executable: executable,
                providerSessionID: providerSessionID,
                workingDirectory: directory,
                request: request
            )
        }.value

        guard let json = result.json else {
            var failed = package
            failed.agentFailureReason = result.failure
                ?? String(localized: "its answer could not be read")
            return failed
        }
        var merged = HandoffPrompt.merge(agentJSON: json, into: package)
        if !merged.agentResponded {
            merged.agentFailureReason = String(localized: "it wrote an empty handover")
        }
        return merged
    }

    // MARK: - Handing over

    /// Starts the new session and gives it the package.
    ///
    /// The outgoing session is left running. It is the only record of what the
    /// package was made from, and closing it would take that away at the moment
    /// somebody might need to check the handover against it.
    @discardableResult
    func handOver(
        package: HandoffPackage,
        from session: SessionRecord,
        to destination: HandoffDestination
    ) async -> UUID? {
        phase = .startingNewSession

        guard let project = projectStore.projects.first(where: { $0.id == session.projectID }) else {
            phase = .failed(String(localized: "The project is gone."))
            return nil
        }

        let created = projectStore.createSession(
            projectID: project.id,
            provider: destination.provider,
            accountID: destination.accountID,
            // Named after what it is continuing, so the sidebar says why the
            // session exists.
            title: String(localized: "\(session.displayTitle) (continued)"),
            worktreePath: session.worktreePath
            // Deliberately the provider's default mode. The agent taking over
            // is doing the user's ordinary work and should ask before acting,
            // exactly as any session they started themselves would. The bypass
            // belongs to the short-lived process that produces the handover —
            // that one only reads a conversation and prints JSON, and nobody is
            // watching it to answer a prompt.
        )
        projectStore.updateSession(created.id) {
            $0.handoffFromSessionID = session.id
        }

        // The handover goes to a file and the agent is pointed at it.
        //
        // Typing the whole thing in was the first design and it was wrong twice
        // over: two kilobytes of markdown pasted into a TUI is at the mercy of
        // however that TUI handles a paste, and none of it survives if the
        // prompt is not drawn yet. One line referring to a file has neither
        // problem — and the file stays afterwards, so the handover can be read
        // by a person, not only by the agent that consumed it.
        let relative = writeHandover(package, for: created, in: project)

        // A session's process starts when its terminal is created, and nothing
        // else starts it. The first design waited politely for a process that
        // no one had launched, timed out, and typed the opening line into a
        // PTY that did not exist — the handoff "finished" and the new session
        // came up empty. Creating the terminal here, exactly as the task
        // launcher and the control plane's child launcher do, is what makes
        // the delivery real.
        _ = TerminalRegistry.shared.terminal(
            for: created, project: project,
            account: settings.account(id: destination.accountID),
            settings: settings, sessionStore: sessionStore,
            projectStore: projectStore
        )
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sessionStore.status(of: created.id).isKnownLive {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // `submitText` waits for the agent to look ready before typing.
        await TerminalRegistry.shared.submitText(
            relative.map { HandoffPrompt.opening(fileName: $0) }
                // With nowhere to write, the text itself is still better than
                // nothing.
                ?? HandoffPrompt.handover(package),
            for: created.id,
            provider: destination.provider,
            namesTheSession: false
        )

        phase = .done(newSessionID: created.id)
        return created.id
    }

    /// Writes the handover beside the work and returns its relative path.
    ///
    /// Relative, because that is the one form of path a CLI agent never has to
    /// ask permission to read: it is inside the directory it was started in.
    private func writeHandover(
        _ package: HandoffPackage, for session: SessionRecord, in project: Project
    ) -> String? {
        let relative = "\(HandoffPrompt.directory)/\(session.id.uuidString.prefix(8)).md"
        let url = URL(fileURLWithPath: session.workingDirectory(in: project))
            .appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try HandoffPrompt.handover(package).write(to: url, atomically: true, encoding: .utf8)
            if LaunchConfig.shared.isUITesting {
                // Path and content both: the runner's sandbox can read the
                // journal it chose the path of, and nothing else.
                UITestJournal.append("HANDOVER", url.path)
                UITestJournal.append("HANDOVER-TEXT", HandoffPrompt.handover(package))
            }
            return relative
        } catch {
            return nil
        }
    }

    func reset() {
        phase = .idle
        package = nil
    }

    func setPackage(_ package: HandoffPackage) {
        self.package = package
    }
}
