import AppKit
import SwiftUI

/// Settings › Agents › Uncoil Auto.
///
/// Uncoil Auto is not an agent CLI — it has no binary, login or version — so
/// it does not share `AgentSettingsPage`. What it has instead: which agents a
/// conversation may reach, and how an Auto run is staffed and decided, in
/// five areas so no screen holds all of it at once.
struct UncoilAutoSettingsPage: View {
    let back: () -> Void

    enum Area: String, CaseIterable, Identifiable {
        case general, roles, advisor, decisions, policy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .roles: String(localized: "Roles")
            case .advisor: String(localized: "Advisor")
            case .decisions: String(localized: "Laya")
            case .policy: String(localized: "Policy")
            }
        }
    }

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var sidecar = LayaSidecar.shared
    @State private var area: Area
    @State private var catalogs: [AgentProvider: AgentLaunchCapabilities] = [:]

    init(back: @escaping () -> Void, area: Area = .general) {
        self.back = back
        _area = State(initialValue: area)
    }

    private var harness: AutoHarnessSettings { settings.uncoilAuto.harness }
    private var installed: [AgentProvider] {
        AgentProvider.agents.filter { settings.installedProviders.contains($0) }
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "Uncoil Auto"),
            subtitle: String(localized: "Which agents a conversation can reach, and how an Auto run works: Main owns the task, specialists do focused work, the Advisor reviews, Laya takes small decisions and verification checks the result."),
            back: (String(localized: "Installed Agents"), back)
        ) {
            Section {
                Picker(String(localized: "Area"), selection: $area) {
                    ForEach(Area.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .settingsID("uncoilAuto.area")
            }
            switch area {
            case .general:
                general
                reach
                notifications
            case .roles:
                mainRole
                ForEach([AutoRole.explorer, .worker, .researcher]) { role in
                    AutoRoleSection(role: role, installed: installed, catalogs: catalogs)
                }
            case .advisor:
                AutoRoleSection(role: .advisor, installed: installed, catalogs: catalogs)
                advisorCheckpoints
            case .decisions:
                decisionEngine
                ForEach(AutoDecisionKind.allCases) { kind in decisionSection(kind) }
                runtime
            case .policy:
                policy
                limits
            }
        }
        .task {
            sidecar.refresh()
            for provider in installed {
                catalogs[provider] = await AgentLaunchCatalog.detect(
                    provider: provider, binaryPath: settings.binaryPath(for: provider))
            }
        }
    }

    // MARK: - General

    private var general: some View {
        Section {
            Toggle(isOn: harnessBinding(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Auto runs"),
                    detail: String(localized: "Off: /auto is refused and every message goes to an agent as before."))
            }
            .settingsID("uncoilAuto.enabled")
            Picker(selection: harnessBinding(\.mode)) {
                Text("Only with /auto").tag(AutoExecutionMode.onCommand)
                Text("Every message naming no agent").tag(AutoExecutionMode.everyMessage)
            } label: {
                SettingsLabel(
                    title: String(localized: "What starts a run"),
                    detail: String(localized: "A message that names an agent with @ always goes straight to it."))
            }
            .settingsID("uncoilAuto.mode")
            Picker(selection: harnessBinding(\.policy.specialistFailure)) {
                Text("Carry on without it").tag(AutoSpecialistFailure.continueWithoutIt)
                Text("Stop the run").tag(AutoSpecialistFailure.stopRun)
            } label: {
                SettingsLabel(
                    title: String(localized: "When a specialist fails"),
                    detail: String(localized: "A specialist that cannot start, crashes or times out. A Laya failure never stops a run: its decisions fall back to the deterministic policy."))
            }
            .settingsID("uncoilAuto.fallback")
        } header: {
            Text("Auto runs")
        }
    }

    private var reach: some View {
        Section {
            ForEach(installed) { provider in
                Toggle(isOn: Binding(
                    get: { settings.uncoilAuto.allows(provider) },
                    set: { settings.setUncoilAutoAllows(provider, $0) }
                )) {
                    HStack(spacing: 8) {
                        ProviderMark(provider: provider, size: 14)
                        Text(provider.displayName)
                    }
                }
                .settingsID("uncoilAuto.reach.\(provider.rawValue)")
            }
            if installed.isEmpty {
                SettingsStatusLine(level: .warning, text: String(localized: "No agent CLI is installed yet."))
            }
        } header: {
            Text("Agents Uncoil Auto can reach")
        } footer: {
            SettingsNote(String(localized: "An agent turned off here cannot be addressed or started from any Uncoil Auto conversation. Each conversation can narrow this further from its agents panel."))
        }
    }

    private var notifications: some View {
        Section {
            Picker(selection: Binding(
                get: { settings.uncoilAuto.notifications },
                set: { mode in settings.updateUncoilAuto { $0.notifications = mode } }
            )) {
                Text("As usual").tag(DirectedAgentNotifications.asUsual)
                Text("Not while the conversation is on screen").tag(DirectedAgentNotifications.whenConversationHidden)
                Text("Only permission requests").tag(DirectedAgentNotifications.permissionsOnly)
            } label: {
                SettingsLabel(
                    title: String(localized: "Notifications from directed agents"),
                    detail: notificationDetail)
            }
            .settingsID("uncoilAuto.notifications")
        } header: {
            Text("Notifications")
        } footer: {
            SettingsNote(String(localized: "Applies only to agents an Uncoil Auto conversation has spoken to. Every other session notifies exactly as set in Notifications."))
        }
    }

    private var notificationDetail: String {
        switch settings.uncoilAuto.notifications {
        case .asUsual:
            String(localized: "Waiting for input, turn done and permission requests notify like any session.")
        case .whenConversationHidden:
            String(localized: "Held back while you are looking at the conversation that directs the agent; it shows them there.")
        case .permissionsOnly:
            String(localized: "Replies and waits stay in the conversation. A permission request still notifies when the conversation is not on screen — it is the one thing it cannot answer.")
        }
    }

    // MARK: - Roles

    private var mainRole: some View {
        Section {
            SettingsDetailLine(label: String(localized: "Main agent"), value: String(localized: "The conversation's target"))
            SettingsNote(String(localized: "Main is the agent chosen with the button beside the composer, running with the model and effort you launched it with. Auto orchestrates around it and never replaces it: it owns the plan, reads the specialists' results and gives the final answer."))
        } header: {
            Text("Main")
        }
    }

    // MARK: - Advisor

    private var advisorCheckpoints: some View {
        Section {
            Toggle(isOn: harnessBinding(\.advisorCheckpoints.beforePlan)) {
                SettingsLabel(title: String(localized: "Before the plan is carried out"),
                              detail: String(localized: "Is this approach targeting the right problem?"))
            }
            .settingsID("uncoilAuto.advisor.beforePlan")
            Toggle(isOn: harnessBinding(\.advisorCheckpoints.onRepeatedFailure)) {
                SettingsLabel(title: String(localized: "When the same failure repeats"),
                              detail: String(localized: "Are repeated failures a sign the wrong layer is being debugged?"))
            }
            .settingsID("uncoilAuto.advisor.onRepeatedFailure")
            Toggle(isOn: harnessBinding(\.advisorCheckpoints.beforeCompletion)) {
                SettingsLabel(title: String(localized: "Before completion"),
                              detail: String(localized: "Off: Laya's completion decision may still recommend a review, when you make it active."))
            }
            .settingsID("uncoilAuto.advisor.beforeCompletion")
        } header: {
            Text("Checkpoints")
        } footer: {
            SettingsNote(String(localized: "The Advisor is an Uncoil-managed session that receives a compact packet at each checkpoint — no provider's native advisor facility is used, so any agent and model can advise. One session per run, reused across its checkpoints."))
        }
    }

    // MARK: - Decisions

    private var decisionEngine: some View {
        Section {
            Toggle(isOn: harnessBinding(\.decisions.enabled)) {
                SettingsLabel(
                    title: String(localized: "Ask Laya"),
                    detail: String(localized: "Off: every decision is the deterministic policy's, and nothing is recorded as Laya's."))
            }
            .settingsID("uncoilAuto.decisions.enabled")
            Picker(selection: harnessBinding(\.decisions.checkpoint)) {
                Text("Automatic (by language)").tag("auto")
                ForEach(LayaSidecar.checkpoints, id: \.self) { Text($0).tag($0) }
            } label: {
                SettingsLabel(title: String(localized: "Checkpoint"))
            }
            .settingsID("uncoilAuto.decisions.checkpoint")
            Picker(selection: harnessBinding(\.decisions.timeoutMilliseconds)) {
                Text("0.5 s").tag(500)
                Text("1.5 s").tag(1_500)
                Text("3 s").tag(3_000)
                Text("10 s").tag(10_000)
            } label: {
                SettingsLabel(title: String(localized: "Decision timeout"),
                              detail: String(localized: "A slower answer is dropped for the deterministic one."))
            }
            .settingsID("uncoilAuto.decisions.timeout")
            Picker(selection: harnessBinding(\.decisions.minimumConfidence)) {
                Text("Any").tag(0.0)
                Text("50%").tag(0.5)
                Text("70%").tag(0.7)
                Text("85%").tag(0.85)
            } label: {
                SettingsLabel(title: String(localized: "Act only when at least this sure"),
                              detail: String(localized: "For active decisions. Below it, the deterministic policy acts and the diagnostics say why."))
            }
            .settingsID("uncoilAuto.decisions.confidence")
        } header: {
            HStack(spacing: 6) {
                Text("Decision engine")
                Text("Experimental")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.warnSurface, in: Capsule())
            }
        } footer: {
            SettingsNote(String(localized: "Laya is a small local model for bounded control decisions. It never plans, writes code, grants a permission or replaces verification: budgets, thresholds and checkpoints sit above it, and a high probability is not an approval."))
        }
    }

    private func decisionSection(_ kind: AutoDecisionKind) -> some View {
        let schema = kind.schema
        return Section {
            Picker(selection: Binding(
                get: { harness.decisions.authority[kind.rawValue] ?? .shadow },
                set: { value in settings.updateAutoHarness { $0.decisions.authority[kind.rawValue] = value } }
            )) {
                Text("Off").tag(AutoDecisionAuthority.off)
                Text("Shadow — record only").tag(AutoDecisionAuthority.shadow)
                Text("Active — Laya decides").tag(AutoDecisionAuthority.active)
            } label: {
                SettingsLabel(title: schema.title, detail: schema.question)
            }
            .settingsID("uncoilAuto.decisions.\(kind.rawValue)")
            ForEach(schema.options, id: \.id) { option in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.id).font(.system(.callout, design: .monospaced).weight(.medium))
                        if option.id == schema.fallback {
                            Text("deterministic default")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.panelHover, in: Capsule())
                        }
                    }
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var runtime: some View {
        Section {
            SettingsStatusLine(level: runtimeLevel, text: runtimeText)
            SettingsDetailLine(label: String(localized: "Package"), value: LayaSidecar.package)
            SettingsDetailLine(label: String(localized: "Models"), value: LayaSidecar.checkpoints.joined(separator: ", "))
            SettingsDetailLine(label: String(localized: "Location"), value: sidecar.root.path, wraps: true)
            SettingsDetailLine(
                label: String(localized: "Decisions"),
                value: String(localized: "\(sidecar.stats.answered) answered, \(sidecar.stats.failed) failed, \(sidecar.stats.restarts) restarts")
                    + (sidecar.stats.lastLatencyMilliseconds.map { String(format: " · last %.0f ms", $0) } ?? ""))
            if let error = sidecar.stats.lastError {
                SettingsDetailLine(label: String(localized: "Last error"), value: error, wraps: true, level: .warning)
            }
            ForEach(sidecar.health.keys.sorted(), id: \.self) { key in
                SettingsDetailLine(label: key, value: sidecar.health[key] ?? "", wraps: true)
            }
            SettingsActionRow(isWorking: isBusy, note: failureNote, noteLevel: .error) {
                switch sidecar.state {
                case .notInstalled, .unknown, .failed:
                    if sidecar.isInstalled {
                        Button(String(localized: "Start")) { Task { await sidecar.ensureRunning() } }
                    } else {
                        Button(String(localized: "Install")) { Task { await sidecar.install() } }
                            .buttonStyle(.borderedProminent)
                            .settingsID("uncoilAuto.runtime.install")
                    }
                case .installed:
                    Button(String(localized: "Start")) { Task { await sidecar.ensureRunning() } }
                case .ready:
                    Button(String(localized: "Restart")) { Task { await sidecar.restart() } }
                    Button(String(localized: "Stop")) { sidecar.stop() }
                    Button(String(localized: "Check Health")) { Task { await sidecar.checkHealth() } }
                case .installing, .starting:
                    EmptyView()
                }
                if sidecar.isInstalled {
                    Button(String(localized: "Update")) { Task { await sidecar.install() } }
                        .help(String(localized: "Reinstall the pinned package and fetch the models again"))
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([sidecar.root])
                    }
                    Button(String(localized: "Remove"), role: .destructive) { sidecar.uninstall() }
                }
            }
        } header: {
            Text("Laya runtime")
        } footer: {
            SettingsNote(String(localized: "Install uses uv to create a Python environment and download about 1.4 GB of model weights, all inside the location above. Nothing is downloaded until you click Install. The server listens on 127.0.0.1 only, stays loaded while Uncoil runs, is started again if it stops, and quits with Uncoil."))
        }
    }

    private var isBusy: Bool {
        switch sidecar.state {
        case .installing, .starting: true
        default: false
        }
    }

    private var runtimeLevel: SettingsStatusLine.Level {
        switch sidecar.state {
        case .ready: .ok
        case .failed: .error
        case .notInstalled: .warning
        default: .neutral
        }
    }

    private var runtimeText: String {
        switch sidecar.state {
        case .unknown: String(localized: "Checking…")
        case .notInstalled: String(localized: "Not installed — every decision is the deterministic policy's.")
        case .installing(let step): String(localized: "\(step)…")
        case .installed: String(localized: "Installed; starts when a run has a decision to ask.")
        case .starting: String(localized: "Starting…")
        case .ready(let port): String(localized: "Running on 127.0.0.1:\(port)")
        case .failed(let message): message
        }
    }

    private var failureNote: String? {
        guard case .failed = sidecar.state, let log = sidecar.lastLog else { return nil }
        return String(log.suffix(1_200))
    }

    // MARK: - Policy

    private var policy: some View {
        Section {
            Toggle(isOn: harnessBinding(\.policy.parallelSpecialists)) {
                SettingsLabel(title: String(localized: "Explore and research in parallel"))
            }
            .settingsID("uncoilAuto.policy.parallel")
            Picker(selection: harnessBinding(\.policy.research)) {
                Text("Never").tag(AutoResearchMode.never)
                Text("When needed").tag(AutoResearchMode.whenNeeded)
                Text("Always").tag(AutoResearchMode.always)
            } label: {
                SettingsLabel(title: String(localized: "Research"),
                              detail: String(localized: "When needed: the research gate decides, deterministically or with Laya."))
            }
            .settingsID("uncoilAuto.policy.research")
            Toggle(isOn: harnessBinding(\.policy.mainReviewsSpecialistResults)) {
                SettingsLabel(title: String(localized: "Main reviews specialist results"),
                              detail: String(localized: "Off: the Worker gets the Explorer's and Researcher's reports as they are, without a planning turn."))
            }
            .settingsID("uncoilAuto.policy.mainReview")
            Toggle(isOn: harnessBinding(\.policy.alwaysVerify)) {
                SettingsLabel(title: String(localized: "Always verify before completion"),
                              detail: String(localized: "Runs the project's default test suite after every Worker turn."))
            }
            .settingsID("uncoilAuto.policy.verify")
            Toggle(isOn: harnessBinding(\.policy.requireTestsWhenAvailable)) {
                SettingsLabel(title: String(localized: "Require tests when available"),
                              detail: String(localized: "A declared or detected suite must pass, whatever the Worker reports."))
            }
            .settingsID("uncoilAuto.policy.tests")
            Stepper(value: harnessBinding(\.policy.repeatedFailureThreshold), in: 1...6) {
                SettingsLabel(title: String(localized: "Repeated failure after \(harness.policy.repeatedFailureThreshold) in a row"),
                              detail: String(localized: "Goes to the Advisor when its checkpoint is on, otherwise back to Main. Policy, not Laya."))
            }
            .settingsID("uncoilAuto.policy.repeated")
            Stepper(value: harnessBinding(\.policy.maxMainRevisions), in: 0...5) {
                SettingsLabel(title: String(localized: "New briefs from Main: \(harness.policy.maxMainRevisions)"),
                              detail: String(localized: "Times a failing Worker is sent back to Main before the run stops and hands over to you."))
            }
            .settingsID("uncoilAuto.policy.revisions")
        } header: {
            Text("Execution")
        }
    }

    private var limits: some View {
        Section {
            Stepper(value: harnessBinding(\.policy.maxChildSessions), in: 1...20) {
                SettingsLabel(title: String(localized: "Child sessions per run: \(harness.policy.maxChildSessions)"))
            }
            .settingsID("uncoilAuto.policy.children")
            Stepper(value: harnessBinding(\.policy.maxConcurrentSpecialists), in: 1...4) {
                SettingsLabel(title: String(localized: "Specialists at once: \(harness.policy.maxConcurrentSpecialists)"))
            }
            .settingsID("uncoilAuto.policy.concurrent")
            Stepper(value: harnessBinding(\.policy.maxRunMinutes), in: 10...480, step: 10) {
                SettingsLabel(title: String(localized: "Whole run: \(harness.policy.maxRunMinutes) min"),
                              detail: String(localized: "After this the run stops where it is."))
            }
            .settingsID("uncoilAuto.policy.runtime")
            Toggle(isOn: harnessBinding(\.policy.stopSpecialistsWhenDone)) {
                SettingsLabel(title: String(localized: "Stop specialists when the run ends"),
                              detail: String(localized: "Their sessions stay in the sidebar either way."))
            }
            .settingsID("uncoilAuto.policy.stopSpecialists")
            Toggle(isOn: harnessBinding(\.policy.removeEmptyWorktrees)) {
                SettingsLabel(title: String(localized: "Remove a Worker worktree left without changes"))
            }
            .settingsID("uncoilAuto.policy.cleanWorktrees")
        } header: {
            Text("Limits and cleanup")
        }
    }

    private func harnessBinding<Value>(_ keyPath: WritableKeyPath<AutoHarnessSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings.uncoilAuto.harness[keyPath: keyPath] },
            set: { value in settings.updateAutoHarness { $0[keyPath: keyPath] = value } })
    }
}

