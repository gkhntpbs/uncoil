import AppKit
import SwiftUI

/// Settings › Integrations › Drivers.
///
/// Both drivers are optional external programs, and installing one always needs
/// the user's say-so — these sections probe, report and offer, they never fetch
/// anything on their own.
///
/// They are described the same way an agent's CLI is described on its own page:
/// a status line, then where the binary is and what version answered. Before
/// this, an installed driver was a word — "ready" or "missing" — and everything
/// else the page knew was dumped in as the tool's raw output, ticks, crosses
/// and all.

// MARK: - The shape both drivers share

/// What came of running something. Kept apart from the tool's own output so the
/// page can say what happened in its own voice and still let the output be read
/// when it is the only thing that explains a failure.
struct DriverOutcome: Equatable {
    var level: SettingsStatusLine.Level
    var summary: String
    var output: String?

    static func output(_ text: String, ok: Bool) -> DriverOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return DriverOutcome(
            level: ok ? .ok : .error,
            summary: ok
                ? String(localized: "Finished.")
                : String(localized: "It did not finish. The output says why."),
            output: trimmed
        )
    }
}

/// One driver: what it is, whether it is here, and what can be done about it.
private struct DriverCard<Actions: View>: View {
    let title: String
    let purpose: String
    let symbol: String
    /// `nil` while the first probe is still running.
    let status: DependencyInfo?
    let state: (level: SettingsStatusLine.Level, text: String)
    let outcome: DriverOutcome?
    @Binding var isShowingOutput: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        AdaptiveRow {
            SettingsLabel(title: title, detail: purpose, symbol: symbol)
        } control: {
            SettingsStatusLine(level: state.level, text: state.text)
        }

        if let status {
            VStack(alignment: .leading, spacing: 2) {
                if let path = status.path {
                    SettingsDetailLine(label: String(localized: "path"), value: path)
                }
                if let version = status.version, !version.isEmpty {
                    SettingsDetailLine(label: String(localized: "version"), value: version)
                }
                if let detail = status.detail, !detail.isEmpty {
                    SettingsDetailLine(
                        label: String(localized: "reports"), value: detail, wraps: true
                    )
                }
                // What to do about it, in the tool's own words, and only while
                // there is something to do.
                if !status.installed, let remedy = status.remedy, !remedy.isEmpty {
                    SettingsDetailLine(
                        label: String(localized: "needs"),
                        value: remedy,
                        wraps: true,
                        level: .warning
                    )
                }
            }
        }

        actions

