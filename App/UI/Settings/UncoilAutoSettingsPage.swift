import AppKit
import SwiftUI

/// Settings › Agents › Uncoil Auto.
///
/// Uncoil Auto is not an agent CLI — it has no binary, login or version — so
/// it does not share `AgentSettingsPage`. What it has instead: which agents a
/// conversation may reach, and, in Edge builds, the effort advisor with the
/// model that powers it.
struct UncoilAutoSettingsPage: View {
    let back: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var sidecar = LayaSidecar.shared
    @State private var ladders: [AgentProvider: EffortLadder] = [:]
    @State private var logCount = 0

    private var isEdge: Bool { UpdateChannel.installed() == .edge }
    private var advisor: EffortAdvisorSettings { settings.uncoilAuto.advisor }
    private var installed: [AgentProvider] {
        AgentProvider.agents.filter { settings.installedProviders.contains($0) }
    }
    private var log: EffortDecisionLog { EffortDecisionLog(url: EffortDecisionLog.defaultURL) }

    var body: some View {
        SettingsPage(
            title: String(localized: "Uncoil Auto"),
            subtitle: String(localized: "Which agents a conversation can reach, and how much effort it suggests for each prompt."),
            back: (String(localized: "Installed Agents"), back)
        ) {
            reach
            notifications
            if isEdge {
                effortAdvisor
                if advisor.enabled {
                    effortRanges
                    if advisor.engine == .laya { runtime }
                    decisionLog
                }
            }
        }
        .task {
            sidecar.refresh()
            logCount = log.count
            for provider in installed {
                ladders[provider] = await EffortLadder.detect(provider, settings: settings)
            }
        }
    }

    // MARK: - Reach

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

    // MARK: - Notifications

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

    // MARK: - Effort advisor

    private var effortAdvisor: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                SettingsLabel(
                    title: String(localized: "Suggest an effort for each prompt"),
                    detail: String(localized: "Shown above the composer. Nothing is sent to an agent until you click Apply."))
            }
            .settingsID("uncoilAuto.advisor.enabled")

            if advisor.enabled {
                Picker(selection: binding(\.engine)) {
                    Text("Heuristic").tag(EffortAdvisorSettings.Engine.heuristic)
                    Text("Laya (local model)").tag(EffortAdvisorSettings.Engine.laya)
                } label: {
                    SettingsLabel(
                        title: String(localized: "Engine"),
                        detail: advisor.engine == .laya
                            ? String(localized: "A System 1 decision model on this Mac, via MLX. Falls back to the heuristic while it is not running.")
                            : String(localized: "Prompt length and a few words, in English and Turkish."))
                }
                .settingsID("uncoilAuto.advisor.engine")

                Picker(selection: binding(\.confidenceThreshold)) {
                    Text("Always").tag(0.0)
                    Text("20%").tag(0.2)
                    Text("30%").tag(0.3)
                    Text("50%").tag(0.5)
                    Text("70%").tag(0.7)
                } label: {
                    SettingsLabel(
                        title: String(localized: "Show when at least this sure"),
                        detail: String(localized: "How much of the model's probability lands on the suggested level."))
                }
                .settingsID("uncoilAuto.advisor.threshold")
            }
        } header: {
            HStack(spacing: 6) {
                Text("Effort advisor")
                Text("Edge")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.warnSurface, in: Capsule())
            }
        } footer: {
            SettingsNote(String(localized: "Experimental. Picks within the range you allow below, so simple prompts do not spend your plan on high effort."))
        }
    }

    private var effortRanges: some View {
        Section {
            ForEach(installed) { provider in
                EffortRangeRow(
                    provider: provider,
                    ladder: ladders[provider],
                    policy: advisor.policy(for: provider),
                    onChange: { policy in
                        settings.updateUncoilAuto { $0.advisor.perAgent[provider.rawValue] = policy }
                    })
            }
        } header: {
            Text("Effort range per agent")
        } footer: {
            SettingsNote(String(localized: "Levels are read from each installed CLI. An agent without an effort setting gets no suggestion."))
        }
    }

    // MARK: - Model runtime

    private var runtime: some View {
        Section {
            SettingsStatusLine(level: runtimeLevel, text: runtimeText)
            SettingsDetailLine(label: String(localized: "Package"), value: LayaSidecar.package)
            SettingsDetailLine(label: String(localized: "Models"), value: LayaSidecar.checkpoints.joined(separator: ", "))
            SettingsDetailLine(label: String(localized: "Location"), value: sidecar.root.path, wraps: true)
            SettingsActionRow(
                isWorking: isBusy,
                note: failureNote,
                noteLevel: .error
            ) {
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
                    Button(String(localized: "Stop")) { sidecar.stop() }
                case .installing, .starting:
                    EmptyView()
                }
                Button(String(localized: "Check Again")) { sidecar.refresh() }
                if sidecar.isInstalled {
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([sidecar.root])
                    }
                    Button(String(localized: "Remove"), role: .destructive) { sidecar.uninstall() }
                }
            }
        } header: {
            Text("Model runtime")
        } footer: {
            SettingsNote(String(localized: "Install uses uv to create a Python environment and download about 1.4 GB of model weights, all inside the location above. Nothing is downloaded until you click Install. The server listens on 127.0.0.1 only and stops when Uncoil quits."))
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
        case .notInstalled: String(localized: "Not installed — suggestions use the heuristic.")
        case .installing(let step): String(localized: "\(step)…")
        case .installed: String(localized: "Installed; starts when a conversation asks for a suggestion.")
        case .starting: String(localized: "Starting…")
        case .ready(let port): String(localized: "Running on 127.0.0.1:\(port)")
        case .failed(let message): message
        }
    }

    private var failureNote: String? {
        guard case .failed = sidecar.state, let log = sidecar.lastLog else { return nil }
        return String(log.suffix(1_200))
    }

    // MARK: - Decision log

    private var decisionLog: some View {
        Section {
            Toggle(isOn: binding(\.keepDecisionLog)) {
                SettingsLabel(
                    title: String(localized: "Keep a decision log"),
                    detail: String(localized: "Each sent prompt, the suggestion and how the turn went, one line each. It stays on this Mac; it is what a fine-tuned model would learn from."))
            }
            .settingsID("uncoilAuto.log.enabled")
            SettingsActionRow {
                Text("\(logCount) decisions")
                    .foregroundStyle(Theme.textDim)
                Button(String(localized: "Reveal in Finder")) {
                    let url = log.url
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()])
                }
                Button(String(localized: "Clear"), role: .destructive) {
                    log.clear()
                    logCount = 0
                }
                .disabled(logCount == 0)
            }
        } header: {
            Text("Decision log")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EffortAdvisorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings.uncoilAuto.advisor[keyPath: keyPath] },
            set: { value in settings.updateUncoilAuto { $0.advisor[keyPath: keyPath] = value } })
    }
}