/// One specialist: who does the job and how.
private struct AutoRoleSection: View {
    let role: AutoRole
    let installed: [AgentProvider]
    let catalogs: [AgentProvider: AgentLaunchCapabilities]

    @EnvironmentObject private var settings: SettingsStore

    private var config: AutoRoleSettings { settings.uncoilAuto.harness.role(role) }
    private var catalog: AgentLaunchCapabilities? { config.provider.flatMap { catalogs[$0] } }

    var body: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                SettingsLabel(title: String(localized: "Use the \(role.displayName)"), detail: purpose)
            }
            .settingsID("uncoilAuto.\(role.rawValue).enabled")
            if config.enabled {
                Picker(selection: Binding(
                    get: { config.provider ?? .claude },
                    set: { provider in
                        update {
                            $0.provider = provider
                            // A model or login chosen for one CLI means nothing to another.
                            $0.model = nil
                            $0.effort = nil
                            $0.accountID = nil
                        }
                    }
                )) {
                    ForEach(installed) { Text($0.displayName).tag($0) }
                    if let provider = config.provider, !installed.contains(provider) {
                        Text("\(provider.displayName) (not installed)").tag(provider)
                    }
                } label: {
                    SettingsLabel(title: String(localized: "Agent"))
                }
                .settingsID("uncoilAuto.\(role.rawValue).provider")
                if let provider = config.provider {
                    let accounts = settings.accounts(for: provider)
                    if accounts.count > 1 {
                        Picker(selection: binding(\.accountID)) {
                            Text("Default login").tag(UUID?.none)
                            ForEach(accounts) { Text($0.name).tag(UUID?.some($0.id)) }
                        } label: {
                            SettingsLabel(title: String(localized: "Account"))
                        }
                        .settingsID("uncoilAuto.\(role.rawValue).account")
                    }
                    optionPicker(String(localized: "Model"), \.model, options: catalog?.models ?? [])
                    optionPicker(String(localized: "Effort"), \.effort, options: catalog?.efforts ?? [])
                }
                if role.readsOnly {
                    Toggle(isOn: binding(\.readOnly)) {
                        SettingsLabel(title: String(localized: "Read-only"),
                                      detail: String(localized: "Claude starts without its editing tools; Codex starts in its read-only sandbox."))
                    }
                    .settingsID("uncoilAuto.\(role.rawValue).readOnly")
                }
                if role == .worker {
                    Toggle(isOn: binding(\.worktreeIsolation)) {
                        SettingsLabel(title: String(localized: "Work in its own worktree"),
                                      detail: String(localized: "A fresh uncoil/ branch per run. Its changes are never merged for you."))
                    }
                    .settingsID("uncoilAuto.worker.worktree")
                    Stepper(value: binding(\.maxRetries), in: 0...6) {
                        SettingsLabel(title: String(localized: "Retries after a failed verification: \(config.maxRetries)"))
                    }
                    .settingsID("uncoilAuto.worker.retries")
                }
                Stepper(value: binding(\.maxRuntimeMinutes), in: 2...120) {
                    SettingsLabel(title: String(localized: "Longest turn: \(config.maxRuntimeMinutes) min"))
                }
                .settingsID("uncoilAuto.\(role.rawValue).runtime")
                SettingsTextField(
                    title: String(localized: "Instructions"),
                    detail: String(localized: "Leave empty for the built-in instructions below. The result format the run reads is always added."),
                    prompt: String(localized: "Built-in instructions"),
                    text: binding(\.instructions),
                    lineLimit: 3...10)
                .settingsID("uncoilAuto.\(role.rawValue).instructions")
                DisclosureGroup(String(localized: "Built-in instructions")) {
                    Text(AutoPrompts.defaultInstructions(for: role))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text(role.displayName)
        }
    }

    private var purpose: String {
        switch role {
        case .explorer: String(localized: "Investigates the repository so its search output stays out of Main's context.")
        case .researcher: String(localized: "Looks up documentation, APIs and release notes, and cites them.")
        case .worker: String(localized: "Implements Main's brief, builds and tests it. Off: Main implements the plan itself.")
        case .advisor: String(localized: "A rare deep second opinion — Fable by default — at the checkpoints below.")
        }
    }

    @ViewBuilder
    private func optionPicker(
        _ title: String, _ keyPath: WritableKeyPath<AutoRoleSettings, String?>,
        options: [AgentLaunchCapabilities.Option]
    ) -> some View {
        let current = config[keyPath: keyPath]
        Picker(selection: binding(keyPath)) {
            Text("CLI default").tag(String?.none)
            ForEach(options) { Text($0.label).tag(String?.some($0.id)) }
            if let current, !options.contains(where: { $0.id == current }) {
                Text(current).tag(String?.some(current))
            }
        } label: {
            SettingsLabel(title: title)
        }
        .settingsID("uncoilAuto.\(role.rawValue).\(title.lowercased())")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutoRoleSettings, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout AutoRoleSettings) -> Void) {
        settings.updateAutoHarness { harness in
            var role = harness.role(self.role)
            change(&role)
            harness.roles[self.role] = role
        }
    }
}
