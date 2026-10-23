import Foundation

extension AutoHarnessEnvironment {
    /// The harness in the running app. Specialists are ordinary sessions of
    /// the project — made by `ProjectStore`, started through the terminal
    /// registry like any other, children of Main in the sidebar — so the user
    /// can open each one and see what it is doing.
    ///
    /// - Parameters:
    ///   - main: the conversation's target, started if need be.
    ///   - deliver: how a prompt reaches a session from this conversation;
    ///     Main's go through the conversation so their echo is not shown twice.
    static func live(
        projectID: UUID,
        projects: ProjectStore,
        sessions: SessionStore,
        settings: SettingsStore,
        main: @escaping () async -> AgentItemSource?,
        deliver: @escaping (AutoSessionHandle, String) async -> Void
    ) -> AutoHarnessEnvironment {
        func project() -> Project? { projects.projects.first { $0.id == projectID } }
        func record(_ id: UUID) -> SessionRecord? { projects.sessions.first { $0.id == id } }
        func ensureRunning(_ id: UUID) {
            guard let record = record(id), let project = project() else { return }
            TerminalRegistry.shared.ensureSession(
                for: record, project: project, account: settings.account(id: record.accountID),
                settings: settings, sessionStore: sessions, projectStore: projects)
        }
        func handle(for id: UUID, name: String) -> AutoSessionHandle? {
            guard let record = record(id), let project = project() else { return nil }
            return AutoSessionHandle(
                sessionID: id, provider: record.provider, handle: name,
                directory: record.worktreePath ?? project.rootPath,
                worktreePath: record.worktreePath,
                model: record.launchSelection?.model, effort: record.launchSelection?.effort)
        }
        var started: [AutoRole: Int] = [:]

        return AutoHarnessEnvironment(
            settings: { settings.uncoilAuto.harness },
            resolveMain: {
                guard let source = await main() else { return nil }
                return handle(for: source.sessionID, name: source.handle)
            },
            startSpecialist: { spec, main in
                guard let project = project() else { return .failure(AutoHarnessFailure(message: "The project is gone.")) }
                var worktree: String?
                if spec.worktree {
                    let name = "auto-\(spec.role.rawValue)-\(UUID().uuidString.prefix(6).lowercased())"
                    let root = project.rootPath
                    let created = await Task.detached { GitService.createWorktree(repoPath: root, name: name) }.value
                    switch created {
                    case .success(let tree): worktree = tree.path
                    case .failure(let failure):
                        return .failure(AutoHarnessFailure(message: "The Worker's worktree could not be created: \(failure.message)"))
                    }
                }
                let restriction = AutoReadOnly.launch(for: spec.provider, readOnly: spec.readOnly)
                let selection = AgentLaunchSelection(model: spec.model, effort: spec.effort, workingMode: restriction.workingMode)
                let account = spec.accountID.flatMap(settings.account(id:)) ?? settings.defaultAccount(for: spec.provider)
                let record = projects.createSession(
                    projectID: projectID, provider: spec.provider, accountID: account?.id,
                    title: "Auto · \(spec.role.displayName)", worktreePath: worktree, launchSelection: selection)
                projects.updateSession(record.id) {
                    $0.parentSessionID = main.sessionID
                    if !restriction.extraArguments.isEmpty { $0.extraArguments = restriction.extraArguments }
                }
                ensureRunning(record.id)
                let count = started[spec.role, default: 0] + 1
                started[spec.role] = count
                let name = count == 1 ? spec.role.rawValue : "\(spec.role.rawValue)-\(count)"
                guard let handle = handle(for: record.id, name: name) else {
                    return .failure(AutoHarnessFailure(message: "The session could not be created."))
                }
                return .success(handle)
            },
            runTurn: { handle, prompt, timeout in
                ensureRunning(handle.sessionID)
                // A structured session publishes its own events; a terminal
                // agent's are read from its transcript. Never both: the same
                // reply would arrive twice under different ids.
                let structured = TerminalRegistry.shared.isStructured(handle.sessionID)
                return await AutoTurnWatcher(
                    sessionID: handle.sessionID,
                    hubs: structured ? [.shared] : [.transcripts],
                    status: { sessions.status(of: $0) },
                    follow: { id in
                        guard !structured else { return }
                        NativeSessionObservers.shared.retain(
                            id, locate: NativeTranscriptLocation.locator(for: id, projects: projects, settings: settings))
                    },
                    unfollow: { id in if !structured { NativeSessionObservers.shared.release(id) } },
                    isReady: { TerminalRegistry.shared.control(for: handle.sessionID, provider: handle.provider).isReady },
                    interrupt: { TerminalRegistry.shared.interrupt($0) }
                ).run(prompt: prompt, timeout: timeout) { text in
                    await deliver(handle, text)
                }
            },
            verificationSuites: { directory in
                await Task.detached { AutoVerification.suites(in: directory) }.value
            },
            runSuite: { suite, timeout in
                await Task.detached { AutoVerification.run(suite, timeout: timeout) }.value
            },
            changedFiles: { directory in
                await Task.detached { AutoVerification.changedFiles(in: directory) }.value
            },
            decisionEngine: {
                guard settings.uncoilAuto.harness.decisions.enabled else { return nil }
                return await LayaSidecar.shared.decisionEngine(
                    timeout: Double(settings.uncoilAuto.harness.decisions.timeoutMilliseconds) / 1000 + 1)
            },
            installed: { settings.installedProviders.contains($0) },
            stopSession: { TerminalRegistry.shared.closeTerminal(for: $0) },
            removeWorktree: { path in
                guard let root = project()?.rootPath else { return }
                _ = await Task.detached { GitService.removeWorktree(repoPath: root, path: path) }.value
            }
        )
    }
}

