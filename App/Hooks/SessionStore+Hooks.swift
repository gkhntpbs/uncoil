import Foundation
import UserNotifications

extension SessionStore {
    /// Starts the hook socket server and routes events into session state.
    /// `projectResolver` maps a hook cwd to a registered project.
    func startHookServer(projectResolver: @escaping @MainActor (String) -> Project?) {
        let server = HookServer(socketPath: HookInstaller.socketPath)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.reduce(event, projectResolver: projectResolver)
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
    func reduce(_ event: HookEvent, projectResolver: @MainActor (String) -> Project?) {
        guard let cwd = event.cwd, let project = projectResolver(cwd) else { return }

        let session: AgentSession
        if let existing = self.session(for: project.id) {
            session = existing
        } else if event.kind == .sessionEnd {
            return
        } else {
            session = startSession(projectID: project.id, title: project.name)
        }
        if let sid = event.sessionID {
            session.providerSessionID = sid
        }

        switch event.kind {
        case .sessionStart:
            session.status = .idle
            session.statusDetail = nil
        case .userPromptSubmit:
            session.status = .running
            session.statusDetail = nil
        case .preToolUse:
            session.status = .running
            session.statusDetail = event.toolName.map { "Araç: \($0)" }
        case .postToolUse:
            session.status = .running
        case .notification:
            let message = event.message ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                session.status = .waitingForPermission
                notifyAttention(title: project.name, body: "Claude izin bekliyor")
            } else if message.localizedCaseInsensitiveContains("waiting") {
                session.status = .waitingForInput
                notifyAttention(title: project.name, body: "Claude yanıtını bekliyor")
            }
            session.statusDetail = message.isEmpty ? nil : message
        case .stop:
            session.status = .completed
            session.statusDetail = nil
        case .sessionEnd:
            session.status = .terminated
        }
        // AgentSession fields are @Published on the object; poke the store so
        // list rows that only observe the store also refresh.
        objectWillChange.send()
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
