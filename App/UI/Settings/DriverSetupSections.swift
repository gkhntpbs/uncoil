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

/// What came of running something, in Uncoil's words.
///
/// A tool's own output never reaches the screen: it is read — see
/// `DriverReport` — and what it meant is what gets shown. A page that pastes in
/// ticks, crosses and stack traces is asking the user to do the interpreting.
struct DriverOutcome: Equatable {
    var level: SettingsStatusLine.Level
    var summary: String

    /// A failure explained in the tool's own first line, when it had one, and
    /// by the fallback when it did not.
    static func failure(_ text: String, fallback: String) -> DriverOutcome {
        DriverOutcome(level: .error, summary: DriverReport.sentence(text) ?? fallback)
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
    @ViewBuilder let actions: Actions

    /// What the driver says it still needs, read out of its own status output.
    private var requirements: [DriverRequirement] {
        DriverReport.requirements(in: status?.detail ?? "")
    }

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
            }
        }

        // What the driver needs from macOS, one row each. This is the same
        // answer its status command gives in ticks and crosses; it is read
        // rather than shown.
        if !requirements.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(requirements) { requirement in
                    AdaptiveRow {
                        Text(name(of: requirement))
                            .font(.callout)
                    } control: {
                        SettingsStatusLine(
                            level: level(of: requirement),
                            text: label(for: requirement)
                        )
                    }
                }
            }
        }

        actions

        if let outcome {
            SettingsStatusLine(level: outcome.level, text: outcome.summary)
        }
    }

    /// Tools are inconsistent about case; the page is not.
    private func name(of requirement: DriverRequirement) -> String {
        guard let first = requirement.name.first else { return requirement.name }
        return first.uppercased() + requirement.name.dropFirst()
    }

    private func level(of requirement: DriverRequirement) -> SettingsStatusLine.Level {
        switch requirement.isGranted {
        case true: .ok
        case false: .warning
        default: .neutral
        }
    }

    private func label(for requirement: DriverRequirement) -> String {
        switch requirement.isGranted {
        case true: String(localized: "granted")
        case false: String(localized: "not granted")
        default: String(localized: "unknown")
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
            outcome: outcome
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
            // The probe is the verdict, not the installer's exit code: what
            // matters is whether a runtime is there now.
            outcome = status?.installed == true
                ? DriverOutcome(level: .ok, summary: String(localized: "Chromium is installed and ready."))
                : DriverOutcome.failure(
                    [result.stderrString, result.stdoutString].joined(separator: "\n"),
                    fallback: String(localized: "The install finished but no Chromium runtime is there.")
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
                    outcome = DriverOutcome.failure(
                        error.message,
                        fallback: String(localized: "The browser did not open.")
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

    var body: some View {
        DriverCard(
            title: String(localized: "Computer Use"),
            purpose: String(localized: "Lets an agent see this Mac's screen and use it — the daemon and the macOS permissions it needs."),
            symbol: "display",
            status: status,
            state: state,
            outcome: outcome
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
                    outcome = DriverOutcome.failure(
                        error.message,
                        fallback: String(localized: "The browser did not open.")
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
            // macOS decides, not the exit code: the re-probe above says which
            // permissions are actually in hand, and the rows show it.
            let outstanding = DriverReport
                .requirements(in: status?.detail ?? "")
                .filter { $0.isGranted != true }
            outcome = outstanding.isEmpty
                ? DriverOutcome(level: .ok, summary: String(localized: "Every permission is in place."))
                : DriverOutcome(
                    level: .warning,
                    summary: String(localized: "macOS still has to be told: \(outstanding.map(\.name).joined(separator: ", ")).")
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