/// How a specialist is kept from writing, per provider. One place, so the
/// provider knowledge does not leak into the orchestration.
enum AutoReadOnly {
    struct Launch: Equatable {
        var workingMode: AgentWorkingMode?
        var extraArguments: [String] = []
    }

    static func launch(for provider: AgentProvider, readOnly: Bool) -> Launch {
        guard readOnly else { return Launch() }
        switch provider {
        case .claude:
            // Plan mode would end every turn by asking to leave it, which
            // nobody is there to answer; denying the editing tools is the
            // same restriction without the question. One comma-separated
            // value: the flag is variadic and would swallow what follows.
            return Launch(extraArguments: ["--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit"])
        default:
            let modes = AgentWorkingMode.options(for: provider)
            if modes.contains(.readOnly) { return Launch(workingMode: .readOnly) }
            // Read-only by instruction only: the CLI offers no such mode.
            return Launch()
        }
    }
}

/// Waits for one turn of one session, from the events it publishes.
///
/// A structured session says when its turn ends; a terminal agent's
/// transcript often does not, and then the session's own status — the hooks
/// that already drive the sidebar — says it: working, then settled, then
/// quiet for a moment.
@MainActor
final class AutoTurnWatcher {
    let sessionID: UUID
    let hubs: [AgentEventHub]
    let status: (UUID) -> AgentSessionStatus
    let follow: (UUID) -> Void
    let unfollow: (UUID) -> Void
    let isReady: () -> Bool
    let interrupt: (UUID) -> Void
    var pollInterval: Duration = .milliseconds(300)
    /// How long a settled session must stay quiet before its turn is over.
    var quietPeriod: TimeInterval = 2.5
    var now: () -> Date = Date.init

    private var started = false
    private var ended: AgentTurnOutcome?
    private var messages: [(id: String, text: String)] = []
    private var commands: [String: String] = [:]
    private var files: [String] = []
    private var lastEvent = Date.distantPast

    init(
        sessionID: UUID,
        hubs: [AgentEventHub],
        status: @escaping (UUID) -> AgentSessionStatus,
        follow: @escaping (UUID) -> Void = { _ in },
        unfollow: @escaping (UUID) -> Void = { _ in },
        isReady: @escaping () -> Bool = { true },
        interrupt: @escaping (UUID) -> Void
    ) {
        self.sessionID = sessionID
        self.hubs = hubs
        self.status = status
        self.follow = follow
        self.unfollow = unfollow
        self.isReady = isReady
        self.interrupt = interrupt
    }

    func run(prompt: String, timeout: TimeInterval, deliver: (String) async -> Void) async -> AutoTurnResult {
        let observations = hubs.map { hub in
            hub.observe(sessionID) { [weak self] record in self?.take(record.event) }
        }
        follow(sessionID)
        defer {
            observations.forEach { $0.cancel() }
            unfollow(sessionID)
        }
        let deadline = now().addingTimeInterval(timeout)
        // A session just started takes a moment to take input.
        let readyBy = min(deadline, now().addingTimeInterval(30))
        while !(status(sessionID).isKnownLive && isReady()), now() < readyBy {
            if Task.isCancelled { return result(.cancelled) }
            try? await Task.sleep(for: pollInterval)
        }
        let sent = now()
        lastEvent = sent
        await deliver(prompt)
        var sawWork = false
        while true {
            if Task.isCancelled {
                interrupt(sessionID)
                return result(.cancelled)
            }
            if now() >= deadline {
                interrupt(sessionID)
                return result(.timedOut)
            }
            if let ended {
                switch ended {
                case .completed: return result(.completed)
                case .interrupted: return result(.interrupted)
                case .failed(let message): return result(.failed(message ?? "the turn failed"))
                }
            }
            let state = status(sessionID)
            if state.isWorking { sawWork = true }
            let quiet = now().timeIntervalSince(lastEvent) >= quietPeriod
            if state == .terminated, sawWork || now().timeIntervalSince(sent) > 10 {
                return result(.crashed)
            }
            let settled = !state.isWorking && state != .waitingForPermission && state != .unknown
            if settled, quiet, !messages.isEmpty, sawWork || started {
                return result(.completed)
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func take(_ event: AgentEvent) {
        lastEvent = now()
        switch event {
        case .turnStarted:
            started = true
        case .turnCompleted(_, let outcome):
            // A turn that ended before this one started is the previous one.
            if started { ended = outcome }
        case .itemStarted(let item), .itemCompleted(let item):
            switch item.kind {
            case .agentMessage(let text):
                if let index = messages.firstIndex(where: { $0.id == item.id }) {
                    messages[index].text = text
                } else {
                    messages.append((item.id, text))
                }
            case .command(let command, _, let exitCode):
                commands[item.id] = "\(command) → \(exitCode.map { "exit \($0)" } ?? item.status.rawValue)"
            case .fileChange(let changes):
                for change in changes where !files.contains(change.path) { files.append(change.path) }
            case .userMessage:
                started = true
            default:
                break
            }
        case .itemDelta(let itemID, .text, let text):
            if let index = messages.firstIndex(where: { $0.id == itemID }) {
                messages[index].text += text
            } else {
                messages.append((itemID, text))
            }
        default:
            break
        }
    }

    private func result(_ outcome: AutoTurnResult.Outcome) -> AutoTurnResult {
        AutoTurnResult(
            outcome: outcome,
            text: messages.map(\.text).joined(separator: "\n\n"),
            commands: commands.values.sorted(),
            files: files)
    }
}
