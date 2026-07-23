import Foundation
import UserNotifications

extension SessionStore {
    /// Starts the hook socket server and routes events into session state.
    /// `applyMeta` persists provider session id / title candidates onto the record.
    func startHookServer(
        projectResolver: @escaping @MainActor (String) -> Project?,
        sessionResolver: @escaping @MainActor (UUID) -> UUID?,
        touchSession: @escaping @MainActor (UUID) -> Void,
        applyMeta: @escaping @MainActor (UUID, String?, String?) -> Void = { _, _, _ in }
    ) {
        let server = HookServer(socketPath: HookInstaller.socketPath)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.reduce(
                    event,
                    projectResolver: projectResolver,
                    sessionResolver: sessionResolver,
                    touchSession: touchSession,
                    applyMeta: applyMeta
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
        applyMeta: @MainActor (UUID, String?, String?) -> Void = { _, _, _ in }
    ) {
        guard
            let cwd = event.cwd,
            let project = projectResolver(cwd),
            let sessionID = sessionResolver(project.id)
        else { return }

        touchSession(sessionID)
        applyMeta(sessionID, event.sessionID, Self.titleCandidate(from: event))

        switch event.kind {
        case .sessionStart:
            setStatus(.idle, for: sessionID)
        case .userPromptSubmit:
            setStatus(.thinking, for: sessionID)
        case .preToolUse:
            setStatus(.running, detail: event.toolName.map { "araç: \($0)" }, for: sessionID)
        case .postToolUse:
            setStatus(.thinking, for: sessionID)
        case .notification:
            let message = event.message ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                setStatus(.waitingForPermission, detail: message, for: sessionID)
                notifyAttention(title: project.name, body: "Claude izin bekliyor")
            } else if message.localizedCaseInsensitiveContains("waiting") {
                setStatus(.waitingForInput, detail: message, for: sessionID)
                notifyAttention(title: project.name, body: "Claude yanıtını bekliyor")
            } else {
                setStatus(.thinking, detail: message.isEmpty ? nil : message, for: sessionID)
            }
        case .stop:
            // Turn finished — the agent now idles waiting for the human.
            setStatus(.idle, for: sessionID)
        case .sessionEnd:
            setStatus(.terminated, for: sessionID)
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

    // MARK: - Attention notifications

    private func notifyAttention(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "attention-\(title)-\(body)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
