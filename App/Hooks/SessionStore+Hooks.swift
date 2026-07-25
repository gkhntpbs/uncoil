import Foundation
import UserNotifications

extension SessionStore {
    /// Starts the hook socket server and routes events into session state.
    /// `applyMeta` persists provider session id / title candidates onto the record.
    func startHookServer(
        projectResolver: @escaping @MainActor (String) -> Project?,
        sessionResolver: @escaping @MainActor (UUID) -> UUID?,
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
        sessionResolver: @MainActor (UUID) -> UUID?,
        touchSession: @MainActor (UUID) -> Void,
        notificationPrefs: @MainActor () -> NotificationPrefs = { NotificationPrefs() },
        sessionTitle: @MainActor (UUID) -> String? = { _ in nil },
        applyMeta: @MainActor (UUID, String?, String?) -> Void = { _, _, _ in },
        endSession: @MainActor (UUID) -> Void = { _ in }
    ) {
        guard
            let cwd = event.cwd,
            let project = projectResolver(cwd),
            let sessionID = sessionResolver(project.id)
        else { return }

        touchSession(sessionID)
        applyMeta(sessionID, event.sessionID, Self.titleCandidate(from: event))

        let prefs = notificationPrefs()
        let sessionTitle = sessionTitle(sessionID) ?? "oturum"

        switch event.kind {
        case .sessionStart:
            setStatus(.idle, for: sessionID)
            clearNotificationDedup(sessionID)
        case .userPromptSubmit:
            setStatus(.thinking, for: sessionID)
            // New turn started: allow the next attention/completion ping.
            clearNotificationDedup(sessionID)
        case .preToolUse:
            setStatus(.running, detail: event.toolName.map { "araç: \($0)" }, for: sessionID)
        case .postToolUse:
            setStatus(.thinking, for: sessionID)
        case .notification:
            let message = event.message ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                setStatus(.waitingForPermission, detail: message, for: sessionID)
                if prefs.notifyPermission {
                    notifyOnce(
                        key: "\(sessionID)-permission",
                        title: project.name,
                        body: "İzin bekliyor · \(sessionTitle)",
                        projectID: project.id,
                        sessionID: sessionID,
                        prefs: prefs
                    )
                }
            } else if message.localizedCaseInsensitiveContains("waiting") {
                setStatus(.waitingForInput, detail: message, for: sessionID)
                if prefs.notifyInput {
                    notifyOnce(
                        key: "\(sessionID)-input",
                        title: project.name,
                        body: "Girdi bekliyor · \(sessionTitle)",
                        projectID: project.id,
                        sessionID: sessionID,
                        prefs: prefs
                    )
                }
            } else {
                setStatus(.thinking, detail: message.isEmpty ? nil : message, for: sessionID)
            }
        case .stop:
            // Turn finished — the agent now idles waiting for the human.
            setStatus(.idle, for: sessionID)
            if prefs.notifyTurnCompleted {
                notifyOnce(
                    key: "\(sessionID)-completed",
                    title: project.name,
                    body: "Tur tamamlandı · \(sessionTitle)",
                    projectID: project.id,
                    sessionID: sessionID,
                    prefs: prefs
                )
            }
        case .sessionEnd:
            setStatus(.terminated, for: sessionID)
            endSession(sessionID)
            clearNotificationDedup(sessionID)
        }
    }

    // MARK: - Once-per-state notifications

    @MainActor
    private func notifyOnce(
        key: String,
        title: String,
        body: String,
        projectID: UUID,
        sessionID: UUID,
        prefs: NotificationPrefs
    ) {
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)
        // The banner is easy to miss; the sidebar row keeps saying it until the
        // session is opened.
        markAttention(sessionID)
        AttentionNotifier.post(
            title: title, body: body, projectID: projectID, prefs: prefs, sessionID: sessionID
        )
    }

    @MainActor
    private func clearNotificationDedup(_ sessionID: UUID) {
        sentNotificationKeys = sentNotificationKeys.filter {
            !$0.hasPrefix(sessionID.uuidString)
        }
    }

    /// First line of the first prompt, tightened for the sidebar.
    nonisolated static func titleCandidate(from event: HookEvent) -> String? {
        guard event.kind == .userPromptSubmit, let prompt = event.prompt else { return nil }
        let firstLine = prompt
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return nil }
        return firstLine.count > 42 ? String(firstLine.prefix(41)) + "…" : firstLine
    }

}
