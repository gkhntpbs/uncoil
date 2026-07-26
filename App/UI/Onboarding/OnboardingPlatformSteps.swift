import SwiftUI

// MARK: - Live status

/// The hook install and the notification permission — the two pieces of plumbing
/// without which Uncoil cannot tell the user anything is happening.
struct OnboardingLiveStatusStep: View {
    @ObservedObject private var authorization = NotificationAuthorization.shared
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var hookStatus = HookInstaller.status()
    @State private var hookError: String?
    @State private var working = false

    private var installed: Bool { hookStatus == .installed }

    var body: some View {
        OnboardingScaffold(
            step: .liveStatus,
            title: String(localized: "Let Uncoil see what your agents are doing"),
            subtitle: String(localized: "Claude Code reports through hooks. Without them a session is just a terminal: no working / needs-input state, no notifications, no attention list."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                OnboardingCard(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: String(localized: "Status hooks"),
                    badge: installed
                        ? String(localized: "Installed")
                        : String(localized: "Not installed"),
                    badgeTint: installed ? Theme.ok : Theme.warn,
                    detail: String(localized: "Uncoil adds its own entries to ~/.claude/settings.json and nothing else: a timestamped backup is written first, your own hooks are preserved byte for byte, and the file is re-parsed before it is saved.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(HookInstaller.managedEvents.joined(separator: " · "))
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)

                        if case .partiallyInstalled(let missing) = hookStatus {
                            Text("Missing: \(missing.joined(separator: ", "))")
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.warn)
                        }
                        if let hookError {
                            Text(hookError)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !installed {
                            Button(String(localized: "Install hooks")) { installHooks() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(working)
                                .accessibilityIdentifier("onboarding.installHooks")
                        }
                    }
                }

                OnboardingCard(
                    symbol: "bell.badge",
                    title: String(localized: "Notifications"),
                    badge: authorization.status.label,
                    badgeTint: authorization.status == .granted ? Theme.ok : Theme.warn,
                    detail: String(localized: "macOS only offers its prompt once. Uncoil notifies when an agent needs input, finishes, or asks for a permission.")
                ) {
                    HStack(spacing: 10) {
                        Button(String(localized: "Allow notifications")) {
                            Task { _ = await authorization.request() }
                        }
                        .buttonStyle(GhostButtonStyle())
                        .accessibilityIdentifier("onboarding.requestNotifications")

                        Button(String(localized: "Send a test")) {
                            Task { await authorization.sendTestNotification() }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(.small, .semibold))
                        .foregroundStyle(Theme.highlight)
                    }
                }

                OnboardingSkipLink(action: onSkip)
            }
        }
        .task { await authorization.refresh() }
    }

    private func installHooks() {
        working = true
        hookError = nil
        do {
            try HookInstaller.install()
        } catch {
            hookError = error.localizedDescription
        }
        hookStatus = HookInstaller.status()
        working = false
    }
}

// MARK: - Agent capabilities (MCP)

