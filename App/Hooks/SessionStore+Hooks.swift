import AppKit
import Foundation
import UserNotifications

extension SessionStore {
    /// Starts the hook socket server and routes events into session state.
    /// `applyMeta` persists provider session id / title candidates onto the record.
    func startHookServer(
        projectResolver: @escaping @MainActor (String) -> Project?,
        sessionResolver: @escaping @MainActor (Project, HookEvent) -> UUID?,
        touchSession: @escaping @MainActor (UUID) -> Void,
        notificationPrefs: @escaping @MainActor () -> NotificationPrefs = { NotificationPrefs() },
        sessionTitle: @escaping @MainActor (UUID) -> String? = { _ in nil },
        applyMeta: @escaping @MainActor (UUID, String?, String?) -> Void = { _, _, _ in },
        endSession: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        let server = HookServer(socketPath: HookInstaller.socketPath)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.reduce(
                    event,
                    projectResolver: projectResolver,
                    sessionResolver: sessionResolver,
                    touchSession: touchSession,
                    notificationPrefs: notificationPrefs,
                    sessionTitle: sessionTitle,
                    applyMeta: applyMeta,
                    endSession: endSession
                )
            }
        }
        do {
            try server.start()
            hookServer = server
        } catch {
            NSLog("Uncoil hook server could not start: \(error)")
        }
    }

    func stopHookServer() {
        hookServer?.stop()
        hookServer = nil
    }

    // MARK: - Reducer

    @MainActor
    func reduce(
        _ event: HookEvent,
        projectResolver: @MainActor (String) -> Project?,
        sessionResolver: @MainActor (Project, HookEvent) -> UUID?,
        touchSession: @MainActor (UUID) -> Void,
        notificationPrefs: @MainActor () -> NotificationPrefs = { NotificationPrefs() },
        sessionTitle: @MainActor (UUID) -> String? = { _ in nil },
        applyMeta: @MainActor (UUID, String?, String?) -> Void = { _, _, _ in },
        endSession: @MainActor (UUID) -> Void = { _ in }
    ) {
        guard
            let cwd = event.cwd,
            let project = projectResolver(cwd),
            let sessionID = sessionResolver(project, event)
        else { return }

        touchSession(sessionID)
        applyMeta(sessionID, event.sessionID, Self.titleCandidate(from: event))
        if let model = event.model { setReportedModel(model, for: sessionID) }

        let prefs = notificationPrefs()
        let sessionTitle = sessionTitle(sessionID) ?? "session"

        switch event.kind {
        case .sessionStart:
            subagents.reset(sessionID)
            setStatus(.idle, for: sessionID)
            clearNotificationDedup(sessionID)
        case .userPromptSubmit:
            subagents.mainResumed(in: sessionID)
            setStatus(.thinking, for: sessionID)
            // New turn started: allow the next attention/completion ping.
            clearNotificationDedup(sessionID)
        case .preToolUse:
            // Once the main agent's turn is over, tool calls come from its
            // sub-agents: the session stays "Sub-agents working" rather than
            // flickering back to Running and losing track of the wait.
            if subagents.isWaiting(for: sessionID) {
                subagents.heard(in: sessionID)
                setSubagentStatus(sessionID, tool: event.toolName)
            } else {
                setStatus(.running, detail: event.toolName.map { "tool: \($0)" }, for: sessionID)
            }
        case .postToolUse:
            if subagents.isWaiting(for: sessionID) {
                subagents.heard(in: sessionID)
                setSubagentStatus(sessionID, tool: nil)
            } else {
                setStatus(.thinking, for: sessionID)
            }
        case .notification:
            let message = event.message ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                setStatus(.waitingForPermission, detail: message, for: sessionID)
                notify(
                    .permission,
                    title: project.name,
                    body: String(localized: "Waiting for permission · \(sessionTitle)"),
                    projectID: project.id,
                    sessionID: sessionID,
                    prefs: prefs
                )
            } else if message.localizedCaseInsensitiveContains("waiting") {
                setStatus(.waitingForInput, detail: message, for: sessionID)
                notify(
                    .input,
                    title: project.name,
                    body: String(localized: "Waiting for input · \(sessionTitle)"),
                    projectID: project.id,
                    sessionID: sessionID,
                    prefs: prefs
                )
            } else if subagents.isWaiting(for: sessionID) {
                setSubagentStatus(sessionID, tool: nil)
            } else {
                setStatus(.thinking, detail: message.isEmpty ? nil : message, for: sessionID)
            }
        case .subagentStart:
            subagents.started(event.agentID, in: sessionID)
            if subagents.isWaiting(for: sessionID) {
                setSubagentStatus(sessionID, tool: nil)
            }
        case .subagentStop:
            // The last sub-agent the finished main turn was waiting on: only
            // now is the work done, and only now does "Turn done" go out.
            if subagents.stopped(event.agentID, in: sessionID) {
                setStatus(.idle, for: sessionID)
                notify(
                    .turnCompleted,
                    title: project.name,
                    body: String(localized: "Turn done · \(sessionTitle)"),
                    projectID: project.id,
                    sessionID: sessionID,
                    prefs: prefs
                )
            } else if subagents.isWaiting(for: sessionID) {
                setSubagentStatus(sessionID, tool: nil)
            }
        case .stop:
            // The main agent's turn is over, but sub-agents it started in the
            // background may not be. Then the session is still working.
            if subagents.mainStopped(in: sessionID) {
                setSubagentStatus(sessionID, tool: nil)
                return
            }
            // Turn finished — the agent now idles waiting for the human.
            setStatus(.idle, for: sessionID)
            notify(
                .turnCompleted,
                title: project.name,
                body: String(localized: "Turn done · \(sessionTitle)"),
                projectID: project.id,
                sessionID: sessionID,
                prefs: prefs
            )
        case .sessionEnd:
            subagents.reset(sessionID)
            setStatus(.terminated, for: sessionID)
            endSession(sessionID)
            clearNotificationDedup(sessionID)
        }
    }

    @MainActor
    private func setSubagentStatus(_ sessionID: UUID, tool: String?) {
        let count = subagents.count(for: sessionID)
        let base = count == 1
            ? String(localized: "1 sub-agent working")
            : String(localized: "\(count) sub-agents working")
        setStatus(
            .waitingForSubagents,
            detail: tool.map { "\(base) · tool: \($0)" } ?? base,
            for: sessionID
        )
    }

    // MARK: - Event notifications

    /// Runs one event through `NotificationPolicy` and posts it if the policy
    /// agrees. The ledger it consults is the same one the reminder sweep walks,
    /// so a first banner and its repeats stay in step.
    @MainActor
    @discardableResult
    func notify(
        _ event: NotificationEvent,
        title: String,
        body: String,
        projectID: UUID,
        sessionID: UUID,
        prefs: NotificationPrefs,
        context: NotificationPolicy.Context = .init(now: Date(), appIsActive: NSApp?.isActive ?? false)
    ) -> NotificationDecision {
        if directedNotificationFilter?(sessionID, event) == true {
            return .skip(.directedByUncoilAuto)
        }
        let decision = NotificationPolicy.decide(
            event: event,
            projectID: projectID,
            sessionID: sessionID,
            prefs: prefs,
            attempt: notificationLedger.attempt(sessionID: sessionID, event: event),
            context: context
        )
        guard let dispatch = decision.dispatch else { return decision }
        notificationLedger.record(sessionID: sessionID, event: event, at: context.now)
        // The banner is easy to miss; the sidebar row keeps saying it until the
        // session is opened.
        markAttention(sessionID)
        AttentionNotifier.post(
            title: title,
            body: body,
            projectID: projectID,
            prefs: prefs,
            sessionID: sessionID,
            dispatch: dispatch
        )
        return decision
    }

    @MainActor
    private func clearNotificationDedup(_ sessionID: UUID) {
        notificationLedger.clear(sessionID: sessionID)
    }

    // MARK: - Repeat reminders

    /// Starts the sweep that re-announces states nobody has answered.
    ///
    /// A timer rather than a per-notification delay: the condition being
    /// reminded about ("still waiting for input") is a property of the session's
    /// *current* status, so it has to be re-checked, not scheduled once and
    /// fired blindly after the user has long since replied.
    @MainActor
    func startNotificationReminders(
        interval: TimeInterval = 30,
        prefs: @escaping @MainActor () -> NotificationPrefs,
        projectID: @escaping @MainActor (UUID) -> UUID?,
        projectName: @escaping @MainActor (UUID) -> String?,
        sessionTitle: @escaping @MainActor (UUID) -> String?,
        visibleSessionID: @escaping @MainActor () -> UUID? = { nil }
    ) {
        reminderTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepReminders(
                    prefs: prefs(),
                    projectID: projectID,
                    projectName: projectName,
                    sessionTitle: sessionTitle,
                    visibleSessionID: visibleSessionID()
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    @MainActor
    func stopNotificationReminders() {
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    /// One pass over the ledger. Public so a test can drive it with a fixed
    /// clock instead of waiting on a timer.
    @MainActor
    func sweepReminders(
        prefs: NotificationPrefs,
        projectID: @MainActor (UUID) -> UUID?,
        projectName: @MainActor (UUID) -> String?,
        sessionTitle: @MainActor (UUID) -> String?,
        visibleSessionID: UUID? = nil,
        now: Date = Date(),
        appIsActive: Bool = NSApp?.isActive ?? false
    ) {
        guard prefs.enabled, prefs.reminders.enabled else { return }
        for entry in notificationLedger.pending() {
            guard prefs.remindsAbout(entry.event) else { continue }
            // The state has to still be true. A session that has moved on gets
            // its ledger entry dropped instead of a stale reminder.
            guard Self.status(matching: entry.event) == status(of: entry.sessionID) else {
                notificationLedger.clear(sessionID: entry.sessionID, event: entry.event)
                continue
            }
            guard let project = projectID(entry.sessionID) else { continue }
            notify(
                entry.event,
                title: projectName(entry.sessionID) ?? "Uncoil",
                body: String(localized: "\(entry.event.title) · \(sessionTitle(entry.sessionID) ?? "session")"),
                projectID: project,
                sessionID: entry.sessionID,
                prefs: prefs,
                context: .init(
                    now: now,
                    appIsActive: appIsActive,
                    visibleSessionID: visibleSessionID,
                    isReminderPass: true
                )
            )
        }
    }

    /// The session status an event describes, for events that persist.
    static func status(matching event: NotificationEvent) -> AgentSessionStatus? {
        switch event {
        case .permission: .waitingForPermission
        case .input: .waitingForInput
        default: nil
        }
    }

    /// First line of the first prompt, tightened for the sidebar.
    nonisolated static func titleCandidate(from event: HookEvent) -> String? {
        guard event.kind == .userPromptSubmit, let prompt = event.prompt else { return nil }
        return SessionAutoTitle.candidate(from: prompt)
    }

}