/// One agent: whether it gets suggestions, and between which levels. Two
/// Form rows rather than one stacked row, so each lays out like every other
/// settings row.
private struct EffortRangeRow: View {
    let provider: AgentProvider
    let ladder: EffortLadder?
    let policy: AgentEffortPolicy
    let onChange: (AgentEffortPolicy) -> Void

    var body: some View {
        if let ladder, !ladder.isEmpty, let range = policy.range(in: ladder) {
            Toggle(isOn: Binding(
                get: { policy.enabled },
                set: { var next = policy; next.enabled = $0; onChange(next) }
            )) {
                label(detail: ladder.levels.joined(separator: " · "))
            }
            .settingsID("uncoilAuto.range.\(provider.rawValue).enabled")
            if policy.enabled {
                LabeledContent {
                    HStack(spacing: 6) {
                        Picker(String(localized: "From"), selection: Binding(
                            get: { ladder.levels[range.lowerBound] },
                            set: { var next = policy; next.minimum = $0; onChange(next) }
                        )) {
                            ForEach(ladder.levels.prefix(range.upperBound + 1), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .settingsID("uncoilAuto.range.\(provider.rawValue).min")
                        Text("to").foregroundStyle(Theme.textDim)
                        Picker(String(localized: "To"), selection: Binding(
                            get: { ladder.levels[range.upperBound] },
                            set: { var next = policy; next.maximum = $0; onChange(next) }
                        )) {
                            ForEach(ladder.levels.suffix(from: range.lowerBound), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .settingsID("uncoilAuto.range.\(provider.rawValue).max")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                } label: {
                    SettingsLabel(
                        title: String(localized: "Range"),
                        detail: String(localized: "Suggestions for \(provider.displayName) stay between these."))
                        .padding(.leading, 22)
                }
            }
        } else {
            label(detail: ladder == nil
                  ? String(localized: "Reading the CLI…")
                  : String(localized: "No effort control in this CLI."))
        }
    }

    private func label(detail: String) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: provider, size: 14)
            SettingsLabel(title: provider.displayName, detail: detail)
        }
    }
}
