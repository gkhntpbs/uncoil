import Foundation

/// Puts a prompt into a session that may not have started yet.
///
/// Every caller that opens a session and then says something to it needs the
/// same three steps, in the same order: force the PTY into existence through
/// the ordinary terminal path so the session appears in the sidebar like any
/// other, wait for the agent to be there, then write.
///
/// This existed four times over — the control plane's child launcher, the
/// palette's "ask", the session organiser and task dispatch — with the timings
/// copied along with it. A fifth copy for blueprints would have been the point
/// at which one of them quietly drifted.
///
/// The wait is deliberately best-effort and deliberately short. It watches for
/// the first hook to lift the session off `.terminated`, and gives up after
/// three seconds rather than failing: the real readiness gate is downstream in
/// `RuntimeClient.waitUntilInputReady`, and this only exists so the common case
/// does not race the very first paint.
@MainActor
enum SessionPromptDelivery {
    static let readinessTimeout: TimeInterval = 3
    private static let pollInterval: UInt64 = 200_000_000

    /// Opens the session's terminal and delivers `prompt` once it is live.
    ///
    /// `autoStart` false types the text into the line editor without sending
    /// it, so the user reads it before it runs. `namesTheSession` is false for
    /// text Uncoil sends on its own account — a session named after something
    /// the user never wrote would be worse than one still called "new session".
    static func deliver(
        _ prompt: String,
        to record: SessionRecord,
        project: Project,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore,
        autoStart: Bool = true,
        namesTheSession: Bool = false
    ) {
        _ = TerminalRegistry.shared.terminal(
            for: record, project: project,
            account: settings.account(id: record.accountID),
            settings: settings, sessionStore: sessionStore,
            projectStore: projectStore
        )
        guard !prompt.isEmpty else { return }
        let sid = record.id
        let provider = record.provider
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(readinessTimeout)
            while Date() < deadline, !sessionStore.status(of: sid).isKnownLive {
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            if autoStart {
                await TerminalRegistry.shared.submitText(
                    prompt, for: sid, provider: provider,
                    namesTheSession: namesTheSession
                )
            } else {
                await TerminalRegistry.shared.typeText(prompt, for: sid, provider: provider)
            }
        }
    }
}
