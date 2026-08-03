import SwiftUI

// MARK: - Status hooks

/// The hook install, which is Claude Code's mechanism and nobody else's.
///
/// On a Mac without Claude Code the page says so and offers nothing to install:
/// asking someone to write into `~/.claude/settings.json` for a CLI they do not
/// have is how a setup screen loses its credibility.
struct OnboardingHooksStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var hookStatus = HookInstaller.status()
    @State private var hookError: String?
    @State private var working = false

    private var installed: Bool { hookStatus == .installed }
    private var hasClaude: Bool { settings.binaryPath(for: .claude) != nil }
    private var hasCodex: Bool { settings.binaryPath(for: .codex) != nil }

    var body: some View {
        OnboardingScaffold(
            step: .hooks,
            title: String(localized: "Let Uncoil see what your agents are doing"),
            subtitle: String(localized: "Claude Code reports its state through hooks. Without them a Claude session is just a terminal: no working / needs-input state, no notifications, no attention list."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                if hasClaude {
                    OnboardingCard(
                        leading: { ProviderMark(provider: .claude, size: 18) },
                        title: String(localized: "Claude Code status hooks"),
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
                } else {
                    OnboardingCard(
                        symbol: "questionmark.folder",
                        title: String(localized: "Claude Code is not installed"),
                        detail: String(localized: "Hooks are Claude Code's own mechanism, so there is nothing to install here. If you add Claude Code later, come back through “Finish setup” in the sidebar — or Settings › Integrations › Agent Status Hooks.")
                    )
                }

                if hasCodex {
                    OnboardingCard(
                        leading: { ProviderMark(provider: .codex, size: 18) },
                        title: String(localized: "Codex needs nothing installed"),
                        badge: String(localized: "No setup"),
                        badgeTint: Theme.ok,
                        detail: String(localized: "Codex has no hook system. Uncoil follows its sessions through the CLI itself — its own output and the rollout files it writes — so its global config is left alone.")
                    )
                }

                OnboardingSkipLink(action: onSkip)
            }
        }
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

// MARK: - Notifications

/// The system permission — which macOS only ever offers once — and the events
/// worth being interrupted for.
struct OnboardingNotificationsStep: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var authorization = NotificationAuthorization.shared
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    private var granted: Bool { authorization.status == .granted }

    var body: some View {
        OnboardingScaffold(
            step: .notifications,
            title: String(localized: "Be told when an agent needs you"),
            subtitle: String(localized: "An agent that finished, or that is stuck waiting for an answer, is worth knowing about without watching the window."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                OnboardingCard(
                    symbol: "bell.badge",
                    title: String(localized: "macOS permission"),
                    badge: authorization.status.label,
                    badgeTint: granted ? Theme.ok : Theme.warn,
                    detail: String(localized: "macOS only offers its prompt once. If it was already denied, the button opens System Settings instead.")
                ) {
                    HStack(spacing: 12) {
                        Button(authorization.status == .denied
                               ? String(localized: "Open System Settings")
                               : String(localized: "Allow notifications")) {
                            if authorization.status == .denied {
                                authorization.openSystemSettings()
                            } else {
                                Task { _ = await authorization.request() }
                            }
                        }
                        .buttonStyle(granted
                                     ? AnyButtonStyle(GhostButtonStyle())
                                     : AnyButtonStyle(AccentButtonStyle()))
                        .accessibilityIdentifier("onboarding.requestNotifications")

                        Button(String(localized: "Send a test")) {
                            Task { await authorization.sendTestNotification() }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.ui(.small, .semibold))
                        .foregroundStyle(Theme.highlight)
                        .accessibilityIdentifier("onboarding.testNotification")
                    }
                    .padding(.top, 2)
                }

                OnboardingCard(
                    symbol: "list.bullet.rectangle",
                    title: String(localized: "What gets announced"),
                    detail: String(localized: "Needs input · permission request · turn finished · error · task done · merge ready · login needed. Each carries its own switch, priority and sound in Settings › Notifications.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { settings.notifications.onlyWhenBackgrounded },
                            set: { settings.notifications.onlyWhenBackgrounded = $0; settings.save() }
                        )) {
                            Text("Only while Uncoil is in the background")
                                .font(Theme.ui(.body))
                                .foregroundStyle(Theme.textDim)
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("onboarding.notifyBackgroundOnly")

                        Toggle(isOn: Binding(
                            get: { settings.notifications.suppressForVisibleSession },
                            set: { settings.notifications.suppressForVisibleSession = $0; settings.save() }
                        )) {
                            Text("Stay quiet about the session already on screen")
                                .font(Theme.ui(.body))
                                .foregroundStyle(Theme.textDim)
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("onboarding.notifySuppressVisible")
                    }
                    .padding(.top, 2)
                }

                Text("Reminders, quiet hours and per-project rules live in Settings › Notifications.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)

                OnboardingSkipLink(action: onSkip)
            }
        }
        .task { await authorization.refresh() }
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
                detail: String(localized: "uncoil_browser — driven by the optional agent-browser driver over a Playwright-managed Chromium, in a blank profile with no access to your own logins. Installing that driver always asks you first."),
                keys: ["browser.use", "browser.persistent_state"],
                isOptional: false
            ),
            Group(
                id: "computer",
                symbol: "display",
                title: String(localized: "Computer Use"),
                detail: String(localized: "uncoil_computer — sees this Mac's screen and drives its mouse and keyboard through the optional cua-driver, which also needs macOS's Screen Recording and Accessibility permissions. Off until you turn it on."),
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
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                } label: {
                    Text("How does the agent find these?")
                        .font(Theme.ui(.body))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 4)

                Text("Every tool answers {\"action\":\"help\"} with its own actions, so an agent discovers what it may do. A child agent's grants are intersected with its parent's — never widened. You can change all of this later in Settings › Security and Data › Permissions.")
                    .font(Theme.ui(.small))
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