        if let outcome {
            VStack(alignment: .leading, spacing: 6) {
                SettingsStatusLine(level: outcome.level, text: outcome.summary)
                if let output = outcome.output {
                    // The tool's own output is kept, because on a failure it is
                    // the only thing that explains anything — but it is not the
                    // page's answer, so it stays behind a disclosure.
                    DisclosureGroup(isExpanded: $isShowingOutput) {
                        Text(output)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textFaint)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Output")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }
}

// MARK: - Agent Browser

struct AgentBrowserSetupSection: View {
    @State private var status: DependencyInfo?
    /// A long action the user started. Separate from `isProbing`, because the
    /// probe at the end of an action used to be refused by the very flag the
    /// action had set — so installing the runtime left the page still saying
    /// the runtime was missing until it was refreshed by hand.
    @State private var isWorking = false
    @State private var isProbing = false
    @State private var outcome: DriverOutcome?
    @State private var isShowingOutput = false
    @AppStorage(AgentBrowserAdapter.executablePreferenceKey)
    private var executablePath = ""

    private var choices: [AgentBrowserAdapter.BrowserChoice] {
        let installed = AgentBrowserAdapter.installedBrowserChoices()
        guard !executablePath.isEmpty,
              !installed.contains(where: { $0.executablePath == executablePath })
        else { return installed }
        // The browser that was chosen has since been moved or deleted. Naming
        // it keeps the picker honest; dropping it would leave the control blank
        // and the setting invisibly in force.
        return installed + [
            AgentBrowserAdapter.BrowserChoice(
                id: "missing",
                name: String(localized: "Chosen browser — no longer on this Mac"),
                executablePath: executablePath
            ),
        ]
    }

    var body: some View {
        DriverCard(
            title: String(localized: "Agent Browser"),
            purpose: String(localized: "Lets an agent drive a Chromium browser: open a page, read it, click and type."),
            symbol: "globe",
            status: status,
            state: state,
            outcome: outcome,
            isShowingOutput: $isShowingOutput
        ) {
            SettingsActionRow(isWorking: isWorking || isProbing) {
                if status?.installed == true {
                    Button("Start and Verify") { startAndVerify() }
                        .buttonStyle(.borderedProminent)
                        .settingsID("permissions.browser.start")
                } else if status?.path != nil {
                    Button("Install Chromium") { installRuntime() }
                        .buttonStyle(.borderedProminent)
                        .settingsID("permissions.browser.install")
                } else {
                    Button("Open the Setup Guide") { openInstallGuide() }
                        .buttonStyle(.borderedProminent)
                        .settingsID("permissions.browser.installGuide")
                }

                Button("Check Again") { refresh() }
                    .settingsID("permissions.browser.refresh")
            }
        }

        Picker(selection: Binding(
            get: { executablePath },
            set: { newValue in
                executablePath = newValue
                outcome = DriverOutcome(
                    level: .neutral,
                    summary: String(localized: "The new browser will be used from the next browser session on.")
                )
                refresh()
            }
        )) {
            ForEach(choices) { browser in
                Text(browser.name).tag(browser.executablePath ?? "")
            }
        } label: {
            SettingsLabel(
                title: String(localized: "Browser"),
                detail: String(localized: "Only Chromium-based browsers installed on this Mac are listed."),
                symbol: "macwindow"
            )
        }
        .settingsID("permissions.browser.choice")
        .disabled(isWorking)
        .task { await refreshStatus() }
    }

    private var state: (level: SettingsStatusLine.Level, text: String) {
        guard let status else { return (.neutral, String(localized: "Checking…")) }
        guard status.path != nil else { return (.error, String(localized: "Not installed")) }
        guard status.installed else { return (.warning, String(localized: "Chromium runtime missing")) }
        return (.ok, String(localized: "Ready"))
    }

    private func refresh() {
        Task { await refreshStatus() }
    }

    private func installRuntime() {
        guard !isWorking, let binary = status?.path,
              let invocation = AgentBrowserAdapter.installInvocation(binary: binary)
        else {
            outcome = DriverOutcome(
                level: .error,
                summary: String(localized: "Neither Node nor the agent-browser Playwright CLI was found.")
            )
            return
        }
        isWorking = true
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(
                    at: AgentBrowserAdapter.defaultBrowserDirectory,
                    withIntermediateDirectories: true
                )
                return ProcessRunner.run(
                    executable: invocation.executable,
                    arguments: invocation.arguments,
                    extraEnv: AgentBrowserAdapter.runtimeEnvironment(
                        nodePath: AgentBrowserAdapter.nodePath(binary: binary)
                    ),
                    timeout: 900
                )
            }.value
            isWorking = false
            await refreshStatus()
            let installed = status?.installed == true
            outcome = DriverOutcome.output(
                [result.stdoutString, result.stderrString].joined(separator: "\n"),
                ok: installed
            ) ?? DriverOutcome(
                level: installed ? .ok : .error,
                summary: installed
                    ? String(localized: "Chromium is installed.")
                    : String(localized: "The install finished but Chromium is still not there.")
            )
        }
    }

    private func startAndVerify() {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let adapter = AgentBrowserAdapter()
                let opened = adapter.perform(
                    .open(url: "https://example.com"),
                    session: "uncoil-setup",
                    profileDir: nil
                )
                let outcome: DriverOutcome
                switch opened {
                case .success:
                    _ = adapter.perform(.stop, session: "uncoil-setup", profileDir: nil)
                    outcome = DriverOutcome(
                        level: .ok,
                        summary: String(localized: "Opened a page and closed it again.")
                    )
                case .failure(let error):
                    outcome = DriverOutcome(
                        level: .error,
                        summary: error.message,
                        output: error.remedy
                    )
                }
                return (adapter.probe(), outcome)
            }.value
            status = result.0
            outcome = result.1
            isWorking = false
        }
    }

    private func refreshStatus() async {
        guard !isProbing else { return }
        isProbing = true
        status = await Task.detached(priority: .utility) {
            AgentBrowserAdapter().probe()
        }.value
        isProbing = false
    }

    private func openInstallGuide() {
        guard let url = URL(string: "https://github.com/vercel-labs/agent-browser") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Computer Use

struct CuaDriverSetupSection: View {
    @State private var status: DependencyInfo?
    @State private var isWorking = false
    @State private var isProbing = false
    @State private var outcome: DriverOutcome?
    @State private var isShowingOutput = false

    var body: some View {
        DriverCard(
            title: String(localized: "Computer Use"),
            purpose: String(localized: "Lets an agent see this Mac's screen and use it — the daemon and the macOS permissions it needs."),
            symbol: "display",
            status: status,
            state: state,
            outcome: outcome,
            isShowingOutput: $isShowingOutput
        ) {
            SettingsActionRow(isWorking: isWorking || isProbing) {
                if status?.installed == true {
                    Button("Start and Verify") { startAndVerify() }
                        .buttonStyle(.borderedProminent)
                        .settingsID("permissions.cua.start")

                    Button("Set Permissions") { grantPermissions() }
                        .settingsID("permissions.cua.permissions")
                } else {
                    Button("Open the Setup Guide") { openInstallGuide() }
                        .buttonStyle(.borderedProminent)
                        .settingsID("permissions.cua.installGuide")
                }

                Button("Check Again") { refresh() }
                    .settingsID("permissions.cua.refresh")
            }
        }
        .task { await refreshStatus() }
    }

    private var state: (level: SettingsStatusLine.Level, text: String) {
        guard let status else { return (.neutral, String(localized: "Checking…")) }
        guard status.installed else { return (.error, String(localized: "Not installed")) }
        return (.ok, String(localized: "Ready"))
    }

    private func refresh() {
        Task { await refreshStatus() }
    }

    private func startAndVerify() {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let adapter = CuaDriverAdapter()
                let call = adapter.perform(.listApps, session: "uncoil-setup")
                let outcome: DriverOutcome
                switch call {
                case .success:
                    outcome = DriverOutcome(
                        level: .ok,
                        summary: String(localized: "Answered a tool call.")
                    )
                case .failure(let error):
                    outcome = DriverOutcome(
                        level: .error,
                        summary: error.message,
                        output: error.remedy
                    )
                }
                return (adapter.probe(), outcome)
            }.value
            status = result.0
            outcome = result.1
            isWorking = false
        }
    }

    private func grantPermissions() {
        guard !isWorking, let binary = status?.path else { return }
        isWorking = true
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ProcessRunner.run(
                    executable: binary,
                    arguments: ["permissions", "grant"],
                    timeout: 120
                )
            }.value
            isWorking = false
            await refreshStatus()
            outcome = DriverOutcome.output(
                [result.stdoutString, result.stderrString].joined(separator: "\n"),
                ok: result.exitCode == 0
            ) ?? DriverOutcome(
                level: result.exitCode == 0 ? .ok : .error,
                summary: result.exitCode == 0
                    ? String(localized: "Permissions granted.")
                    : String(localized: "The driver refused to grant its permissions.")
            )
        }
    }

    private func refreshStatus() async {
        guard !isProbing else { return }
        isProbing = true
        status = await Task.detached(priority: .utility) {
            CuaDriverAdapter().probe()
        }.value
        isProbing = false
    }

    private func openInstallGuide() {
        guard let url = URL(string: "https://cua.ai/docs/how-to-guides/driver/install") else { return }
        NSWorkspace.shared.open(url)
    }
}