/// The control plane, explained where it matters: before the first agent runs.
///
/// The toggles are real — they are stamped onto sessions created from here on —
/// but the point of the page is the model behind them: what is on by default,
/// what stays off until asked for, and why a child agent can never escalate.
struct OnboardingCapabilitiesStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var granted: Set<String> = []
    @State private var showHelpSample = false

    private struct Group: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let keys: Set<String>
        /// Off until the user asks for it, and marked as such.
        let isOptional: Bool
    }

    private var groups: [Group] {
        [
            Group(
                id: "projects",
                symbol: "folder",
                title: String(localized: "Projects, worktrees and artifacts"),
                detail: String(localized: "uncoil_projects · uncoil_artifacts — the agent reads your projects, cuts a worktree for itself, and leaves files behind that you can open."),
                keys: ["projects.read", "worktrees.read", "worktrees.create",
                       "artifacts.read", "artifacts.write"],
                isOptional: false
            ),
            Group(
                id: "sessions",
                symbol: "bubble.left.and.bubble.right",
                title: String(localized: "Sessions and child agents"),
                detail: String(localized: "uncoil_sessions — the agent sees the other sessions in its project and can start a child agent. No raw shell is ever accepted: children come from named presets only."),
                keys: ["sessions.read", "sessions.read_all", "sessions.control_children",
                       "sessions.control_all", "sessions.create_children",
                       "sessions.cross_project", "sessions.organize"],
                isOptional: false
            ),
            Group(
                id: "tasks",
                symbol: "checklist",
                title: String(localized: "Reading and ticking tasks"),
                detail: String(localized: "uncoil_tasks — the agent reads your TODO.md and ticks off what it finished. The file stays yours: only the relevant line is patched."),
                keys: ["tasks.read", "tasks.write"],
                isOptional: false
            ),
            Group(
                id: "runs",
                symbol: "play.rectangle",
                title: String(localized: "Running the project"),
                detail: String(localized: "uncoil_run — detects how the project starts, edits that configuration and launches it, so the agent can verify its own change."),
                keys: ["runs.read", "runs.write", "runs.control"],
                isOptional: false
            ),
            Group(
                id: "browser",
                symbol: "globe",
                title: String(localized: "Agent browser"),
                detail: String(localized: "uncoil_browser — an isolated browser profile with no access to your own logins. Installing the driver always asks you first."),
                keys: ["browser.use", "browser.persistent_state"],
                isOptional: false
            ),
            Group(
                id: "computer",
                symbol: "display",
                title: String(localized: "Computer Use"),
                detail: String(localized: "uncoil_computer — sees this Mac's screen and drives its mouse and keyboard. Off until you turn it on, and it needs its own driver."),
                keys: ["computer.inspect", "computer.background_control",
                       "computer.foreground_control"],
                isOptional: true
            ),
            Group(
                id: "orchestrate",
                symbol: "arrow.triangle.branch",
                title: String(localized: "Task orchestration and worktrees"),
                detail: String(localized: "Lets an agent hand a task to another agent and cut a worktree for it."),
                keys: ["tasks.orchestrate", "tasks.worktree"],
                isOptional: true
            ),
            Group(
                id: "taskWrite",
                symbol: "trash",
                title: String(localized: "Deleting and merging tasks"),
                detail: String(localized: "Destroying work and asking for a merge stay with you unless you grant them."),
                keys: ["tasks.delete", "tasks.merge"],
                isOptional: true
            ),
        ]
    }

    var body: some View {
        OnboardingScaffold(
            step: .capabilities,
            title: String(localized: "What your agents may do"),
            subtitle: String(localized: "Uncoil hands every session an MCP server of its own, so the agent can talk back: eight tools, each one gated by a capability you control."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: apply,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    OnboardingCard(
                        symbol: group.symbol,
                        title: group.title,
                        badge: group.isOptional ? String(localized: "Opt-in") : nil,
                        badgeTint: group.isOptional ? Theme.warn : nil,
                        detail: group.detail,
                        toggle: Binding(
                            get: { group.keys.isSubset(of: granted) },
                            set: { isOn in
                                if isOn { granted.formUnion(group.keys) }
                                else { granted.subtract(group.keys) }
                            }
                        )
                    )
                }

                DisclosureGroup(isExpanded: $showHelpSample) {
                    Text("""
                    > uncoil_tasks {"action":"help"}
                    { "tool": "uncoil_tasks",
                      "actions": ["list", "get", "update", "dispatch", …],
                      "requires": ["tasks.read", "tasks.write"] }
                    """)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                } label: {
                    Text("How does the agent find these?")
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 4)

                Text("Every tool answers {\"action\":\"help\"} with its own actions, so an agent discovers what it may do. A child agent's grants are intersected with its parent's — never widened. You can change all of this later in Settings › Privacy and Permissions.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingSkipLink(action: onSkip)
            }
        }
        .onAppear { granted = settings.effectiveSessionCapabilities }
    }

    private func apply() {
        settings.setSessionCapabilityDefaults(granted)
        onContinue()
    }
}
